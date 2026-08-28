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

## Parent recheck 2026-08-28T02:10Z
Still **PARENT_UPLOAD_REQUIRED** (no stamped binaries on cloud). Product test tip:
`cursor/dtsx-damf-input-tbh-pop-3541` @ `c7021d6` (PR #27). NF DAMF encode blocker
fixed on that tip; TBH HW pops + byte-exact census still need Louis test + uploads.
See `UPLOAD_BLOCKED.md`.
