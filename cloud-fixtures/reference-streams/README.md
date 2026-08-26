# Reference / encode-debug streams (required for cloud agents)

Cloud VMs cannot mount Louis's Mac. Push the files below into **this directory**
on branch `cursor/cloud-materials-3541` (or onto the active feature branch), then
notify the parent agent to re-run.

## Required for this debug cycle

| Local file (Mac) | Commit as |
| --- | --- |
| `/Users/sunyun_louis/Downloads/tbh.dtshd` | `tbh.dtshd` — **new software encode** (TBH: first ~10s unplayable) |
| `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` | `Dolby_NaturesFury.dtshd` — **new software encode** (playable; control) |
| `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd` | `TBH_offical.dtshd` — official perfect TBH (if available) |

Optional but valuable: first 15s AU-aligned cuts if full titles are too large for GitHub.

## Suggested upload commands (on Mac, in repo)

```bash
git fetch origin
git checkout cursor/cloud-materials-3541
mkdir -p cloud-fixtures/reference-streams
cp "/Users/sunyun_louis/Downloads/tbh.dtshd" cloud-fixtures/reference-streams/
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" cloud-fixtures/reference-streams/
# optional official:
# cp "/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd" cloud-fixtures/reference-streams/
git add -f cloud-fixtures/reference-streams/*.dtshd
git commit -m "Add encode-debug and/or official reference .dtshd streams for cloud agents"
git push -u origin cursor/cloud-materials-3541
```

Use Git LFS if files exceed GitHub blob limits.
