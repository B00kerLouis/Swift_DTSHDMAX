# Canonical location for Louis's encode + master materials

**Naming rule:** every uploaded binary MUST carry UTC stamp `YYYYMMDDTHHMMZ`
in the filename, plus `UPLOAD_MANIFEST_<STAMP>.txt`. Silent skip forbidden.

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt
```

## Sources (Mac)
| Role | Path |
| --- | --- |
| Encode-debug TBH | `/Users/sunyun_louis/Downloads/tbh.dtshd` |
| Encode-debug NF | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` |
| TBH IAB master | `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf` |

## Pop windows
- `00:00:21:06`–`00:00:24:00`
- `00:02:51:00`–`00:02:56:00`

## Parent recheck 2026-08-28T09:30Z
**PARENT_UPLOAD_REQUIRED** — continue segmented archive upload (DAMF parts 006–045,
TBH reference parts 000–056). Product test tip:
`cursor/dtsx-tbh-pop-rollback-restore-3541` @ `50c2f37` (PR #30). See `UPLOAD_BLOCKED.md`.
