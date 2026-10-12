# Progress

- Done (2026-10-12): groups that fit come up unfolded in the grid; Firestore reads are kept, counted and capped (`Firestore.collection`). Committed and pushed, not installed: the day's reads were spent, and a Fleet restarted before 09:00 on 2026-10-13 comes up without mail or todos.
- Next: `./install.sh` then `./test-stop-hook.sh` once 09:00 has passed; check that `~/.claude/fleet/hub` fills (four `.json` and `reads`) and count the documents in each. That count is what a load costs, and what a server-side filter on `mail` and `todos` would save.
