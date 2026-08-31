# PARENT_UPLOAD_REQUIRED — timestamped materials

**Recheck:** 2026-08-28T09:30Z  
**Example stamp:** `20260828T0930Z`

Cloud VM: **zero** stamped `*.dtshd` / `*.mxf` in `reference-streams/`. Silent skip forbidden.

## Partial segmented archives (materials branch)
- `Dolby_NaturesFury_DAMF.tar.gz.part-000`–`005` present; **parts 006–045 missing**
- `TBH-reference-streams.tar.gz.part-*` — **all 57 parts missing**

Product test tip: `cursor/dtsx-tbh-pop-macos-ci-3541` @ `2f12b6c` (PR #32).
Default seam: bridged-zero-gaps; A/B: `--private-seam-mode compact|sticky-rice-zero-gaps`.

## Required stamped names
```text
tbh_<STAMP>.dtshd
Dolby_NaturesFury_<STAMP>.dtshd
QWER_TBH_IAB_<STAMP>.mxf
UPLOAD_MANIFEST_<STAMP>.txt
```

Mac push: see `WHERE_TO_PUT_ENCODES.md`. Product tip: PR #30 (`cursor/dtsx-tbh-pop-rollback-restore-3541`).
