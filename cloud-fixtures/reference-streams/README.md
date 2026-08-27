# Encode-debug / reference `.dtshd` (REQUIRED)

Cloud agents cannot read Louis's Mac. Push files into **this directory** on
`cursor/cloud-materials-3541` (Git LFS OK). First ~15s AU-aligned cuts suffice.

```bash
git checkout cursor/cloud-materials-3541
mkdir -p cloud-fixtures/reference-streams
cp "/Users/sunyun_louis/Downloads/tbh.dtshd" cloud-fixtures/reference-streams/
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" cloud-fixtures/reference-streams/
# optional: cp "/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd" cloud-fixtures/reference-streams/
git add -f cloud-fixtures/reference-streams/*.dtshd
git commit -m "Add encode-debug .dtshd streams for cloud agents"
git push origin cursor/cloud-materials-3541
```
