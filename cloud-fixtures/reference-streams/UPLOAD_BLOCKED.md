# PARENT_UPLOAD_REQUIRED — encode binaries not on cloud

**Recheck:** 2026-08-27T05:29Z (parent orchestrator)

Cloud VM still cannot read:

- `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd`
- `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd`
- Research Nature’s Fury perfect delivery `.dtshd` (see `perfect-stream-grammar/`)

No `*.dtshd` under `cloud-fixtures/reference-streams/` on this branch.

**Hardware update:** NAVI-ladder tip branches render completely wrong. Next fix child
starts from `main` only and needs these binaries for byte-level perfect-stream
comparison. Please push from Mac (commands in `WHERE_TO_PUT_ENCODES.md`).

Child agents must **not** invent reference bitstreams. Use `test_X` + grammar
notes meanwhile and escalate PARENT_UPLOAD_REQUIRED — no silent pass.
