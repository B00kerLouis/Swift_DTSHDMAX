# Swift_DTSHDMAX project memory (2026-08-25 handoff)

## Local status (Louis)

- HDMA encode: OK
- Core encode: OK
- Controllable vectors saved under local `Research/test_X` (Mac SSD; not cloud-mounted)
- DTS:X still shows random Click/Clip + 爆音; first frame must be playable

## Perfect-stream grammar (Nature's Fury)

| Topic | Value |
| --- | --- |
| Silent startup public XLL | 4×128 |
| Mid-stream public XLL | 2×256 |
| Core priming | 2 AUs × 512 samples; `nuInitLLDecDlyFrames = 0` |
| Priming declarations | Must match **delivery** channel-set config (not research-only) |
| Private Rice | `terminalRiceOfficial`, unary ≤ 22 |
| Private routing | branch-zero stable |

## Root causes already diagnosed (do not regress OK HDMA/Core)

1. Priming AUs using research-only XLL → first frames unplayable until AU3
2. Mid-stream public partition flip 2×256 ↔ 4×128 → navigation reconfig pops
3. Unbounded Rice unary > 22 → full-scale pops / desync
4. Height slew too aggressive → stepped Top Surround

## Do not trust

Existing `verify-*` gates and the current Test approach can stay green while
terminals still click. Prefer raw-stream declaration / perfect-stream grammar
analysis and controllable vectors under `cloud-fixtures/test_X/`.

## Prior fix branch (reference only)

`cursor/dtsx-priming-partition-pop-fixes-ded9` (PR #4 draft) — re-check against
original-stream grammar before landing; user asked for a **new** independent
feature branch for this run.
