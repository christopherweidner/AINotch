# Notice

AINotch is derived from [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils)
(Copyright © 2026 Vorssaint), which is licensed under the GNU General Public License v3.0 or later.
As a derivative work, AINotch is distributed under the same license (see `LICENSE`).

Taken or adapted from vorssaint-utils:

- The Claude Code transcript semantics: how turns open and close, how sub-agent (sidechain)
  lines are handled, interruptions, and deduplicating responses by message and request id
  (`Services/AgentUsage/AgentLogParser.swift`, `AgentUsageStore.swift`).
- The Claude model price table (`Resources/agent-prices.json`).
- The overall approach to notch geometry and a borderless overlay panel above the menu bar
  (`Services/Notch/NotchWindowHost.swift`, `NotchSupport.swift`).

Everything else in vorssaint-utils (media, mixer, volume, windows, clipboard, uninstaller,
system monitors, the other agent providers, and so on) is not included. The code in this
repository was rewritten as a small standalone app.

"Claude" and "Anthropic" are trademarks of Anthropic PBC. This project is not affiliated with
or endorsed by Anthropic or Vorssaint.
