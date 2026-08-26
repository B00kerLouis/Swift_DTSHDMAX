# UPLOAD BLOCKED on parent cloud VM (2026-08-26)

Parent attempted again to git Louis's encodes from:
- `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd`

**Result:** paths do not exist on the cloud Linux VM (no `/Users`, no `/Volumes`).
Parent cannot `cp` or `git add` files that are not on this filesystem.

## Canonical destination (when Louis pushes from Mac)

```
cloud-fixtures/reference-streams/tbh.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
```

Branch: `cursor/cloud-materials-3541`

See `WHERE_TO_PUT_ENCODES.md` for Mac-side commands.
