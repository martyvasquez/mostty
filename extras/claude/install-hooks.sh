#!/bin/bash
# mostty: installs the Claude Code notification hook.
#  - copies mostty-notify.sh to ~/.claude/hooks/
#  - registers it for the Claude Code hook events below in ~/.claude/settings.json
#    (existing hooks are kept; a backup is written next to the file)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
settings="$HOME/.claude/settings.json"
hook="$HOME/.claude/hooks/mostty-notify.sh"

mkdir -p "$HOME/.claude/hooks"
cp "$here/mostty-notify.sh" "$hook"
chmod +x "$hook"

[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak-mostty"

entry='{"hooks":[{"type":"command","command":"~/.claude/hooks/mostty-notify.sh"}]}'
tmp="$(mktemp)"
jq --argjson e "$entry" '
  def add(k): .hooks[k] = (((.hooks[k] // []) | map(select((.hooks // []) | all(.command != $e.hooks[0].command)))) + [$e]);
  .hooks = (.hooks // {})
  | add("SessionStart") | add("UserPromptSubmit") | add("PreToolUse") | add("PostToolUse")
  | add("Notification") | add("Stop") | add("StopFailure") | add("SessionEnd")
' "$settings" > "$tmp"
mv "$tmp" "$settings"

echo "Installed $hook"
echo "Registered for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, StopFailure, SessionEnd in $settings (backup: $settings.bak-mostty)"
