# PARENT_UPLOAD_REQUIRED — encodes + TBH master

**Recheck:** 2026-08-27T06:31Z

Cloud VM has **zero** `*.dtshd` / `*.mxf` under `cloud-fixtures/reference-streams/`.

## Required for next child (TBH pop windows)

```bash
git checkout cursor/cloud-materials-3541
mkdir -p cloud-fixtures/reference-streams

cp "/Users/sunyun_louis/Downloads/tbh.dtshd" \
   cloud-fixtures/reference-streams/tbh.dtshd
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" \
   cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd

# TBH Atmos/IAB master (full or TC-window extract preferred if size blocks GitHub)
cp "/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf" \
   cloud-fixtures/reference-streams/QWER_TBH_IAB.mxf
# If full MXF is too large: upload an extract covering
#   00:00:20:00–00:00:25:00 and 00:02:50:00–00:02:57:00
# and note the cut in a README beside the file. Use Git LFS if needed.

git add -f cloud-fixtures/reference-streams/tbh.dtshd \
           cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd \
           cloud-fixtures/reference-streams/QWER_TBH_IAB.mxf
git commit -m "Add TBH/NF encode-debug streams and TBH IAB master for cloud agents"
git push origin cursor/cloud-materials-3541
```

## Hardware windows to analyze after upload
- `00:00:21:06`–`00:00:24:00`
- `00:02:51:00`–`00:02:56:00`

Do not invent binaries. Escalate PARENT_UPLOAD_REQUIRED — no silent pass.
