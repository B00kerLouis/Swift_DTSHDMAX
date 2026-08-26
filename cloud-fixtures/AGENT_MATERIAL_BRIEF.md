# Material brief for cloud subagent (2026-08-26)

## Fetch
```
git fetch origin cursor/cloud-materials-3541 cursor/dtsx-tbh-firstframe-atmos-3541
```

## AVAILABLE NOW (parent pushed — USE THESE)
| Path | Role |
| --- | --- |
| `cloud-fixtures/test_X/pcm-sources/` | Controllable 7.1.4 PCM vectors (ALL_MUTE, ALL_SINE, impulses, CHANNEL_WALK, FULLSCALE, LFH_*, SILENCE, FRAME_EDGE, …) — **134 files** |
| `cloud-fixtures/test_X/MANIFEST.json` | Vector inventory |
| `cloud-fixtures/perfect-stream-grammar/` | Nature's Fury perfect-stream grammar notes + MANIFEST |
| `cloud-fixtures/PROJECT_MEMORY.md` | Project memory |
| `docs/reference-streams/DTSX/` | Staging docs (if checked out) |
| Code tip | `origin/cursor/dtsx-tbh-firstframe-atmos-3541` |

## MISSING — PARENT_UPLOAD_REQUIRED (Mac Downloads not on cloud VM)
Louis's branch-updated **software encodes** (refresh each tip):
- Desired repo path: `cloud-fixtures/reference-streams/tbh.dtshd` ← `/Users/sunyun_louis/Downloads/tbh.dtshd`
- Desired repo path: `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` ← Downloads NF encode
See `reference-streams/WHERE_TO_PUT_ENCODES.md`. Parent cannot mount `/Users`. Do not silent-pass encode bitstream对照.

## Hardware sync (critical)
1. NF playable; **TBH first frame still unplayable**
2. Click/Clip + 爆音; **this tip: 没有任何进展也没有任何退步** (flat vs previous)
3. Atmos **master** Object onset/fast-move correlate (NOT DTS:X/XLL-X objects)
4. Louis insight: **same downmix → 7.1 DTSHD/XLL compatibility bed is OK; only DTS:X path fails** → prefer defects unique to DTS:X (XLL-X heights, private grammar, DTS:X packaging/priming interaction with heights), not shared Core/7.1 HDMA fold
5. No ffmpeg; hunt remaining unsafe DTS:X-only implementations
