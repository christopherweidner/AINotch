# AINotch

A tiny macOS menu bar app that turns the MacBook notch into a live status display for **Claude Code**.

- **Live timer while Claude works.** It keeps running through sub-agents. A Task/Agent sub-agent, or several background agents, count as part of the same run. The run ends only when Claude and every agent it started are done.
- **Progress, tokens and cost in real time.** Animated activity bars, the current step ("Editing", "Running command", "3 sub-agents"), a running token count and a running cost.
- **Completion summary.** When a run ends, the notch shows total time, tokens and cost, then shrinks to a green ✓ indicator. Click the indicator to open the Claude desktop app.
- **Answer Claude from the notch.** When Claude asks a question (`AskUserQuestion`), needs permission for a tool, or ends its turn with a question, the notch springs open into a card with an input field. Your answer goes straight back to the waiting Claude session.

The app has no Dock icon and no windows (`LSUIElement`), and it only reads local files. On Macs without a notch, the island hangs from the top centre of the main display.

> AINotch is a focused, standalone rewrite of the notch and Claude-tracking features in [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils). All the other utilities are left out. See [NOTICE.md](NOTICE.md).

## Requirements

- macOS 14 Sonoma or later. Built for Apple Silicon (Intel works with `UNIVERSAL=1`).
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (the CLI, or Claude Code sessions in the desktop app).
- To build: Xcode 15.3+ or the Swift 5.10+ command line tools (`xcode-select --install`).

## Download and run (Apple Silicon)

1. Download `AINotch.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `AINotch.app` to `/Applications`.
3. The app is ad-hoc signed, not notarized, so macOS blocks it the first time. Do one of these:
   - Right-click `AINotch.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/AINotch.app`.
4. When it asks to **Connect to Claude Code**, click **Connect**. This is needed for answering from the notch. The timer, tokens and cost work without it.

A ✦ icon appears in the menu bar. Start a Claude Code session and the notch comes alive.

## Build from source

```bash
git clone https://github.com/christopherweidner/AINotch.git
cd AINotch
make app          # → build/AINotch.app and build/AINotch.zip
make install      # copies to /Applications and launches it
```

Other options:

```bash
swift run AINotch                    # run without bundling (menu bar app, no Dock icon)
swift test                           # unit tests (the core also builds and tests on Linux)
UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
open Package.swift                   # work on it in Xcode
```

To sign with your own certificate: `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`.

## How it works

```
Claude Code ──writes──▶ ~/.claude/projects/**/<session>.jsonl          (+ <session>/subagents/agent-*.jsonl)
     │                         │ FSEvents
     │ hooks                   ▼
     └──▶ ainotch-hook ──unix socket──▶ AINotch.app ── SessionTracker ──▶ notch UI
              ▲                                │
              └──────── your answer (JSON) ◀───┘  (questions, permissions, follow-ups)
```

**Transcripts → timer, tokens, cost.** AINotch follows Claude Code's JSONL transcripts, including sub-agent logs. Every API response is priced from a built-in table of Anthropic's list prices (input, output, cache reads, 5-minute and 1-hour cache writes, fast mode, long-context premiums). Responses Claude Code writes more than once are counted only once. Sub-agent usage counts toward the run it serves.

**Why the timer no longer stops during sub-agent work.** A run stays "working" while any of these is true:

- the main turn is open (no final `end_turn` yet);
- a tool call is pending, such as a `Task`/`Agent` sub-agent or a long `Bash` command. While a tool is pending, the main log can stay silent for up to an hour;
- any sub-agent is still active: it has not given its final answer and wrote something in the last 15 minutes. This covers **background agents** that keep going after the main agent has already said "done".

The end of a run is debounced by a few seconds, so hand-offs between agents don't flash "finished". If Claude Code wakes the main agent with a `<task-notification>` when a background agent completes, the run resumes with its original start time. A `SubagentStop` hook is never mistaken for the main agent stopping.

**Hooks → interactive questions.** **Connect to Claude Code** adds entries to `~/.claude/settings.json` that run `AINotch.app/Contents/MacOS/ainotch-hook`. A backup is saved as `settings.json.ainotch-backup`, and other hooks are left alone. The helper passes each event to the app over a private Unix socket. If AINotch isn't running, the helper exits immediately and Claude Code behaves exactly as before.

| Claude Code event | What the notch does | What goes back to Claude |
|---|---|---|
| `PreToolUse` (`AskUserQuestion`) | Shows the question with its options plus an "Other…" field | Your answers, as the tool result Claude reads |
| `PermissionRequest` | Shows the tool and its command or file, with **Allow** / **Deny** | Allow, or deny with optional instructions |
| `Stop`, when Claude's last message ends with a question | Holds the session open and shows a reply field | Your reply. Claude continues in the same run |
| `Notification` | Shows the message | (nothing) |
| `UserPromptSubmit`, `SubagentStop`, `SessionEnd` | Makes run start and end tracking more precise | (nothing) |

Every card has **Answer in Claude**, which hands the question back to Claude's own UI. A card also closes by itself if you answer in the terminal, press Esc, or wait longer than the timeout (10 minutes).

**Completion → Claude app.** Clicking the ✓ indicator, the completion banner, or **Open Claude** calls `NSWorkspace` to bring up the Claude desktop app (`com.anthropic.claudefordesktop`), launching it if needed. If the app isn't installed, it opens claude.ai/download.

## Menu bar options

- **Connect to Claude Code (hooks)**: install or remove the hooks. From a script: `AINotch --install-hooks` / `--uninstall-hooks`.
- **Answer Questions in the Notch**: turn the interactive cards on or off.
- **Hold Claude When It Ends With a Question**: when off, `Stop` never waits on the notch.
- **Launch at Login**.

## Project layout

```
Package.swift
Sources/
  AINotchCore/          platform-independent, unit-tested (also on Linux)
    TranscriptParser    JSONL lines → events (usage, tools, turn ends, sub-agents)
    SessionTracker      run/turn state machine, incl. sub-agent keep-alive
    Pricing             Claude price table + cost computation
    HookProtocol        hook payloads, AskUserQuestion parsing, reply JSON
    SocketIPC           Unix socket server (app) and client (hook)
    HookInstaller       safe merge into ~/.claude/settings.json
    TranscriptTailer    incremental, partial-line-safe file tailing
  AINotchHook/          `ainotch-hook` CLI that Claude Code runs
  AINotch/              the macOS app (AppKit + SwiftUI)
    NotchGeometry       notch size from safeAreaInsets / auxiliaryTop*Area
    NotchPanel          click-through overlay panel above the menu bar
    NotchViews          compact timer, hover details, completion banner
    InteractionCard     question / permission / follow-up cards
    TranscriptWatcher   FSEvents on ~/.claude/projects
    AppModel            glue: transcripts + hooks → tracker → UI
Resources/Info.plist    LSUIElement = true
scripts/build-app.sh    builds and ad-hoc signs build/AINotch.app
```

## Privacy

Everything stays on your Mac. AINotch reads `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR/projects`). The only file it writes is `~/.claude/settings.json`, and only when you connect or disconnect the hooks. Its socket lives at `~/Library/Application Support/AINotch/hook.sock`, with permissions limited to your user. It makes no network requests.

## Uninstall

Choose **Connect to Claude Code** in the menu again to remove the hooks (or run `make uninstall`), then delete `/Applications/AINotch.app`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Not affiliated with Anthropic. "Claude" is a trademark of Anthropic.
