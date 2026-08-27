# Material brief (2026-08-27 — post main land)

## Code base
`origin/main` @ `08b4478` — bed-active silence gaps + prior DTS:X tip landed (author Sunyun_Louis).

## Fetch materials
```
git fetch origin main cursor/cloud-materials-3541
```

## AVAILABLE
| Path | Role |
| --- | --- |
| `cloud-fixtures/test_X/` | Controllable 7.1.4 PCM vectors |
| `cloud-fixtures/perfect-stream-grammar/` | NF perfect-stream grammar |
| `Agent.md` on parent VM (gitignored) | Project memory |

## MISSING encode-debug → PARENT_UPLOAD_REQUIRED
- `cloud-fixtures/reference-streams/tbh.dtshd` ← Downloads
- `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd`

## Hardware sync
1. **Both streams first frames OK**
2. 爆音 **unchanged** — Atmos **master** Object first few frames + fast channel switches
3. Probe perfect-stream **special semantics at XLL-X-active positions**
4. 7.1 HDMA bed OK; DTS:X-only residual; no ffmpeg
