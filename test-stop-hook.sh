#!/usr/bin/env bash
# Drives the installed session-state hook against a throwaway HOME and checks the one decision
# in it that is not obvious from reading it: when a press of STOP AGENTS reaches a session and
# when it does not. Run after `fleet --install-hooks`.
set -uo pipefail

HOOK="${1:-$HOME/.claude/fleet/session-state.sh}"
[ -x "$HOOK" ] || { echo "no hook at $HOOK — run: fleet --install-hooks"; exit 1; }

FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.claude/fleet/state"
SID=11111111-2222-3333-4444-555555555555
fail=0

# $1 struggling, $2 how many seconds ago the button was pressed ('' for never).
machine() {
    now=$(date +%s)
    [ -n "$2" ] && stop=",\"stop\":$((now - $2))" || stop=""
    printf '{"struggling":%s,"reason":"every core is busy","hogs":"","at":%s%s}' \
        "$1" "$now" "$stop" > "$FAKE/.claude/fleet/machine.json"
}

run() {
    printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"/tmp/t.jsonl"}' \
        "$SID" "$1" | HOME="$FAKE" sh "$HOOK" "$2"
}

check() {
    case "$3" in *'"continue":false'*) got=stop ;; *) got=quiet ;; esac
    if [ "$got" = "$2" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s — wanted %s, got %s: %s\n' "$1" "$2" "$got" "$3"; fail=1; fi
}

# The regression this file exists for. The press used to be read only while the verdict still
# said the machine was struggling, so a stop pressed during a spike was thrown away the second
# the spike passed — and the button had halted nothing.
machine false 5
check "a recovered machine still honours the press" stop "$(run PreToolUse running)"

rm -f "$FAKE/.claude/fleet/state/$SID.stopped"
machine true 5
check "PreToolUse, so the turn ends before the tool runs" stop  "$(run PreToolUse running)"
check "the same press, already honoured"                  quiet "$(run PreToolUse running)"

rm -f "$FAKE/.claude/fleet/state/$SID.stopped"
check "Notification is not a stopping point"              quiet "$(run Notification awaiting)"

machine true 400
check "a press older than its window"                     quiet "$(run PreToolUse running)"

machine true ''
check "no press at all"                                   quiet "$(run UserPromptSubmit running)"

[ $fail = 0 ] && echo "all good" || echo "FAILED"
exit $fail
