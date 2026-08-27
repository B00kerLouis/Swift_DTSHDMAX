# PARENT_UPLOAD_REQUIRED — timestamped materials

**Parent recheck:** 2026-08-27T07:22Z  
**Requested stamp example:** `20260827T0722Z` (Louis may use a newer `date -u +%Y%m%dT%H%MZ`)

Cloud VM still has **zero** stamped (and unstamped) `*.dtshd` / `*.mxf` under
`cloud-fixtures/reference-streams/`. **Silent skip is forbidden.**

## Naming contract (required)

Every uploaded binary MUST include a UTC stamp in the filename and a matching manifest:

```text
tbh_<STAMP>.dtshd
Dolby_NaturesFury_<STAMP>.dtshd
QWER_TBH_IAB_<STAMP>.mxf          # or window extracts with same STAMP
UPLOAD_MANIFEST_<STAMP>.txt       # must contain uploadedAtUTC=<STAMP>
```

## Mac push (Louis)

```bash
git fetch origin && git checkout cursor/cloud-materials-3541 && git pull
mkdir -p cloud-fixtures/reference-streams
STAMP=$(date -u +%Y%m%dT%H%MZ)
cp "/Users/sunyun_louis/Downloads/tbh.dtshd" \
   "cloud-fixtures/reference-streams/tbh_${STAMP}.dtshd"
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" \
   "cloud-fixtures/reference-streams/Dolby_NaturesFury_${STAMP}.dtshd"
cp "/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf" \
   "cloud-fixtures/reference-streams/QWER_TBH_IAB_${STAMP}.mxf"
printf 'uploadedAtUTC=%s\nsources=Downloads tbh+NF; Volumes QWER_TBH_IAB.mxf\npopWindows=00:00:21:06-00:00:24:00;00:02:51:00-00:02:56:00\n' "$STAMP" \
  > "cloud-fixtures/reference-streams/UPLOAD_MANIFEST_${STAMP}.txt"
git add -f cloud-fixtures/reference-streams/*_${STAMP}.* \
           "cloud-fixtures/reference-streams/UPLOAD_MANIFEST_${STAMP}.txt"
git commit -m "Add timestamped TBH/NF encodes and TBH IAB master (${STAMP})"
git push origin cursor/cloud-materials-3541
```

If MXF is too large for GitHub, upload TC extracts covering
`00:00:20:00`–`00:00:25:00` and `00:02:50:00`–`00:02:57:00` with the same
`STAMP` in filenames and note the cut in the manifest.
