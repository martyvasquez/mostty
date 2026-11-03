# mostty

Ghostty with two small additions. The engine (libghostty, Zig) is unchanged;
all changes are in the macOS Swift app.

## Workspaces

A workspace is a named Ghostty window with its own tabs and splits, usually
tied to a project folder. The sidebar runs the full height of the window; tabs
sit to its right.

mostty is one window: workspaces replace windows. Only the active workspace is
shown; switching (sidebar, shortcuts, a notification click) swaps it in place,
and a new workspace (⌘N, ⌃⌘N, a launcher opening a folder) takes the place of
the current one instead of opening a separate window. Background workspaces are
never suspended, so anything running in them (Claude Code + Remote Control,
servers, etc.) keeps running; macOS just doesn't draw them. Closing the last
tab of a workspace shows another one.

| Shortcut | Action |
| --- | --- |
| ⌘N | New workspace in the current tab's directory (File > New Workspace; name it right away) |
| ⌃⌘N | New workspace for a folder (named after the git repo) |
| ⌘⇧T | New tab that starts Claude Code (undo / reopen closed tab stays on ⌘Z) |
| ⌃⌘R | Rename workspace (or double-click it) |
| ⌥1–9 | Go to workspace N |
| ⌃⌘J / ⌃⌘K | Next / previous workspace |
| ⌃⌘S | Show / hide sidebar |
| ⌃⌘U | Jump to latest notification |

- New tabs in a workspace with a folder open in that folder (or stay in the
  current directory if it's inside the project).
- Opening a folder with mostty (Portal and other launchers, `open -a mostty
  <dir>`, Finder, dropping on the Dock icon, Finder's Services >
  New mostty Terminal Here) opens a new tab in the workspace
  whose project folder is, or contains, that folder. Otherwise it creates a
  new workspace for it.
- Right-click a workspace to rename, set/change its folder, show it in
  Finder, reorder, or close it.
- Workspaces, tabs and splits are restored when you reopen mostty (unless
  `window-save-state = never`).

## Claude Code status + notifications

Nothing to install. In mostty, `claude` runs with mostty's hooks for
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop,
StopFailure and SessionEnd: shell integration (zsh, bash, fish) wraps the
`claude` command to add `--settings` pointing at the copy bundled in the app
(`src/shell-integration/claude/`). `~/.claude` is never touched, other
terminals are unaffected, and app updates update the hooks. It's skipped if
you define your own `claude` function or pass `--settings` yourself.
The bundled settings also turn off Claude Code's own built-in terminal
alert (`preferredNotifChannel`), which otherwise repeats the hook's
notification about a minute later.

Each workspace in the sidebar shows:

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
- Engine: `src/config/Config.zig` no longer binds ⌘⇧T to undo by default
  (it's New Claude Tab; undo stays on ⌘Z).
- Xcode project: app is `mostty.app` (bundle id `com.mostty.app`); the Swift
  module and the executable inside stay `Ghostty` / `ghostty` so upstream
  merges and shell integration keep working.
- Dock icon defaults to Ghostty's "retro" style (set `macos-icon` to override).

## Updates (Sparkle)

mostty updates itself from this repo's GitHub releases. It checks once a day
(and via mostty → Check for Updates…), shows an "Update Available" pill, and
installs on click or on quit. Set `auto-update = off|check|download` in the
config to change that.

Updates are signed with an EdDSA key stored in the login keychain under the
account `mostty` (public key: `SUPublicEDKey` in `macos/Ghostty-Info.plist`).
**Back it up** — without it, existing installs can't verify new releases:

    <sparkle bin>/generate_keys --account mostty -x mostty-sparkle-key.txt

### Publishing a release

    extras/release.sh 0.2.0

From a clean, pushed `main`, this builds the app, stamps the version
(build number = commit count), re-signs it, zips it, writes a signed
`appcast.xml` and creates GitHub release `v0.2.0` with both. Installed apps
read `releases/latest/download/appcast.xml`.

To try a release locally first:

    MOSTTY_BUILD=2 extras/release.sh 0.0.2 --local
    (cd release-out/archives && python3 -m http.server 8000)
    defaults write com.mostty.app MosttyUpdateFeedURL http://localhost:8000/appcast.xml
    # … Check for Updates… …
    defaults delete com.mostty.app MosttyUpdateFeedURL

## Build from source

Needs Xcode 26+ (with Metal Toolchain) and Zig 0.17.

    zig build -Doptimize=ReleaseFast
    open zig-out/mostty.app

The bundle id is `com.mostty.app` so it runs side by side with Ghostty and
shares your Ghostty config file.

## Pulling in Ghostty updates

Merge Ghostty's `main` (remote `upstream` = ghostty-org/ghostty) every week
or two so each merge stays small:

    git fetch upstream
    git merge upstream/main
    zig build -Doptimize=ReleaseFast && open zig-out/mostty.app
    git push origin main              # releases it

Merge, don't rebase: `main` is published and every push releases (the build
number is the commit count), so rewriting it would need a force push.

Conflicts, if any, will be in the files listed under "Changes to Ghostty";
`macos/Sources/Features/Workspaces/` is all mostty's own code.
