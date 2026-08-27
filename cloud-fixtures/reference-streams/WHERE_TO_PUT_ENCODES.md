# Canonical location for Louis's encode + master materials

**Naming rule (2026-08-27):** every uploaded binary MUST carry a UTC stamp
`YYYYMMDDTHHMMZ` in the filename, plus `UPLOAD_MANIFEST_<STAMP>.txt`.

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt
```

Cloud agents must record the newest stamp they find and must **not** silently
skip a missing upload.

## Sources (Mac)

| Role | Path |
| --- | --- |
| Encode-debug TBH | `/Users/sunyun_louis/Downloads/tbh.dtshd` |
| Encode-debug NF | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` |
| TBH IAB master | `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf` |

## Pop windows (TBH)

- `00:00:21:06`–`00:00:24:00`
- `00:02:51:00`–`00:02:56:00`

## Parent recheck 2026-08-27T07:22Z

Still **PARENT_UPLOAD_REQUIRED** (zero binaries on VM). See `UPLOAD_BLOCKED.md`
for stamped push commands. Controllable PCM remains on this branch under
`cloud-fixtures/test_X/`; grammar notes under `cloud-fixtures/perfect-stream-grammar/`.
