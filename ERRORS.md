# Errors

One line per mistake of mine: date, what I did wrong, what to do instead.

- 2026-10-12 — Ran `--bench-panel` eight times and a `--render` of the live fleet to compare two binaries, without reading what a run fetches; each one read the hub's Firestore collections whole, the day's 50k reads ran out on the last, and a Fleet restarted before 09:00 had no mail or todos to show — before a mode is run in rounds, read what it fetches: `--render` and `--bench-panel` now draw the kept copy (`Firestore.reads`), every other mode that builds a hub still reads, against the 35k a day Fleet allows itself.
