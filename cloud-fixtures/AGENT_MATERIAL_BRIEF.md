# Cloud subagent material brief (parent → child)

## Fetch first
```
git fetch origin cursor/cloud-materials-3541 cursor/dtsx-five-scheme-object-safety-3541
```

## Already available via git
| Path | Use |
| --- | --- |
| `cloud-fixtures/test_X/pcm-sources/` | Controllable 7.1.4 PCM (mute/sine/impulse/walk/fullscale/…) |
| `cloud-fixtures/perfect-stream-grammar/` | Nature's Fury grammar notes + MANIFEST |
| `docs/reference-streams/DTSX/` | Staging docs / memory excerpts |
| `docs/dtsx-active-start-safety-schemes.md` on five-scheme tip | Prior 6 schemes; **爆音量未明显再降** — do not only re-ship Scheme 1 |

## Required encode-debug streams (Louis Mac → must be under reference-streams/)
These are **new software encodes** (not necessarily official Encoder Suite output):

| Commit as | Source on Louis Mac | Role |
| --- | --- | --- |
| `cloud-fixtures/reference-streams/tbh.dtshd` | `/Users/sunyun_louis/Downloads/tbh.dtshd` | Failing encode: first ~10s bad; Object-onset 爆音 worst near programme start |
| `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` | Playable control encode |
| `cloud-fixtures/reference-streams/TBH_offical.dtshd` | `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd` | Official perfect TBH if available |

Parent VM cannot mount `/Users` or `/Volumes`. If files absent after fetch: escalate PARENT_UPLOAD_REQUIRED — do not silent-pass.

## Latest hardware symptom to sync
- NF playable; TBH first ~10s still broken (prior five-scheme tip insufficient)
- 爆音量 ≈ last version (not much better)
- Object data: **closer to object onset / programme head → higher pop probability**; later playback stabilizes
