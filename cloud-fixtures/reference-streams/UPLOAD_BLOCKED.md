# PARENT_UPLOAD_REQUIRED — timestamped materials

**Recheck:** 2026-08-28T01:24Z  
**Example stamp:** `20260828T0124Z`

Cloud VM: **zero** `*.dtshd` / `*.mxf`. Silent skip forbidden.

## Encode blocker (Louis Mac — fixed on product tip)
Nature's Fury DAMF manifest `Dolby_NaturesFury_.atmos` references missing
`Dolby_NaturesFury_ADM_BWF.atmos.audio`. **Fixed** on `cursor/dtsx-damf-input-tbh-pop-3541`
@ `c7021d6` (PR #27): unambiguous sibling CAF or ADM BWF WAVE fallback.
Louis can re-encode NF from the DAMF folder; stamped uploads still required for cloud census.

## Required stamped names
```text
tbh_<STAMP>.dtshd
Dolby_NaturesFury_<STAMP>.dtshd
QWER_TBH_IAB_<STAMP>.mxf
UPLOAD_MANIFEST_<STAMP>.txt
```

Mac push: see `WHERE_TO_PUT_ENCODES.md`. PR #26 closed; new tip `cursor/dtsx-damf-input-tbh-pop-3541`.
