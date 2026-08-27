# Child brief — TBH render unsafe in pop windows (2026-08-27T0722Z)

## HARD RULES
- Branch off **`origin/main` @ `08b4478`**: create **`cursor/dtsx-tbh-render-unsafe-3541`**
- HDMA + Core OK — do not break
- **Do NOT** re-land NAVI 11/13/14 (HW-failed PR #20/#22)
- May cherry-pick **tools** from `cursor/dtsx-tbh-pop-windows-3541` (PR #24) / PR #23
- No ffmpeg; no silent pass; no invented binaries
- Atmos 母带 Object ≠ DTS:X/XLL-X objects

## Timestamped materials (MANDATORY)
After `git fetch origin cursor/cloud-materials-3541`, look for newest stamp files:

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt
```

`<STAMP>` = UTC `YYYYMMDDTHHMMZ` (example expected: `20260827T0722Z` if Louis used parent’s stamp).
**Record the stamp + uploadedAt in schemes doc.** If missing → **PARENT_UPLOAD_REQUIRED** with the stamp convention; escalate to parent; continue with `test_X` + grammar + PR #24 window tools. **Forbidden to silently skip.**

Legacy unstamped names (`tbh.dtshd` etc.) may appear; prefer newest stamped set.

Mac sources:
- `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd`
- `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf`

## Defect
TBH pop windows (24 fps mapping already on PR #24):
- `00:00:21:06`–`00:00:24:00` → stream AU ~1994–2252
- `00:02:51:00`–`00:02:56:00` → stream AU ~16033–16502

Find **unsafe render/encode** changes in these ranges that cause pops; implement a real fix (not only more instrumentation). Prefer perfect-stream-aligned grammar safety over heuristic ramps.

## Process
1. ≥5 schemes in `docs/schemes-tbh-render-unsafe.md`
2. 择优 + reasons; implement ONLY 择优
3. Native gates; honest results
4. `git push -u origin cursor/dtsx-tbh-render-unsafe-3541`
5. Final report: branch, schemes+择优, files, tests, model `claude-fable-5-thinking-xhigh`, material stamp / PARENT_UPLOAD status

English commits. Do not force-add Agent.md/Research/.
