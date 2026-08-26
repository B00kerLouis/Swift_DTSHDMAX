# Swift_DTSHDMAX project memory (cloud handoff)

## Repo layout

```text
Swift_DTSHDMAX/
  DTSAudioModel/     PCM / WAVE
  DTSBitstream/      BitReader/Writer, CRC
  DTSContainer/      container extract
  DTSCore/           Core encode/decode
  DTSExSS/           ExSS asset / DTS:X descriptor
  DTSHDMA/           HDMA + DTS:X native product encoders
  DTSInspector/      stream inspect / differentials
  DTSObjects/        7.1.4 / Atmos / ADM / gain smoother
  DTSValidation/     closed-loop verifiers + synthetic vectors
  DTSXLL/            public XLL + private XLL-X
  Support/           CLI + Linux portability
```

`main` tip: `7199a8e` — Complete terminal-safe XLL-X and smooth object rendering.

## Known terminal symptoms ↔ root causes

| Symptom | Mechanism | Fix direction |
| --- | --- | --- |
| First 2 frames unplayable | Core priming AUs used `XLLEncoder(.research)` → decorrelation + non-identity order + shared entropy; delivery AUs declare the opposite → terminal latches wrong config until AU3 | Priming must use delivery coding mode; keep compact research priming behind `compactXLLPriming` only |
| Mid-stream pops (L/Lsr/Rsr/Lfh/Lrh/Rrh) | Public XLL cost-search flips 2×256 ↔ 4×128 mid-programme → segment navigation reconfig | Pin mid-stream `preferredSegmentCount = 2`; allow startup frame-indexed 4×128 |
| Full-scale pops / desync | Unbounded Rice unary (>22) on terminal bounded readers | `terminalRiceOfficial` default |
| Stepped Top Surround | Height pan hits 1/480 slew every 250-sample sub-block | Height slew 1/1440 + min ramp 480 (floor unchanged) |

## Prior agents

- `bc-73047fb4` / child `bc-a1ed0683` — Rice Official + channel-allocation verifier
- `bc-cc860ff3` / child `bc-0a553c9c` — height slew + priming declarations + partition pin + startup-seam verifier
- Branch: `cursor/dtsx-encode-official-vector-refactor-51d8` @ `2c9d83f` (PR #1 draft)

## Rollback + re-fix intent (this task)

1. Roll the previous Cursor branch back to the prior baseline (`main` / `7199a8e`), without modifying `main` itself.
2. On a **new** independent feature branch, re-apply the first-two-frames + pop fixes using controlled vectors and the Nature's Fury grammar notes above.
3. Prove with `verify-dtsx-startup-seams` (and related native / private / HDMA gates). Hardware / commercial-stream differential remains external until binaries are mounted.
