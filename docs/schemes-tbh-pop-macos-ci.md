# TBH pop + macOS CI — scheme census, 择优 reasons, verification record

Branch: `cursor/dtsx-tbh-pop-macos-ci-3541`, created off
`cursor/dtsx-tbh-pop-window-fix-3541` @ `22ee754` (PR #31). Mission:
continue fixing TBH hardware pops in `00:00:21:06`–`00:00:24:00` and
`00:02:51:00`–`00:02:56:00` after PR #30/#31 left default delivery
still popping; add mandatory macOS GitHub Actions Release build.

Model: `claude-fable-5-thinking-xhigh` (parent continued locally after
Cloud Agent child spawn hit usage exhaustion).

## Context

PR #31 landed opt-in seam A/B but kept delivery default =
`compact` (shared-zero form flaps). Louis reports both prior tips failed
to fix hardware pops — product encodes use the default path, so opt-in
alone cannot repair playback. Surrogate census (PR #30/#31) still shows
~12 Hz flaps between ~1,400-byte dense frames and 52-byte
`navigated-silence` on 90 bed-audible zero-height gaps, with ABIT 0↔19
at every re-onset. Bitstream/verifiers pass; hardware does not.

## Schemes (≥5) — 择优 with explicit reasons

| # | Scheme | Verdict | Reason |
| --- | --- | --- | --- |
| 1 | Promote `bridged-zero-gaps` to delivery default | **择优 — landed** | Attacks the measured whole-frame form flapping on the exact 90 gap frames; uses corpus-attested per-channel width-0 zero grammar; PCM-identical; product encodes now get the fix without remembering a flag; `--private-seam-mode compact` remains for A/B rollback |
| 2 | Promote `sticky-rice-zero-gaps` to delivery default | REJECT (for now) | Stronger ABIT continuity but larger payload (gap frames ~52→~2.6 KB on surrogate); no HW verdict that sticky beats bridged; keep as opt-in |
| 3 | Smooth bed→height routes in `DTS714Renderer` | DEFER | Unsmoothed bed-height feeds are a real risk class, but TBH IAB object path already uses ObjectGainSmoother; needs `verify-tbh-window-render` on real MXF |
| 4 | Global ABIT slew on all 637 in-window height onsets | REJECT | Blast radius far beyond the 90 gap frames; dominated by sticky opt-in |
| 5 | NAVI 11/13/14 ladder | REJECT | Forbidden; hardware-failed |
| 6 | Onset ramps / RenderGuard reshaping | REJECT | Forbidden; hardware-worsened |
| 7 | macOS GitHub Actions Release build gate | **择优 — landed (infra)** | Louis requires every tip prove Xcode `Build ALL` Release succeeds; repo had no workflows |

### Why scheme 1 is 择优 (must list)

1. **Default path was the defect surface.** PR #31 proved bridged cleans
   the seam grammar but left `compact` as default; Louis's product
   encodes never engaged the fix.
2. **Locally measured, PCM-identical.** Bridging only rewrites declaration
   form on ≤3-AU bed-audible gaps flanked by height-active frames; PCM and
   closed-loop decode stay bit-exact (`isBitExact`).
3. **Narrower than sticky.** Sticky also lands as opt-in for A/B if
   bridged is insufficient on hardware.
4. **Code contradiction removed.** Bed-audible navigated path intended
   per-plane zeros; under compact, `encodeEntropySegment` still collapsed
   all-zero segments to shared `ncSegType=1` when bridging was nil.

## Files changed

- `Swift_DTSHDMAX/DTSXLL/DTSXPrivateFrameEncoder.swift` — default seam policy
- `Swift_DTSHDMAX/DTSHDMA/DTSXNativeEncoder.swift` — default seam policy
- `Swift_DTSHDMAX/DTSHDMA/AutomaticEncoder.swift` — default seam policy
- `Swift_DTSHDMAX/Support/CommandLineInterface.swift` — CLI default + usage
- `.github/workflows/macos-build.yml` — macOS-14 Xcode Release build
- `docs/schemes-tbh-pop-macos-ci.md` — this record

## PARENT_UPLOAD_REQUIRED

Unchanged: DAMF parts 006–045 missing; TBH reference archive missing;
no stamped `tbh_<STAMP>.dtshd` / `QWER_TBH_IAB.mxf` on cloud. Render
audit (scheme 3) and official grammar arbitration remain blocked.

## Louis Mac test

```bash
# Product default now uses bridged-zero-gaps
hdmax -i "/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf" -o tbh-bridged-default.dtshd

# A/B rollback to prior tip bytes
hdmax -i ".../QWER_TBH_IAB.mxf" -o tbh-compact.dtshd --private-seam-mode compact

# Stronger ABIT continuity if bridged is insufficient
hdmax -i ".../QWER_TBH_IAB.mxf" -o tbh-sticky.dtshd --private-seam-mode sticky-rice-zero-gaps
```

Listen in both pop windows. If default (bridged) is clean → done.
If still pops, try sticky; if all three pop → upload IAB for render audit.

## CI

Workflow: `.github/workflows/macos-build.yml`
Command: `xcodebuild -project Swift_DTSHDMAX.xcodeproj -scheme "Build ALL" -configuration Release CODE_SIGNING_ALLOWED=NO`
