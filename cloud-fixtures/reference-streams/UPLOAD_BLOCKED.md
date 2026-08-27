# PARENT_UPLOAD_REQUIRED — timestamped materials

**Recheck:** 2026-08-27T09:08Z  
**Example stamp:** `20260827T0908Z` (or newer `date -u +%Y%m%dT%H%MZ`)

Local + cloud search: **zero** `*.dtshd` / `*.mxf`. Silent skip forbidden.

## Required names
```text
tbh_<STAMP>.dtshd
Dolby_NaturesFury_<STAMP>.dtshd
QWER_TBH_IAB_<STAMP>.mxf
UPLOAD_MANIFEST_<STAMP>.txt   # uploadedAtUTC=<STAMP>
```

## Mac push
```bash
git checkout cursor/cloud-materials-3541 && git pull
mkdir -p cloud-fixtures/reference-streams
STAMP=$(date -u +%Y%m%dT%H%MZ)
cp "/Users/sunyun_louis/Downloads/tbh.dtshd" "cloud-fixtures/reference-streams/tbh_${STAMP}.dtshd"
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" "cloud-fixtures/reference-streams/Dolby_NaturesFury_${STAMP}.dtshd"
cp "/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf" "cloud-fixtures/reference-streams/QWER_TBH_IAB_${STAMP}.mxf"
printf 'uploadedAtUTC=%s\npopWindows=00:00:21:06-00:00:24:00;00:02:51:00-00:02:56:00\n' "$STAMP" \
  > "cloud-fixtures/reference-streams/UPLOAD_MANIFEST_${STAMP}.txt"
git add -f cloud-fixtures/reference-streams/*_${STAMP}.* \
           "cloud-fixtures/reference-streams/UPLOAD_MANIFEST_${STAMP}.txt"
git commit -m "Add timestamped TBH/NF encodes and TBH IAB master (${STAMP})"
git push origin cursor/cloud-materials-3541
```

PR cleanup: #20–#25 product tips closed; materials PR #21 remains.
