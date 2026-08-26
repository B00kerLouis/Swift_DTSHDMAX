# Material brief for cloud subagent

## 1. Fetch materials + code tip
```
git fetch origin cursor/cloud-materials-3541 cursor/dtsx-atmos-object-onset-3541
```

## 2. Encode-debug streams (REQUIRED) — exact repo paths
After fetch/checkout of materials:
- `cloud-fixtures/reference-streams/tbh.dtshd` ← from `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` ← from Downloads Nature's Fury encode
- See `cloud-fixtures/reference-streams/WHERE_TO_PUT_ENCODES.md`

If these `.dtshd` files are missing: write/update `PARENT_UPLOAD_REQUEST.md`, set **PARENT_UPLOAD_REQUIRED** in final report, do **not** silent-pass bitstream对照 against Louis's encodes. Continue with controllable vectors + Atmos render unsafe-path hunt.

## 3. Also available
- `cloud-fixtures/test_X/pcm-sources/` controllable 7.1.4 PCM
- `cloud-fixtures/perfect-stream-grammar/` NF grammar notes
- Code tip: `origin/cursor/dtsx-atmos-object-onset-3541`

## 4. Hardware sync
- NF playable; TBH first ~10s still broken
- 爆音 **more** than previous tip
- Correlate: **Atmos master objects** (not DTS:X/XLL-X objects); nearer Atmos-object onset/head → more pops
- Hunt remaining unsafe implementations in Atmos→7.1.4 and encode handoff
