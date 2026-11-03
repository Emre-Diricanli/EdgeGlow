#!/usr/bin/env python3
"""Add or remove EdgeGlow's hooks in ~/.claude/settings.json (keeps everything else intact)."""
import json, os, shutil, sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
CLI = os.path.expanduser("~/.local/bin/edgeglow")
HOOKS = {
    "Stop": "done --hook",              # green: Claude finished
    "Notification": "input --hook",     # blue: Claude needs you
    "UserPromptSubmit": "clear --hook", # you replied
    "PostToolUse": "clear --hook",      # you approved a tool
}

def is_ours(h):
    return "edgeglow" in h.get("command", "")

def main(action):
    data = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            data = json.load(f)
        shutil.copy(SETTINGS, SETTINGS + ".bak-edgeglow")
    hooks = data.setdefault("hooks", {})
    # always strip existing EdgeGlow entries first, so install is idempotent
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
    if action == "install":
        for event, args in HOOKS.items():
            hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": f"{CLI} {args}"}]})
    if not hooks:
        data.pop("hooks")
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Claude Code hooks {'installed' if action == 'install' else 'removed'} in {SETTINGS}")

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit("usage: hooks.py install|uninstall")
    main(sys.argv[1])
