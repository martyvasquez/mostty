#!/bin/bash
# mostty: Claude Code hook -> terminal status + notification.
#
# Registered for: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
# Notification, Stop, StopFailure, SessionEnd.
#
# It writes OSC 777 sequences to the terminal Claude is running in:
#   - "mostty" control messages, mostty only:
#       state=working|waiting|idle  -> spinner / dots in the sidebar and tabs
#       session=<id>|<cwd>          -> lets mostty resume the session after a
#                                      restart (empty = session ended)
#   - real notifications (finished / needs you), which mostty turns into a
#     sound, a ring on the pane, a dot on the workspace and a toast. Plain
#     Ghostty shows them as macOS notifications.
#
# It only writes a few bytes to the tty and always exits 0 quickly, so it
# can never block Claude or interfere with Remote Control.

input="$(cat)"

# Only act inside Ghostty / mostty.
[ "$TERM_PROGRAM" = "ghostty" ] || exit 0
is_mostty=0
[ "$__CFBundleIdentifier" = "com.mostty.app" ] && is_mostty=1

field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

# OSC fields are separated by ';' and terminated by BEL: strip those and
# other control characters, collapse whitespace, and keep it short.
clean() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -d '\000-\037\177' | tr ';' ',' \
    | sed -e 's/  */ /g' -e 's/^ //' | cut -c1-140
}

out=""
state() { [ "$is_mostty" = 1 ] && out="$out$(printf '\033]777;notify;mostty;state=%s\007' "$1")"; }
# Session id + working directory. Paths with ';' or control characters can't
# travel in an OSC field, so those are sent without a directory.
session() {
  [ "$is_mostty" = 1 ] || return 0
  local id="$1" dir="$2"
  case "$id" in *[!A-Za-z0-9-]*) return 0 ;; esac
  case "$dir" in *';'*|*$'\a'*|*$'\e'*|*$'\n'*) dir="" ;; esac
  if [ -n "$id" ]; then
    out="$out$(printf '\033]777;notify;mostty;session=%s|%s\007' "$id" "$dir")"
  else
    out="$out$(printf '\033]777;notify;mostty;session=\007')"
  fi
}
notify() { out="$out$(printf '\033]777;notify;%s;%s\007' "$(clean "$1")" "$(clean "$2")")"; }

event="$(field hook_event_name)"
cwd="$(field cwd)"
sid="$(field session_id)"
project="$(basename "${cwd:-$PWD}")"

case "$event" in
  SessionStart)
    session "$sid" "$cwd"
    ;;
  UserPromptSubmit)
    session "$sid" "$cwd"
    state working
    ;;
  PreToolUse|PostToolUse)
    state working
    ;;
  Notification)
    type="$(field notification_type)"
    message="$(field message)"
    # The "still waiting for your input" nag after 60s idle repeats what
    # Stop already told you, so skip it.
    if [ "$type" = "idle_prompt" ] || printf '%s' "$message" | grep -qi "waiting for your input"; then
      exit 0
    fi
    state waiting
    notify "Claude Code needs you" "${message:-$project}"
    ;;
  Stop)
    # A Stop hook that blocked and made Claude continue: still working.
    [ "$(field stop_hook_active)" = "true" ] && exit 0
    summary="$(field last_assistant_message | head -c 600)"
    state idle
    notify "Claude Code finished · $project" "${summary:-Done}"
    ;;
  StopFailure)
    state idle
    notify "Claude Code stopped · $project" "$(field error)"
    ;;
  SessionEnd)
    state idle
    session "" ""
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$out" ] || exit 0

# Find the terminal: our controlling tty if we have one, otherwise the tty of
# the nearest ancestor process (the claude process itself).
write_tty() { { printf '%s' "$out" > "$1"; } 2>/dev/null; }

write_tty /dev/tty && exit 0
pid=$PPID
for _ in 1 2 3 4 5 6; do
  [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -n "$tty" ] && [ "$tty" != "??" ]; then
    write_tty "/dev/$tty" && exit 0
  fi
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
done
exit 0
