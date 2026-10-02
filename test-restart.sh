#!/usr/bin/env bash
# Drives the installed hook and fish function against a throwaway HOME and checks when a
# settings change relaunches a session and when it must not: an idle session is ended and
# resumed on the new model, a busy one is left alone until its turn ends, and nothing outside
# Fleet's `claude` function is ever ended. Run after `fleet --install-hooks`.
set -uo pipefail

HOOK="${1:-$HOME/.claude/fleet/session-state.sh}"
FISHFN="${2:-$HOME/.config/fish/functions/claude.fish}"
[ -x "$HOOK" ] || { echo "no hook at $HOOK — run: fleet --install-hooks"; exit 1; }
[ -f "$FISHFN" ] || { echo "no fish function at $FISHFN — run: fleet --install-hooks"; exit 1; }

FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.claude/fleet/state"
SID=11111111-2222-3333-4444-555555555555
fail=0

model() {
    printf '{"model":"%s","modelSettings":{"claude-opus-5-5":{"effortLevel":"xhigh"}}}' "$1" \
        > "$FAKE/.claude/settings.json"
}

# The stand-in claude is a copy of bash, so that `ps` names it claude as it does the real one.
cp /bin/bash "$FAKE/claude"

# Fires one hook the way Claude Code does: the hook is a child of the stand-in claude, itself a
# child of a stand-in shell that FLEET_SHELL names — unless $3 is "bare". The stand-in outlives
# the hook by LIFE seconds (2) and leaves `survived` behind unless it was ended first. BIN, when
# set, is the binary the stand-in claims to run.
fire() {
    rm -f "$FAKE/survived"
    rm -rf "$FAKE/.claude/fleet/restart"
    payload=$(printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"/tmp/t.jsonl"}' "$SID" "$1")
    HOME="$FAKE" HOOK="$HOOK" PAYLOAD="$payload" ARG="$2" BARE="${3:-}" LIFE="${LIFE:-2}" \
        CLAUDE_CODE_EXECPATH="${BIN:-}" sh -c '
        if [ -n "$BARE" ]; then unset FLEET_SHELL; else export FLEET_SHELL=$$; fi
        echo $$ > "$HOME/shell.pid"
        "$HOME/claude" -c "printf %s \"\$PAYLOAD\" | sh \"\$HOOK\" \"\$ARG\" >/dev/null; sleep \$LIFE; touch \"\$HOME/survived\""
    '
}

# A binary modified after the stand-in started, as a display patch would leave it.
patched() { touch -t "$(date -v+2M +%Y%m%d%H%M.%S)" "$FAKE/binary"; }

# $1 name, $2 "kept" or the arguments the relaunch should resume with.
check() {
    note="$FAKE/.claude/fleet/restart/$(cat "$FAKE/shell.pid")"
    if [ -f "$FAKE/survived" ] && [ ! -f "$note" ]; then got=kept
    elif [ ! -f "$FAKE/survived" ] && [ -f "$note" ]; then got=$(tr '\n' ' ' < "$note" | sed 's/ $//')
    else got="survived=$([ -f "$FAKE/survived" ] && echo y || echo n) note=$([ -f "$note" ] && echo y || echo n)"
    fi
    if [ "$got" = "$2" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s — wanted %s, got %s\n' "$1" "$2" "$got"; fail=1; fi
}

echo "hook: $HOOK"
model opus
fire SessionStart start
fire Stop ready;                 check "idle session, settings unchanged: left alone" kept
model fable
fire UserPromptSubmit running
fire ConfigChange config;        check "busy session when settings change: left alone" kept
fire Stop ready;                 check "busy session relaunched when its turn ends" "$SID --model fable"
fire SessionStart start
fire ConfigChange config;        check "resumed session is not relaunched again" kept
model opus
fire ConfigChange config;        check "idle session relaunched on a settings change" "$SID --model opus"
fire SessionStart start
model fable
fire Stop ready bare;            check "session outside the fish function never ended" kept

export BIN="$FAKE/binary"
touch -t 202001010000 "$BIN"
fire SessionStart start
fire Stop ready;                 check "binary older than the session: left alone" kept
patched
fire Stop ready;                 check "binary patched since the session started: relaunched" "$SID --model fable"
# An idle session fires no hook: the patcher's sweep has to reach it on its own.
touch -t 202001010000 "$BIN"
LIFE=4 fire Stop ready &
sleep 1
patched
HOME="$FAKE" sh "$HOOK" sweep </dev/null
wait
check "idle session reached by the patcher's sweep" "$SID --model fable"
unset BIN

# Claude Code no longer hands the binary to its hooks: it is read off the process. The stand-in
# becomes a version file, with `claude` on PATH pointing at it, as the native install lays them out.
V="$FAKE/share/claude/versions"
mkdir -p "$V" "$FAKE/.local/bin"
mv "$FAKE/claude" "$V/1.0.0"
cp "$V/1.0.0" "$V/1.0.1"
ln -s "$V/1.0.0" "$FAKE/claude"
ln -s "$V/1.0.0" "$FAKE/.local/bin/claude"
touch -t 202001010000 "$V/1.0.0"
touch -h -t 202001010000 "$FAKE/.local/bin/claude"
fire SessionStart start
fire Stop ready;                 check "binary read off the process, untouched: left alone" kept
touch -t "$(date -v+2M +%Y%m%d%H%M.%S)" "$V/1.0.0"
fire Stop ready;                 check "binary read off the process, patched since: relaunched" "$SID --model fable"
touch -t 202001010000 "$V/1.0.0"
ln -sfn "$V/1.0.1" "$FAKE/.local/bin/claude"
touch -h -t "$(date -v+2M +%Y%m%d%H%M.%S)" "$FAKE/.local/bin/claude"
fire Stop ready;                 check "claude points at a newer version since: relaunched" "$SID --model fable"
ln -sfn "$V/1.0.0" "$FAKE/.local/bin/claude"
touch -h -t 202001010000 "$FAKE/.local/bin/claude"

# A mod is read once, at launch, like the `env` entry that names it.
mkdir -p "$FAKE/mod/hooks" "$FAKE/mod/.claude-plugin/types"
echo one > "$FAKE/mod/hooks/register.tsx"
fire SessionStart start
printf '{"model":"fable","modelSettings":{"claude-opus-5-5":{"effortLevel":"xhigh"}},"env":{"CLAUDE_CODE_PLUGIN_DIRS":"~/mod"}}' \
    > "$FAKE/.claude/settings.json"
fire Stop ready;                 check "a mod named in settings since the session started: relaunched" "$SID --model fable"
fire SessionStart start
echo types > "$FAKE/mod/.claude-plugin/types/index.d.ts"
fire Stop ready;                 check "the types Claude Code writes into a mod: left alone" kept
echo two > "$FAKE/mod/hooks/register.tsx"
fire Stop ready;                 check "mod edited since the session started: relaunched" "$SID --model fable"
# The sessions that did not make the edit fire no hook for it: another session's turn ending does.
fire SessionStart start
LIFE=4 fire Stop ready &
sleep 1
echo three > "$FAKE/mod/hooks/register.tsx"
printf '{"session_id":"99999999-2222-3333-4444-555555555555","hook_event_name":"Stop"}' |
    HOME="$FAKE" sh "$HOOK" ready >/dev/null
wait
check "idle session reached when another session's turn ends after a mod edit" "$SID --model fable"

echo "fish: $FISHFN"
if command -v fish >/dev/null; then
    mkdir -p "$FAKE/bin"
    cat > "$FAKE/bin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/calls"
[ -n "${FLEET_SHELL:-}" ] && [ ! -f "$HOME/once" ] || exit 0
touch "$HOME/once"
mkdir -p "$HOME/.claude/fleet/restart"
printf '%s\n--model\nfable\n' 11111111-2222-3333-4444-555555555555 > "$HOME/.claude/fleet/restart/$FLEET_SHELL"
EOF
    chmod +x "$FAKE/bin/claude"
    try() {
        rm -f "$FAKE/calls" "$FAKE/once"
        HOME="$FAKE" PATH="$FAKE/bin:$PATH" fish --no-config -c "source '$FISHFN'; claude $1"
        got=$(tr '\n' '|' < "$FAKE/calls")
        if [ "$got" = "$2" ]; then printf '  ok    %s\n' "$3"
        else printf '  FAIL  %s — wanted %s, got %s\n' "$3" "$2" "$got"; fail=1; fi
    }
    try hello "hello|--resume $SID --model fable|" "ended session resumed once, on the new model"
    try "-p hi" "-p hi|" "claude -p is never resumed"
else
    echo "  FAIL  fish not found"; fail=1
fi

[ $fail = 0 ] && echo "all passed" || echo "FAILED"
exit $fail
