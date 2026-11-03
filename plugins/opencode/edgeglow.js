// EdgeGlow plugin for OpenCode v2 (server plugin).
// Installed by EdgeGlow (scripts/agents.py) to ~/.config/opencode/plugins/edgeglow.js
//
// green  (done)  -> session.execution.succeeded   (top-level sessions only; subagents skipped)
// amber  (warn)  -> session.execution.failed
// blue   (input) -> permission.asked | form.created (question tool)
// clear          -> permission.replied | form.replied | form.cancelled (the ask is gone)
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { basename } from "node:path";

const BIN = process.env.EDGEGLOW_BIN || `${homedir()}/.local/bin/edgeglow`;
// OpenCode instantiates the plugin once per loaded project location, and every instance
// receives every event. Share one dedupe set across instances so each event fires once.
const SEEN = (globalThis.__edgeglowSeen ??= new Set());
const CHAIN = (globalThis.__edgeglowChain ??= new Map());

const oneLine = (s, max = 140) => {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
};

function glow(kind, proj, subtitle, id) {
  try {
    const args = [kind];
    if (kind !== "clear") {
      args.push("", subtitle || "");
      if (proj) args.push("--project", proj);
    }
    args.push("--agent", "opencode");
    if (id) args.push("--id", id);
    const p = spawn(BIN, args, { detached: true, stdio: "ignore" });
    p.on("error", () => {});
    p.unref();
  } catch {}
}

const withTimeout = (p, ms = 1500) =>
  Promise.race([Promise.resolve(p).catch(() => undefined), new Promise((r) => setTimeout(r, ms))]);

async function sessionInfo(ctx, sessionID) {
  const s = await withTimeout(ctx.session.get({ sessionID }));
  return s && typeof s === "object" ? s : undefined;
}

async function lastAssistantText(ctx, sessionID) {
  const msgs = await withTimeout(ctx.session.context({ sessionID }));
  if (!Array.isArray(msgs)) return undefined;
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m?.type !== "assistant" || !Array.isArray(m.content)) continue;
    const text = m.content.filter((c) => c?.type === "text" && c.text).map((c) => c.text).join(" ");
    if (text.trim()) return text;
  }
}

const project = (s, ev) => {
  const dir = s?.location?.directory || ev?.location?.directory;
  return dir ? basename(dir) : "";
};

async function handle(ctx, ev) {
  const d = ev.data ?? {};
  switch (ev.type) {
    case "session.execution.succeeded": {
      const s = await sessionInfo(ctx, d.sessionID);
      if (s?.parentID) return; // subagent finished; parent turn still running
      const text = await lastAssistantText(ctx, d.sessionID);
      return glow("done", project(s, ev), oneLine(text || s?.title || "Done"), d.sessionID);
    }
    case "session.execution.failed": {
      const s = await sessionInfo(ctx, d.sessionID);
      if (s?.parentID) return;
      return glow("warn", project(s, ev), oneLine(d.error?.message || "Session failed"), d.sessionID);
    }
    case "permission.asked": {
      const s = await sessionInfo(ctx, d.sessionID);
      const what = [d.action, (d.resources ?? []).join(", ")].filter(Boolean).join(": ");
      return glow("input", project(s, ev), oneLine(`Permission: ${what || "needed"}`), s?.parentID || d.sessionID);
    }
    case "form.created": {
      const f = d.form ?? {};
      const s = await sessionInfo(ctx, f.sessionID);
      const q = f.fields?.[0]?.description || f.fields?.[0]?.title || f.title || "Question";
      return glow("input", project(s, ev), oneLine(q), s?.parentID || f.sessionID);
    }
    case "permission.replied":
    case "form.replied":
    case "form.cancelled": {
      const s = await sessionInfo(ctx, d.sessionID);
      return glow("clear", "", "", s?.parentID || d.sessionID);
    }
  }
}

const TYPES = [
  "session.execution.succeeded",
  "session.execution.failed",
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
];

export default {
  id: "edgeglow",
  setup(ctx) {
    const ac = new AbortController();
    (async () => {
      try {
        for await (const ev of ctx.event.subscribe({ types: TYPES, signal: ac.signal })) {
          try {
            if (!ev?.id || SEEN.has(ev.id)) continue;
            SEEN.add(ev.id);
            if (SEEN.size > 500) SEEN.delete(SEEN.values().next().value);
            // fire-and-forget (never block the stream), but keep per-session order so a fast
            // permission.replied "clear" can't overtake its own "input".
            const key = ev.data?.sessionID ?? ev.data?.form?.sessionID ?? "";
            const next = (CHAIN.get(key) ?? Promise.resolve()).then(() => handle(ctx, ev)).catch(() => {});
            CHAIN.set(key, next);
            next.then(() => { if (CHAIN.get(key) === next) CHAIN.delete(key); });
          } catch {}
        }
      } catch {}
    })();
    return () => ac.abort();
  },
};
