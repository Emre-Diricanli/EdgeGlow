# EdgeGlow

Know when Claude Code is done, or needs you, without watching the terminal.

EdgeGlow is a tiny native macOS app that makes the edges of your screen glow and drops a Dynamic Island style pill from the top of the display:

- **Green**: Claude finished a task. The pill shows the first line of its reply.
- **Blue**: Claude needs your input (a permission prompt or a question). It stays until you answer.
- **Amber / red**: available from the CLI for your own scripts (`edgeglow warn`, `edgeglow alert`).

It's a single Swift file with no dependencies and no network access. It idles at about 20 MB of RAM and 0% CPU, and it starts at login.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). The compiler is only needed to build the app, not to run it.

```sh
git clone https://github.com/Emre-Diricanli/EdgeGlow.git
cd EdgeGlow
./install.sh
```

This builds `~/Applications/EdgeGlow.app`, links the `edgeglow` CLI into `~/.local/bin`, registers a LaunchAgent so it runs at login (and restarts if it crashes), and adds hooks to `~/.claude/settings.json`. Your existing hooks are kept, and a backup is written to `settings.json.bak-edgeglow`.

Restart open Claude Code sessions afterwards so they pick up the hooks.

To remove everything: `./uninstall.sh`

## How it behaves

- **Queue.** Several sessions can alert at once. The most urgent one is shown (red > blue > amber > green) with a `+N` badge for the rest.
- **Compact mode.** After about 7 seconds the pill shrinks to a small indicator and blue/amber glows dim to a gentle pulse, so a pending question doesn't keep flashing at you.
- **Click the pill** to dismiss the current alert. If you use the cmux terminal, clicking also jumps straight to the workspace and pane the alert came from, and the pill shows the workspace name.
- **Per session.** Replying in one Claude session only clears that session's alert.
- **Notch aware.** On MacBooks with a notch, the pill grows out of the notch. On other displays it floats just below the top edge. Every connected screen glows.
- **Claude Code only.** Some other agent CLIs (e.g. Grok) read `~/.claude/settings.json` hooks for compatibility. EdgeGlow ignores their events, as well as Claude's "still waiting" idle nudge.

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

## Hooks it installs

| Claude Code event  | Command                    |
|--------------------|----------------------------|
| `Stop`             | `edgeglow done --hook`     |
| `Notification`     | `edgeglow input --hook`    |
| `UserPromptSubmit` | `edgeglow clear --hook`    |
| `PostToolUse`      | `edgeglow clear --hook`    |

With `--hook`, the CLI reads the hook JSON from stdin to get the session, project and message. Manage them with `python3 scripts/hooks.py install|uninstall`.

## How it works

The `edgeglow` CLI and the app are the same binary. Run with arguments, it posts a macOS distributed notification and exits in a few milliseconds. Run with no arguments, it is the overlay app: borderless, click-through SwiftUI windows above everything, on every Space, including full-screen apps.

Hack on it by editing `main.swift` and running `./build.sh`, which rebuilds and restarts the running copy.

## License

MIT
