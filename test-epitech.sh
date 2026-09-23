#!/bin/sh
# Ce que la barre d'alerte doit dire, pour chaque forme que peuvent prendre state.json et
# sources.json. La seule décision non évidente du fichier : un rescan qui répare le scan
# réfute le verdict du scan, et lui seul — outlook, discord, edsquare et l'agenda n'ont pas
# été rejoués et leur code tient toujours.
set -e
BIN="$(dirname "$0")/.build/release/fleet"
[ -x "$BIN" ] || BIN="$HOME/Applications/Fleet.app/Contents/MacOS/fleet"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
fail=0

# $1 titre · $2 generatedAt · $3 sessionOk · $4 contenu de sources.json (vide = pas de fichier)
# $5 morceau attendu dans la ligne « trouble: »
case_is() {
  printf '{"generatedAt":"%s","sessionOk":%s,"errors":[],"registrations":[],"deadlines":[]}\n' \
    "$2" "$3" > "$DIR/state.json"
  if [ -n "$4" ]; then printf '%s\n' "$4" > "$DIR/sources.json"; else rm -f "$DIR/sources.json"; fi
  got=$("$BIN" --epitech "$DIR/state.json" 2>/dev/null | sed -n 's/^trouble: //p')
  case "$got" in
    *"$5"*) printf '  ok    %s\n' "$1" ;;
    *) printf '  FAIL  %s\n        attendu: %s\n        obtenu : %s\n' "$1" "$5" "$got"; fail=1 ;;
  esac
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD=$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)

case_is "un rescan réparateur fait taire le scan" \
  "$NOW" true '{"at":"'"$OLD"'","scan":5,"edsquare":0,"outlook":0,"discord":null,"calendar":0}' \
  "none"
case_is "mais pas outlook, que personne n'a rejoué" \
  "$NOW" true '{"at":"'"$OLD"'","scan":5,"edsquare":0,"outlook":1,"discord":null,"calendar":0}' \
  "outlook unreachable"
case_is "un run cassé qui n'a pas été rejoué parle" \
  "$OLD" true '{"at":"'"$NOW"'","scan":5,"edsquare":0,"outlook":0,"discord":null,"calendar":0}' \
  "epitech scan failed"
case_is "seul un 3 est un jeton mort" \
  "$OLD" true '{"at":"'"$NOW"'","scan":0,"edsquare":0,"outlook":3,"discord":null,"calendar":0}' \
  "outlook token expired"
case_is "edsquare en panne se dit" \
  "$OLD" true '{"at":"'"$NOW"'","scan":0,"edsquare":6,"outlook":0,"discord":null,"calendar":0}' \
  "edsquare unreachable"
case_is "sans verdicts, l'état parle tout seul" \
  "$NOW" false '' "session expired"
case_is "deux lecteurs à terre sans jeton mort, c'est le wifi" \
  "$OLD" true '{"at":"'"$NOW"'","scan":4,"edsquare":6,"outlook":1,"discord":null,"calendar":1}' \
  "no network at the last run"
case_is "un jeton mort parle même si tout est tombé avec lui" \
  "$OLD" true '{"at":"'"$NOW"'","scan":0,"edsquare":6,"outlook":3,"discord":null,"calendar":1}' \
  "outlook token expired"
case_is "un run sain ne dit rien" \
  "$NOW" true '{"at":"'"$NOW"'","scan":0,"edsquare":0,"outlook":0,"discord":null,"calendar":0}' \
  "none"

[ $fail -eq 0 ] && echo "all good" || { echo "des cas cassés"; exit 1; }
