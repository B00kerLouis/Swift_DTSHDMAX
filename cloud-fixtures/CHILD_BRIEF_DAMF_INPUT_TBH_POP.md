# Child brief — DAMF input fix + TBH pops continued (2026-08-28T0124Z)

## Louis branch confirmation
**Completed product tip:** **`cursor/dtsx-damf-input-tbh-pop-3541`** @ **`c7021d6`** (PR #27).
Integrates closed #25/#26 work + DAMF audio fallback + stamped reference gate.
**Prior tip:** `cursor/dtsx-tbh-window-pop-continued-3541` @ `c3ccbdf` (PR #26 closed).

## BLOCKER — Nature's Fury encode (must fix)
Louis cannot test because:
```text
hdmax -i "/Volumes/HP_SSD_FX900_Pro /Dolby_NaturesFury/Dolby_NaturesFury_DAMF/Dolby_NaturesFury_.atmos" \
      -o /Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd
error: cannot open .../Dolby_NaturesFury_ADM_BWF.atmos.audio: doesn't exist
```
Manifest references missing audio. Fix `AtmosMasterReader` / `AtmosInputReader` to resolve sibling CAF or ADM BWF `.wav` when manifest audio is absent, with a clear error listing directory contents if ambiguous. **Do not silently change user's input path** — auto-fallback only when unambiguous.

TBH master path: `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf`

## Hardware defect (still open)
TBH pop windows **still not fixed** after integrated tips:
- `00:00:21:06`–`00:00:24:00`
- `00:02:51:00`–`00:02:56:00`

Integrate from closed `cursor/dtsx-tbh-window-pop-continued-3541`:
- Window tools, grammar timeline, reference gate
- Corpus zero-plane declaration
- Compact navigated NAVI width 11 repair

Then find **remaining** unsafe path. No NAVI 11/13/14 ladder re-land. No ffmpeg.

## Timestamped materials (mandatory — no silent skip)
After `git fetch origin cursor/cloud-materials-3541`:
```text
tbh_<STAMP>.dtshd
Dolby_NaturesFury_<STAMP>.dtshd
QWER_TBH_IAB_<STAMP>.mxf
UPLOAD_MANIFEST_<STAMP>.txt
```
Example stamp: `20260828T0124Z`. Record in schemes doc. PARENT_UPLOAD_REQUIRED if missing.

## Schemes — REQUIRED in doc + final report (≥5)
Starter menu (refine OK; must list all with verdict):
| # | Scheme | Starter verdict |
| --- | --- | --- |
| 1 | DAMF audio path fallback (CAF / ADM wav) | likely 择优 component |
| 2 | ObjectGainSmoother / pan discontinuity | REJECT if re-audited clean |
| 3 | RenderGuard / plane handoff | REJECT if clean |
| 4 | Private prediction / reflection transitions | candidate |
| 5 | Public XLL residual vs height onsets | REJECT if pinned |
| 6 | ExSS seam | REJECT unless evidence |
| 7 | NAVI 11/13/14 ladder | REJECT HW-failed |
| 8 | Heuristic onset ramps | REJECT |
| 9 | Further NAVI width / silence form issues | candidate if census shows |

Implement ONLY 择优. Push branch. Model `claude-fable-5-thinking-xhigh`.
