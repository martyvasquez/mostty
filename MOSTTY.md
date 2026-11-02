# mostty

Ghostty with two small additions. The engine (libghostty, Zig) is unchanged;
all changes are in the macOS Swift app.

## Workspaces

A workspace is a named Ghostty window with its own tabs and splits, usually
tied to a project folder. The sidebar runs the full height of the window; tabs
sit to its right. Clicking a workspace brings it forward at the same size and
position. Background workspaces are never suspended or hidden, so anything
running in them (Claude Code + Remote Control, servers, etc.) keeps running.

| Shortcut | Action |
| --- | --- |
| ⌃⌘N | New workspace for a folder (named after the git repo) |
| ⌃⇧⌘N | New empty workspace |
| ⌃⌘R | Rename workspace (or double-click it) |
| ⌥1–9 | Go to workspace N |
| ⌃⌘J / ⌃⌘K | Next / previous workspace |
| ⌃⌘S | Show / hide sidebar |
| ⌃⌘U | Jump to latest notification |

- New tabs in a workspace with a folder open in that folder (or stay in the
  current directory if it's inside the project).
- Opening a folder with mostty (Portal and other launchers, `open -a mostty
  <dir>`, Finder, dropping on the Dock icon) opens a new tab in the workspace
  whose project folder is, or contains, that folder. Otherwise it creates a
  new workspace for it.
- Right-click a workspace to rename, set/change its folder, show it in
  Finder, reorder, or close it.
- Workspaces, tabs and splits are restored when you reopen mostty (unless
  `window-save-state = never`).

## Claude Code status + notifications

Run once (re-run after updating mostty):

    extras/claude/install-hooks.sh

This registers `~/.claude/hooks/mostty-notify.sh` for Claude Code's
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop,
StopFailure and SessionEnd hooks. Each workspace in the sidebar then shows:

| Indicator | Meaning |
| --- | --- |
| spinner + "Working…" | Claude is working |
| pulsing orange dot + message | Claude needs you (permission prompt, etc.) |
| blue dot + summary | Claude finished and you haven't looked yet |

When Claude finishes or needs you, mostty also plays a sound, rings the pane
(border), puts 🔔 on the tab, and shows a toast (click to jump there).
⌃⌘U jumps to the latest terminal that needs attention.

Also:

- **Tabs** show ⏳ while Claude works there, 🟠 while it's waiting for you,
  and 🔔 once it's finished and you haven't looked.
- **Working time** shows in the sidebar ("Working · 4m").
- **Dock badge** counts tabs that need you (finished or waiting).
- **Keep awake**: while any Claude session is working, mostty prevents idle
  system sleep (the display can still sleep) so work and Remote Control
  aren't cut off. Released as soon as nothing is working.
- **Resume after restart**: Claude sessions open when you quit (or when
  mostty/macOS restarts) are resumed in the same tab with
  `claude --resume <id>`. Sessions you exited yourself are not.
  Turn off with `defaults write com.mostty.app MosttyResumeClaude -bool false`.
- **Close / quit warnings** say when Claude is working or waiting in what
  you're closing.

Notes:
- Claude Code has no hook for interrupts. Esc / ⌃C in the terminal clears
  "working" immediately; an interrupt from Remote Control clears after 15 min
  without activity.
- The 60s "Claude is waiting for your input" nag is ignored (Stop already
  told you).
- The hook only writes to the terminal and exits in ~50ms; it never blocks
  Claude and doesn't touch Remote Control.

Change the sound (any name from /System/Library/Sounds, or `none`):

    defaults write com.mostty.app MosttyNotificationSound Ping

## Changes to Ghostty

- `macos/Sources/Features/Workspaces/` — all new mostty code.
- Small hooks into: `AppDelegate.swift`, `TerminalController.swift`,
  `TerminalRestorable*.swift`, `Ghostty.App.swift`, `SurfaceView*.swift`.
- Window restoration defaults to on (`window-save-state = default` is
  treated as `always`).
- Engine: one exemption in `src/Surface.zig` so "mostty" status messages
  skip the 1-per-second notification rate limit.
- Xcode project: app is `mostty.app` (bundle id `com.mostty.app`); the Swift
  module and the executable inside stay `Ghostty` / `ghostty` so upstream
  merges and shell integration keep working.
- Dock icon defaults to Ghostty's "retro" style (set `macos-icon` to override).

## Build / update

Needs Xcode 26+ (with Metal Toolchain) and Zig 0.17.

    git pull --rebase upstream main   # upstream = ghostty-org/ghostty
    zig build -Doptimize=ReleaseFast
    open zig-out/mostty.app           # or copy it to /Applications

The bundle id is `com.mostty.app` so it runs side by side with Ghostty and
shares your Ghostty config file. Sparkle auto-update is disabled.
