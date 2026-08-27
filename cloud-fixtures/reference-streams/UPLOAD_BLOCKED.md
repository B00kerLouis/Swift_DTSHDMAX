# PARENT_UPLOAD_REQUIRED — encode binaries not on cloud

**Recheck:** 2026-08-27T01:37Z (parent orchestrator)

Cloud VM still cannot read:

- `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd`
- `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd`

No `*.dtshd` under `cloud-fixtures/reference-streams/` on this branch yet.

Child agents must **not** invent reference bitstreams. Use:

1. `cloud-fixtures/test_X/` controllable vectors (present)
2. `cloud-fixtures/perfect-stream-grammar/` recovered grammar notes
3. Escalate to parent / Louis Mac push (commands in `WHERE_TO_PUT_ENCODES.md`)

After Louis pushes binaries to this branch, parent will re-fetch and re-brief the next child.
