# Child brief — TBH pop rollback + reinvestigate (2026-08-28T09:00Z)

## Completed product tip (2026-08-28T09:30Z)
**Branch:** `cursor/dtsx-tbh-pop-rollback-restore-3541` @ `50c2f37` / **PR #30**
Input stage = `main` @ `08b4478` (DAMF mutations deferred). TBH IAB MXF path for HW test.

## Louis request (mandatory)
1. **Rollback baseline** to ~**2026-08-27 16:00** — Louis reports current tips (#27, #29) break **file input**; the ~16:00 baseline fixed **first-frame playback** and encodes normally.
2. **Clean abandoned PRs**; **integrate** already-proven fixes only; **continue** TBH pop investigation.
3. **TBH** simpler master as example. Pop windows (unchanged):
   - `00:00:21:06`–`00:00:24:00`
   - `00:02:51:00`–`00:02:56:00`
4. Find **render-time changes** in those windows that cause hardware pops. Prior PRs (#25–#27, #29) insufficient on hardware.
5. **No ffmpeg**. Verifiers ≠ 100% playback truth; bitstream can pass while audio pops — find unsafe encoder/renderer path.
6. **≥5 schemes** in doc + parent report; **择优** with reasons; implement ONLY 择优.
7. **Independent branch** `cursor/dtsx-tbh-pop-rollback-restore-3541` (create fresh; do not commit on main).
8. Model **`claude-fable-5-thinking-xhigh`**. Max 1 concurrent child.

## Baseline identification
- **`main` @ `08b4478`** (2026-08-27 00:47 UTC) — last main: bed-active silence + delivery startup grammar (first-frame fix). Closest git anchor to Louis's "16:00" rollback.
- **Do NOT** blindly keep PR #27/#29 DAMF changes if they regress Mac encode — validate against restored DAMF package on materials branch.
- **Closed tips to cherry-pick selectively** (only if encoder bytes stay safe / input works):
  - #23 grammar timeline + reference gate
  - #24 timecode-window mapping + pop-window census + motion vector
  - #25 corpus zero-plane declaration
  - #26 compact navigated NAVI width 11
- **Forbidden:** NAVI 11/13/14 ladder (#20/#22), onset ramps (#15/#16), ffmpeg anywhere.
- **Supersedes:** closed #27–#29; product tip is PR #30 (`cursor/dtsx-tbh-pop-rollback-restore-3541` @ `50c2f37`).

## Materials (fetch `origin/cursor/cloud-materials-3541`)
**Partial upload in progress** — do NOT silent-pass:
```text
docs/reference-streams/DTSX/segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-000..005  (need ..045)
docs/reference-streams/DTSX/segmented-archives/TBH-reference-streams.tar.gz.part-*  (NOT YET)
```
Restore per `docs/reference-streams/DTSX/ARCHIVES.md`. If archives incomplete, **escalate PARENT_UPLOAD_REQUIRED** to parent with exact missing parts + SHA checklist from `MATERIALS.md`.

Stamped legacy names still accepted by gate when present:
```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
```

TBH IAB master (Mac): `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf`

## Investigation workflow
1. Restore baseline branch off `main` @ `08b4478`.
2. Cherry-pick / re-land analysis tools + proven grammar fixes (list in schemes doc).
3. Assemble available materials; encode TBH from IAB/MXF or surrogate; run `map-dtsx-timecode-windows`, `analyze-dtsx-pop-windows`, render audit if present.
4. Diff grammar/render motion **inside pop windows** vs safe regions — identify declaration transitions correlated with pops.
5. Land **one** 择优 encoder/renderer fix; document deferred corpus-blocked items.

## Schemes — REQUIRED (≥5, refine OK)
| # | Scheme | Starter verdict |
| --- | --- | --- |
| 1 | Rollback to main@08b4478 + selective re-integration | likely 择优 foundation |
| 2 | DAMF sidecar resolution (audio/metadata/CAF order) | candidate ONLY if input broken |
| 3 | Render-window audit / signed-24 rail detection | candidate tool |
| 4 | ObjectGainSmoother / pan discontinuity at height onsets | REJECT if clean |
| 5 | Private prediction / reflection transitions in windows | candidate |
| 6 | Per-channel linear-0 beside dense planes (scheme 8 lineage) | candidate if census shows |
| 7 | NAVI 11/13/14 ladder | REJECT HW-failed |
| 8 | Heuristic onset ramps | REJECT |
| 9 | ExSS seam / public XLL residual | REJECT unless evidence |

## Deliverables
- Branch pushed: **`cursor/dtsx-tbh-pop-rollback-restore-3541`**
- Doc: `docs/schemes-tbh-pop-rollback-restore.md`
- PR (draft) with scheme table + test plan + PARENT_UPLOAD status
- English commits; HDMA+Core must stay bit-exact on controls
