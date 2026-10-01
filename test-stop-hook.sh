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
    printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"/tmp/t.jsonl","message":"%s"}' \
        "$SID" "$1" "${3:-}" | HOME="$FAKE" sh "$HOOK" "$2"
}

# $1 name, $2 the state the hook should have left on disk. Reads the file the panel reads, not
# the hook's stdout: the colour of a session comes from there and nowhere else.
wrote() {
    got=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$FAKE/.claude/fleet/state/$SID.json")
    if [ "$got" = "$2" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s — wanted state %s, got %s\n' "$1" "$2" "$got"; fail=1; fi
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

# The other decision worth replaying: Claude Code fires the same event for "I need your
# permission" and for "you have been idle a while", and they mean opposite things. Only the
# text tells them apart, so the panel's blue and its green both hang off this match.
run Notification awaiting "Claude needs your permission to use Bash" >/dev/null
wrote "a permission prompt leaves the session waiting"    awaiting
run Notification awaiting "Claude is waiting for your input" >/dev/null
wrote "an idle nudge leaves the session ready"            ready

# A sub-agent's tool call carries its parent's session id. An async agent or a workflow still
# working must not turn its idle parent back to running.
printf '{"session_id":"%s","agent_id":"a62a2fb6","hook_event_name":"PreToolUse","transcript_path":"/tmp/t.jsonl"}' \
    "$SID" | HOME="$FAKE" sh "$HOOK" running >/dev/null
wrote "a sub-agent's tool call leaves its parent ready"   ready

machine true 400
check "a press older than its window"                     quiet "$(run PreToolUse running)"

machine true ''
check "no press at all"                                   quiet "$(run UserPromptSubmit running)"

# Jarvis: a Stop held until Jarvis, an app of its own, answers. Each Stop fires the way test-restart.sh fires one —
# the hook under a stand-in claude under a stand-in fish that FLEET_SHELL names — in a session
# of its own, so no terminal is attached whoever runs this. The settings changed since the
# session started, so a Stop that falls through to the normal flow relaunches the session.
# Nothing here refreshes jarvis.on, so a hold that goes wrong ends by itself within 10 s.
S="$FAKE/.claude/fleet/state"
rm -f "$FAKE/.claude/fleet/machine.json"
printf '{"model":"opus"}' > "$FAKE/.claude/settings.json"
run SessionStart start >/dev/null
printf '{"model":"fable"}' > "$FAKE/.claude/settings.json"
# The stand-in claude is a copy of bash, so that `ps` names it claude as it does the real one.
cp /bin/bash "$FAKE/claude"
cat > "$FAKE/claude.sh" <<'EOF'
printf '%s' "$PAYLOAD" | sh "$HOOK" ready > "$HOME/out"
echo $? > "$HOME/code"
sleep 2; touch "$HOME/survived"
EOF
# $1 the stand-in tty ('' for none), $2 stop_hook_active. Runs in the background: $stopper.
stop() {
    rm -rf "$FAKE/survived" "$FAKE/out" "$FAKE/code" "$FAKE/.claude/fleet/restart"
    payload=$(printf '{"session_id":"%s","hook_event_name":"Stop","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/proj","stop_hook_active":%s,"last_assistant_message":"%s"}' \
        "$SID" "${2:-false}" 'Done — «prêt» \"quoted\" \\ back\nline 2')
    HOME="$FAKE" HOOK="$HOOK" PAYLOAD="$payload" TTYV="$1" /usr/bin/perl -MPOSIX \
        -e 'POSIX::setsid(); exec @ARGV' -- sh -c '
        export FLEET_SHELL=$$; echo $$ > "$HOME/shell.pid"
        [ -z "$TTYV" ] || export FLEET_TEST_TTY="$TTYV"
        "$HOME/claude" "$HOME/claude.sh"; true' 2>/dev/null &
    stopper=$!
}
asked() { for _ in $(seq 50); do [ -f "$S/$SID.ask" ] && return 0; sleep 0.1; done; return 1; }
prompt() { for _ in $(seq 30); do [ -f "$FAKE/code" ] && return 0; sleep 0.1; done; return 1; }
ok() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=1; fi; }
relaunched() { [ ! -f "$FAKE/survived" ] && [ -f "$FAKE/.claude/fleet/restart/$(cat "$FAKE/shell.pid")" ]; }
fresh() { touch "$S/jarvis.on"; }
# $1 a JSON file, $2 a perl expression over $j, the decoded object. Strings stay UTF-8 bytes,
# the way the literals in $2 are.
json() { /usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); exit !(eval $ARGV[0])' "$2" < "$1"; }

rm -f "$S/jarvis.on"
stop ttys999; prompt && held=n || held=y; wait $stopper
ok "jarvis off: no hold, relaunched as before"        '[ $held = n ] && [ ! -s "$FAKE/out" ] && relaunched'

fresh; stop ''; prompt && held=n || held=y; wait $stopper
ok "jarvis on, no tty: no hold, relaunched as before" '[ $held = n ] && [ ! -s "$FAKE/out" ] && relaunched'

fresh; stop ttys999 true; prompt && held=n || held=y; wait $stopper
ok "stop_hook_active: never held twice in one turn"   '[ $held = n ] && [ ! -s "$FAKE/out" ] && relaunched'

fresh; stop ttys999
ok "jarvis on + tty: the question is asked"           asked
ok "  naming the session, the hook, the message"      "json '$S/$SID.ask' '
    \$j->{sid} eq \"$SID\" && \$j->{hook_pid} > 0 && kill(0, \$j->{hook_pid}) && \$j->{claude_pid} > 0
    && \$j->{cwd} eq \"/tmp/proj\" && \$j->{transcript} eq \"/tmp/t.jsonl\" && \$j->{at} > 0
    && \$j->{last_message} eq \"Done — «prêt» \\\"quoted\\\" \\\\ back\\nline 2\"'"
printf 'Go with: ré-essaie "x" \\ C:\\tmp\nline 2\n' > "$S/$SID.answer.tmp"
mv "$S/$SID.answer.tmp" "$S/$SID.answer"
wait $stopper
ok "  an answer blocks the stop, with it as reason"   "json '$FAKE/out' '
    \$j->{decision} eq \"block\" && \$j->{reason} eq \"Go with: ré-essaie \\\"x\\\" \\\\ C:\\\\tmp\\nline 2\"'"
ok "  and the session is not relaunched"              '[ -f "$FAKE/survived" ] && [ ! -f "$S/$SID.ask" ] && [ ! -f "$S/$SID.answer" ]'

fresh; stop ttys999; asked; : > "$S/$SID.answer"; wait $stopper
ok "an empty answer: released, relaunched as before"  '[ ! -s "$FAKE/out" ] && [ ! -f "$S/$SID.ask" ] && relaunched'

fresh; stop ttys999; asked
touch -t "$(date -r $(($(date +%s) - 30)) +%Y%m%d%H%M.%S)" "$S/jarvis.on"
wait $stopper
ok "jarvis.on going stale releases the hold"          '[ ! -s "$FAKE/out" ] && [ ! -f "$S/$SID.ask" ] && relaunched'

fresh; stop ttys999; asked
kill -TERM "$(/usr/bin/perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{hook_pid}' < "$S/$SID.ask")"
wait $stopper
ok "SIGTERM (Esc) takes the question back, exit 0"    '[ ! -f "$S/$SID.ask" ] && [ "$(cat "$FAKE/code")" = 0 ]'

[ $fail = 0 ] && echo "all good" || echo "FAILED"
exit $fail
