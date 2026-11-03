# EdgeGlow

Know when your AI coding agent is done, or needs you, without watching the terminal.

EdgeGlow is a tiny native macOS app that makes the edges of your screen glow and drops a Dynamic Island style pill from the top of the display. It works with **Claude Code, Codex, Gemini CLI, Qwen Code, Kimi, OpenCode** and (opt-in) **Grok**.

- **Green**: the agent finished its turn. The pill shows which agent, the project, and the first line of its reply.
- **Blue**: the agent needs your input (a permission prompt or a question). It stays until you answer.
- **Amber / red**: available from the CLI for your own scripts (`edgeglow warn`, `edgeglow alert`).

It's a single Swift file with no dependencies and no network access. It idles at about 20 MB of RAM and 0% CPU, and it starts at login.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). The compiler is only needed to build the app, not to run it.

```sh
git clone https://github.com/Emre-Diricanli/EdgeGlow.git
cd EdgeGlow
./install.sh
```

This builds `~/Applications/EdgeGlow.app`, links the `edgeglow` CLI into `~/.local/bin`, registers a LaunchAgent so it runs at login (and restarts if it crashes), and connects every AI agent it finds. Only EdgeGlow's own entries are added; your existing hooks are kept, and every file it touches is backed up to `<file>.bak-edgeglow` first.

Restart open agent sessions afterwards so they pick up the hooks.

Connect or disconnect agents any time:

```sh
python3 scripts/agents.py status
python3 scripts/agents.py install codex gemini
python3 scripts/agents.py uninstall qwen
```

To remove everything: `./uninstall.sh`

## How it behaves

- **Queue.** Several sessions can alert at once. The most urgent one is shown (red > blue > amber > green) with a `+N` badge for the rest.
- **Compact mode.** After about 7 seconds the pill shrinks to a small indicator and blue/amber glows dim to a gentle pulse, so a pending question doesn't keep flashing at you.
- **Click the pill** to dismiss the current alert. If you use the cmux terminal, clicking also jumps straight to the workspace and pane the alert came from, and the pill shows the workspace name.
- **Per session.** Replying in one session only clears that session's alert.
- **Notch aware.** On MacBooks with a notch, the pill grows out of the notch. On other displays it floats just below the top edge. Every connected screen glows.

## CLI

```sh
edgeglow done  [title] [subtitle]   # green
edgeglow input [title] [subtitle]   # blue
edgeglow warn  [title] [subtitle]   # amber
edgeglow alert [title] [subtitle]   # red, stays up to an hour or until clicked
edgeglow clear                      # dismiss everything
edgeglow alert "Build failed" "main · 3 tests" --id ci   # same --id replaces/clears just that one
```

Example: `make && edgeglow done "Build passed" || edgeglow alert "Build failed"`

Agents without a hook system can still use the CLI. For example, after each Aider command: `edgeglow done "" "Aider finished" --agent aider --project myapp`.

## Supported agents

| Agent | Green (done) | Blue (needs you) | Where EdgeGlow hooks in |
|---|---|---|---|
| Claude Code | `Stop`, with reply summary | permission prompts, questions | `~/.claude/settings.json` |
| Codex | `Stop`, with reply summary | `PermissionRequest` (approvals only) | `~/.codex/hooks.json`, trusted in `config.toml` |
| Gemini CLI | `AfterAgent`, with reply summary | `Notification` (permissions, ask_user) | `~/.gemini/settings.json` |
| Qwen Code | `Stop`, with reply summary | permission prompts | `~/.qwen/settings.json` |
| Kimi | `Stop` (no summary) | `PermissionRequest`, AskUserQuestion | `~/.kimi-code/config.toml` |
| OpenCode | turn succeeded, with reply summary | permission requests, questions | plugin in `~/.config/opencode/plugins/` |
| Grok (opt-in) | `Stop` (end of turn), with summary | permission prompts, questions | `~/.grok/hooks/edgeglow.json` |

Notes:

- Every hook calls `edgeglow hook <agent>`, which parses that agent's payload. Events from the wrong agent are ignored, so nothing fires twice. That matters because Grok also runs Claude's hooks.
- Codex only runs hooks you have trusted. The installer asks `codex app-server` for each hook's trust hash and records it in `~/.codex/config.toml`. If that fails, approve them once in Codex's `/hooks` screen.
- If you run an agent with approvals turned off (`--yolo`, `--dangerously-bypass-approvals-and-sandbox`, auto modes), it never asks, so you'll only see green.
- Codex shows green rather than blue when it ends a turn with a free-text question, because it has no separate event for that.
- Agent idle nudges ("still waiting for your input") and info notices are filtered out.

## How it works

The `edgeglow` CLI and the app are the same binary. Run with arguments, it posts a macOS distributed notification and exits in a few milliseconds. Run with no arguments, it is the overlay app: borderless, click-through SwiftUI windows above everything, on every Space, including full-screen apps.

Hack on it by editing `main.swift` and running `./build.sh`, which rebuilds and restarts the running copy.

## License

MIT
