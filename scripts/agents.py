#!/usr/bin/env python3
"""Connect EdgeGlow to AI coding agents.

  agents.py status                     show which agents are installed / connected
  agents.py install [agent ...]        connect agents (default: every detected agent except grok)
  agents.py uninstall [agent ...]      disconnect agents (default: all)

Agents: claude codex gemini qwen kimi opencode grok
Every config file is backed up to <file>.bak-edgeglow before it is changed, and only
EdgeGlow's own entries are ever added or removed.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

try:
    import tomllib  # Python 3.11+
except ImportError:  # older Pythons: skip TOML validation
    tomllib = None

HOME = os.path.expanduser("~")
CLI = os.path.join(HOME, ".local/bin/edgeglow")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIMI_HOME = os.environ.get("KIMI_CODE_HOME", os.path.join(HOME, ".kimi-code"))
BEGIN, END = "# >>> edgeglow (managed by EdgeGlow)", "# <<< edgeglow"


def hook_cmd(agent):
    return f"{CLI} hook {agent}"


def is_ours(entry):
    return "edgeglow" in str(entry.get("command", ""))


def which(*names):
    return any(shutil.which(n) for n in names)


# ---------------------------------------------------------------- file helpers

def backup(path):
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak-edgeglow")


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def strip_json_hooks(data):
    """Remove EdgeGlow entries from a Claude-style {"hooks": {Event: [groups]}} object."""
    hooks = data.get("hooks", {})
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h)]
            if g["hooks"]:
                groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if "hooks" in data and not hooks:
        del data["hooks"]


def has_json_hooks(path):
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return False
    return any(is_ours(h) for gs in data.get("hooks", {}).values() for g in gs for h in g.get("hooks", []))


def strip_block(text, begin=BEGIN, end=END):
    return re.sub(rf"\n?{re.escape(begin)}.*?{re.escape(end)}\n?", "\n", text, flags=re.S).rstrip() + "\n"


def write_toml(path, text):
    """Write TOML, refusing to leave behind a file that no longer parses."""
    if tomllib:
        tomllib.loads(text)  # raises on a broken result; caller reports it
    with open(path, "w") as f:
        f.write(text)


# ---------------------------------------------------------------- JSON-hook agents

class JsonHooks:
    """Agents with Claude-style hooks in a JSON settings file."""

    def __init__(self, name, path, events, detect, extra=None, matcher=None):
        self.name, self.path, self.events, self._detect = name, path, events, detect
        self.extra, self.matcher = extra or {}, matcher

    def detected(self):
        return self._detect()

    def connected(self):
        return has_json_hooks(self.path)

    def install(self):
        data = load_json(self.path)
        backup(self.path)
        strip_json_hooks(data)
        hooks = data.setdefault("hooks", {})
        for event in self.events:
            group = {"hooks": [{"type": "command", "command": hook_cmd(self.name), **self.extra}]}
            if self.matcher:
                group = {"matcher": self.matcher, **group}
            hooks.setdefault(event, []).append(group)
        save_json(self.path, data)
        return f"hooks added to {self.path}"

    def uninstall(self):
        if not os.path.exists(self.path) or not self.connected():
            return None
        data = load_json(self.path)
        backup(self.path)
        strip_json_hooks(data)
        save_json(self.path, data)
        return f"hooks removed from {self.path}"


class Codex(JsonHooks):
    """Codex: hooks in ~/.codex/hooks.json, which must also be marked trusted in config.toml."""

    CONFIG = os.path.join(HOME, ".codex/config.toml")
    TRUST_BEGIN, TRUST_END = "# >>> edgeglow codex hook trust (managed by EdgeGlow)", "# <<< edgeglow codex hook trust"

    def __init__(self):
        super().__init__("codex", os.path.join(HOME, ".codex/hooks.json"),
                         ["Stop", "PermissionRequest", "UserPromptSubmit", "PostToolUse"],
                         lambda: which("codex") or os.path.isdir(os.path.join(HOME, ".codex")),
                         extra={"timeout": 5})

    def install(self):
        msg = super().install()
        return msg + "; " + self.trust()

    def uninstall(self):
        msg = super().uninstall()
        if os.path.exists(self.CONFIG):
            text = open(self.CONFIG).read()
            if self.TRUST_BEGIN in text:
                backup(self.CONFIG)
                write_toml(self.CONFIG, strip_block(text, self.TRUST_BEGIN, self.TRUST_END))
        if os.path.exists(self.path) and load_json(self.path) == {}:
            os.remove(self.path)
        return msg

    def list_hooks(self):
        """Ask `codex app-server` which hooks exist and whether they are trusted."""
        import select
        exe = shutil.which("codex") or os.path.join(HOME, ".local/bin/codex")
        p = subprocess.Popen([exe, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
        try:
            def send(obj):
                p.stdin.write(json.dumps(obj) + "\n")
                p.stdin.flush()

            def recv(want, timeout=15):
                deadline = time.time() + timeout
                while time.time() < deadline:
                    ready, _, _ = select.select([p.stdout], [], [], 0.5)
                    if not ready:
                        continue
                    line = p.stdout.readline()
                    if not line:
                        return None
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if msg.get("id") == want:
                        return msg
                return None

            send({"id": 1, "method": "initialize",
                  "params": {"clientInfo": {"name": "edgeglow", "title": "EdgeGlow", "version": "1.0"}}})
            if not recv(1):
                return None
            send({"method": "initialized"})
            send({"id": 2, "method": "hooks/list", "params": {"cwds": [HOME]}})
            resp = recv(2)
            if not resp or "result" not in resp:
                return None
            return [h for d in resp["result"].get("data", []) for h in d.get("hooks", [])]
        finally:
            p.terminate()

    def trust(self):
        manual = "open Codex and approve the EdgeGlow hooks in /hooks (or run it inside cmux, which trusts them)"
        try:
            hooks = self.list_hooks()
        except OSError:
            hooks = None
        if hooks is None:
            return "could not reach `codex app-server` to trust hooks: " + manual
        ours = [h for h in hooks if "edgeglow" in json.dumps(h)]
        pending = [h for h in ours if str(h.get("trustStatus", "")).lower() != "trusted"]
        if not ours:
            return "Codex did not list the hooks: " + manual
        if not pending:
            return "hooks already trusted"
        lines = [self.TRUST_BEGIN]
        for h in pending:
            key, digest = h.get("key"), h.get("currentHash")
            if not key or not digest:
                return "unexpected hook format from Codex: " + manual
            lines += [f"[hooks.state.{json.dumps(key)}]", f"trusted_hash = {json.dumps(digest)}"]
        lines.append(self.TRUST_END)
        text = open(self.CONFIG).read() if os.path.exists(self.CONFIG) else ""
        text = strip_block(text, self.TRUST_BEGIN, self.TRUST_END) if text else ""
        backup(self.CONFIG)
        try:
            write_toml(self.CONFIG, text + "\n" + "\n".join(lines) + "\n")
        except Exception as e:  # leave config.toml untouched if the result would not parse
            return f"could not write trust to config.toml ({e}): " + manual
        return f"trusted {len(pending)} hooks in {self.CONFIG}"


# ---------------------------------------------------------------- other agents

class Kimi:
    name = "kimi"
    path = os.path.join(KIMI_HOME, "config.toml")

    def detected(self):
        return which("kimi") or os.path.isdir(KIMI_HOME)

    def connected(self):
        return os.path.exists(self.path) and BEGIN in open(self.path).read()

    def install(self):
        text = open(self.path).read() if os.path.exists(self.path) else ""
        text = strip_block(text) if text else ""
        cmd = json.dumps(hook_cmd("kimi"))
        block = [BEGIN]
        for event, matcher in [("Stop", None), ("PermissionRequest", None),
                               ("PreToolUse", "^AskUserQuestion$"),
                               ("UserPromptSubmit", None), ("PostToolUse", None)]:
            block += ["[[hooks]]", f'event = "{event}"']
            if matcher:
                block.append(f"matcher = {json.dumps(matcher)}")
            block += [f"command = {cmd}", "timeout = 5", ""]
        block.append(END)
        backup(self.path)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        write_toml(self.path, text + "\n" + "\n".join(block) + "\n")
        return f"hooks added to {self.path}"

    def uninstall(self):
        if not self.connected():
            return None
        backup(self.path)
        write_toml(self.path, strip_block(open(self.path).read()))
        return f"hooks removed from {self.path}"


class OpenCode:
    name = "opencode"
    path = os.path.join(HOME, ".config/opencode/plugins/edgeglow.js")
    src = os.path.join(REPO, "plugins/opencode/edgeglow.js")

    def detected(self):
        return which("opencode") or os.path.isdir(os.path.join(HOME, ".config/opencode"))

    def connected(self):
        return os.path.exists(self.path)

    def install(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        shutil.copy(self.src, self.path)
        return f"plugin installed at {self.path}"

    def uninstall(self):
        if not self.connected():
            return None
        os.remove(self.path)
        return f"plugin removed from {self.path}"


class Grok:
    """Opt-in only. Grok also runs Claude's hooks; EdgeGlow ignores those, so this file is
    the only way Grok events get through and nothing fires twice."""
    name = "grok"
    path = os.path.join(HOME, ".grok/hooks/edgeglow.json")

    def detected(self):
        return which("grok") or os.path.isdir(os.path.join(HOME, ".grok"))

    def connected(self):
        return os.path.exists(self.path)

    def install(self):
        cmd = {"type": "command", "command": hook_cmd("grok")}
        save_json(self.path, {"hooks": {e: [{"hooks": [cmd]}] for e in
                                        ["Stop", "Notification", "UserPromptSubmit", "PostToolUse"]}})
        return f"hooks installed at {self.path}"

    def uninstall(self):
        if not self.connected():
            return None
        os.remove(self.path)
        return f"hooks removed from {self.path}"


AGENTS = {
    "claude": JsonHooks("claude", os.path.join(HOME, ".claude/settings.json"),
                        ["Stop", "Notification", "UserPromptSubmit", "PostToolUse"],
                        lambda: which("claude") or os.path.isdir(os.path.join(HOME, ".claude"))),
    "codex": Codex(),
    "gemini": JsonHooks("gemini", os.path.join(HOME, ".gemini/settings.json"),
                        ["AfterAgent", "Notification", "BeforeAgent", "AfterTool"],
                        lambda: which("gemini") or os.path.isdir(os.path.join(HOME, ".gemini")),
                        extra={"name": "edgeglow", "timeout": 5000}, matcher="*"),
    "qwen": JsonHooks("qwen", os.path.join(HOME, ".qwen/settings.json"),
                      ["Stop", "Notification", "UserPromptSubmit", "PostToolUse"],
                      lambda: which("qwen") or os.path.isdir(os.path.join(HOME, ".qwen"))),
    "kimi": Kimi(),
    "opencode": OpenCode(),
    "grok": Grok(),
}
OPT_IN = {"grok"}


def main(argv):
    action = argv[0] if argv else "status"
    names = [a.lower() for a in argv[1:]]
    unknown = [n for n in names if n not in AGENTS]
    if action not in ("status", "install", "uninstall") or unknown:
        sys.exit(__doc__ + (f"\nunknown agent(s): {', '.join(unknown)}" if unknown else ""))

    if action == "status":
        for n, a in AGENTS.items():
            state = "connected" if a.connected() else ("installed, not connected" if a.detected() else "not installed")
            print(f"  {n:<9} {state}{'  (opt-in)' if n in OPT_IN else ''}")
        return

    if action == "install":
        targets = names or [n for n, a in AGENTS.items() if a.detected() and n not in OPT_IN]
    else:
        targets = names or list(AGENTS)
    for n in targets:
        try:
            msg = getattr(AGENTS[n], action)()
        except Exception as e:  # one agent's broken config shouldn't stop the rest
            msg = f"skipped: {e}"
        if msg:
            print(f"  {n:<9} {msg}")


if __name__ == "__main__":
    main(sys.argv[1:])
