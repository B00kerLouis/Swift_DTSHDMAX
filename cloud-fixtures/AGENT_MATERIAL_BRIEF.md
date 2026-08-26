# Cloud subagent material brief (parent → child) — 2026-08-26

## Fetch
```
git fetch origin cursor/cloud-materials-3541 cursor/dtsx-object-onset-pop-3541
```

## Available via git now
| Path | Use |
| --- | --- |
| `cloud-fixtures/test_X/pcm-sources/` | Controllable 7.1.4 PCM vectors |
| `cloud-fixtures/perfect-stream-grammar/` | Nature's Fury grammar notes |
| Code tip | `origin/cursor/dtsx-object-onset-pop-3541` (height onset conditioner) |

## REQUIRED encode-debug streams (still often missing)
Louis's **new software encodes** — copy from Mac into this repo:

| Repo path | Mac path |
| --- | --- |
| `cloud-fixtures/reference-streams/tbh.dtshd` | `/Users/sunyun_louis/Downloads/tbh.dtshd` |
| `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` |
| `cloud-fixtures/reference-streams/TBH_offical.dtshd` (optional perfect) | `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd` |

Parent VM **cannot** mount `/Users` or `/Volumes`. If absent → PARENT_UPLOAD_REQUIRED, do not silent-pass.

## Hardware sync (critical)
- NF playable; TBH first ~10s still broken
- **爆音量相对上一版更多** (onset-pop tip may have worsened pops — reconsider O1/O2)
- Correlate: **Atmos master objects** (DAMF/IAB/ADM essence + metadata), **NOT** DTS:X/XLL-X "objects". Do not confuse.
- Closer to Atmos-object **onset / programme head** → higher pop rate; later stabilizes
