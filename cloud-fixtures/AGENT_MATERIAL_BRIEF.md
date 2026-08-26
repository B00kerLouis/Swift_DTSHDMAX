# Material brief (2026-08-26 — post xllx-only tip)

## Fetch
```
git fetch origin cursor/cloud-materials-3541 cursor/dtsx-xllx-only-defect-3541
```

## AVAILABLE (parent pushed — USE)
| Path | Role |
| --- | --- |
| `cloud-fixtures/test_X/pcm-sources/` | Controllable 7.1.4 PCM (134 files) |
| `cloud-fixtures/test_X/MANIFEST.json` | Inventory |
| `cloud-fixtures/perfect-stream-grammar/` | NF perfect-stream grammar |
| Code tip | `origin/cursor/dtsx-xllx-only-defect-3541` (S1–S5 private silence timeline) |

## MISSING encode-debug (Mac Downloads — PARENT_UPLOAD_REQUIRED)
Desired after Louis pushes from Mac:
- `cloud-fixtures/reference-streams/tbh.dtshd` ← `/Users/sunyun_louis/Downloads/tbh.dtshd`
- `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd`
See `WHERE_TO_PUT_ENCODES.md`. Parent VM has no `/Users`.

## Hardware sync AFTER last tip (partial win)
1. NF still 可播
2. TBH: **仅 bed 发声的位置不可播** — 前约 10 秒 **和片尾** 都有（heights 有声段改善？）
3. **爆音更少** vs previous（Atmos master Object 首几帧 / 快速切声道仍有）
4. 7.1 HDMA/XLL 兼容层仍 OK；仅 DTS:X 私有层嫌疑
5. Hypothesis to test: mid-stream / terminal private silence forms when **bed active + heights silent** (and possibly **end-of-programme** trailing silence grammar) still wrong — not only AU0–3
6. No ffmpeg; Atmos master Object ≠ DTS:X objects
