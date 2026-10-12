# Errors

One line per mistake of mine: date, what I did wrong, what to do instead.

- 2026-10-12 — Ran `--bench-panel` eight times and a `--render` of the live fleet to compare two binaries, without reading what a run fetches; each one reads the hub's Firestore collections whole, the day's 50k reads ran out on the last, and a Fleet restarted before 09:00 comes up with MAIL and TODO offline — a run that is not `--fake` is a metered read on the quota the phone shares: render with `--fake`, and count the bench rounds before the first one.
