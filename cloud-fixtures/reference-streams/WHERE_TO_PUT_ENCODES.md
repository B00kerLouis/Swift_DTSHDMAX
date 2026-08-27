# Canonical location for Louis's new software encodes

Cloud agents **must** read these paths after `git fetch origin cursor/cloud-materials-3541`:

```
cloud-fixtures/reference-streams/tbh.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
```

Optional official perfect TBH:

```
cloud-fixtures/reference-streams/TBH_offical.dtshd
```

## Parent status (2026-08-26)

Parent cloud VM cannot mount `/Users/sunyun_louis/Downloads` or `/Volumes/...`.
Files were **not** present on the VM, so they could not be committed from the parent.
Louis must run the Mac-side commands below, then ask the parent to re-spawn the child.

## Mac-side upload (run on Louis's machine)

```bash
cd /path/to/Swift_DTSHDMAX
git fetch origin
git checkout cursor/cloud-materials-3541
mkdir -p cloud-fixtures/reference-streams
cp "/Users/sunyun_louis/Downloads/tbh.dtshd" \
   cloud-fixtures/reference-streams/tbh.dtshd
cp "/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd" \
   cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
# optional:
# cp "/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd" \
#    cloud-fixtures/reference-streams/TBH_offical.dtshd
git add -f cloud-fixtures/reference-streams/*.dtshd
git commit -m "Add encode-debug tbh and Nature's Fury dtshd for cloud agents"
git push origin cursor/cloud-materials-3541
```

Use Git LFS if GitHub rejects large blobs. First ~15s AU-aligned cuts are enough.

## Parent re-check 2026-08-26T07:15Z

Local + cloud VM full-filesystem search: **NOT_FOUND** for
`/Users/sunyun_louis/Downloads/tbh.dtshd` and
`/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd`.
No `/Users` or `/Volumes` mounts. Parent cannot commit binaries it cannot read.
Louis must push from Mac using the commands above, then ask parent to re-fetch.

## Parent re-check 2026-08-27T01:37Z

Still **PARENT_UPLOAD_REQUIRED**. `find` over `/workspace`, `/tmp`, `/opt`, `/home`
found **zero** `*.dtshd`. Materials branch carries docs + `test_X` + grammar only.
Latest encode-debug paths Louis named (branch-updating software encodes):

```text
/Users/sunyun_louis/Downloads/tbh.dtshd
/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd
```

→ must land as:

```text
cloud-fixtures/reference-streams/tbh.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
```

on `cursor/cloud-materials-3541` via Mac-side `cp` + `git add -f` + push (see above).

## Parent re-check 2026-08-27T05:29Z

Still **PARENT_UPLOAD_REQUIRED** (zero `*.dtshd` on VM). Hardware rejected both
NAVI-ladder tip branches as fully wrong render; next child needs byte-level
perfect-stream diffs. Upload priority unchanged — push Downloads encodes first.
