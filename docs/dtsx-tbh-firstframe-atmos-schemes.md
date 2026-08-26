# tbh first frame + Atmos-onset pops: encode-stage schemes and selection

Status snapshot this document responds to (Louis, 2026-08-26, after the
render-native onset tip `dtsx-atmos-object-onset-3541`):

1. Nature's Fury: plays (可播).
2. tbh: **first frame unplayable** (首帧不可播放). Earlier tips reported
   ~10 s; the current report is first-frame focused, and the early AUs are
   inspected as one window either way.
3. Click/Clip and 爆音 continue, and the pop volume is **worse than the
   previous version** ("爆音量相对上一版更多") - the render-native
   `beginFromSilence` + rate-exact-slew tip is evidence-negative on
   hardware, exactly like the delivery-boundary height ramps before it.
4. Correlation unchanged: pops track **Atmos master objects** (DAMF/IAB/ADM
   essence plus automation), worst near object 发声 onsets and the
   programme head, under fast moves. These are *not* DTS:X/XLL-X objects;
   the delivery flattens everything to 7.1.4 planes.
5. No ffmpeg anywhere. HDMA and Core encodes are certified OK on hardware
   and must not regress.
6. The official binaries (`tbh.dtshd`, `Dolby_NaturesFury.dtshd`) are
   **still not on this VM** - **PARENT_UPLOAD_REQUIRED**
   (`cloud-fixtures/reference-streams/UPLOAD_BLOCKED.md`,
   `WHERE_TO_PUT_ENCODES.md`, re-verified by the parent 2026-08-26). Direct
   byte comparison against the official corpus is impossible here;
   everything below is validated with controllable vectors
   (`cloud-fixtures/test_X`), the perfect-stream grammar notes
   (`cloud-fixtures/perfect-stream-grammar`), and `PROJECT_MEMORY.md`.

## Root-cause analysis

Two hardware rounds of onset conditioning (O1/O2 encode-boundary ramps,
then A2/A4 render-native `beginFromSilence` + rate-exact slew) both made
pops worse and neither made the tbh first frame playable. That is strong
evidence the first-frame failure is not an onset-shape problem at all. The
code audit of this tip localizes three encode-stage defects instead:

1. **The two DTS:X Core-priming AUs are encoded with research-only XLL
   grammar.** `HDMAEncoder` forces `XLLEncoder(codingMode: .research)` for
   the priming AUs whenever a private XLL-X source is attached - i.e. for
   *every* DTS:X encode - while every following access unit uses the
   delivery mode (`terminalOfficialRice`). The research compact zero form
   is eight bytes smaller, but its channel-set declarations differ from
   every delivery frame: `bPWChDecorEnabled = 1` with a *permuted*
   `nOrigChOrder`, and shared (common) entropy parameters. The terminal
   latches the AU0 channel-set configuration and must reconfigure when AU2
   (the first source AU) arrives with different declarations.
   `PROJECT_MEMORY.md` records exactly this as an already-diagnosed root
   cause: *"Priming AUs using research-only XLL → first frames unplayable
   until AU3"* and *"Priming declarations must match **delivery**
   channel-set config (not research-only)"*. The symptom split matches
   perfectly: Nature's Fury starts silent, so the frames lost to the
   reconfiguration window are inaudible and it plays; tbh is hot from
   sample zero, so its first audible frame lands inside the window -
   "first frame unplayable". Decisive corroboration: **ordinary HDMA -
   which Louis certifies OK on hardware - has always primed with its
   delivery encoder.** Only the DTS:X path was forced into research
   priming.
2. **The render-native onset machinery of the previous tip is
   evidence-negative and mechanically plausible as a pop amplifier.** The
   previous tip replaced `setImmediately` initial declarations with a
   programme-head fade (`beginFromSilence`) and replaced the fixed
   480-sample slew window with "rate-exact" periods
   (`ceil(|delta| x 480 / 2^30)` samples). Rate-exact runs *every*
   slew-limited move at the maximum legal rate for the shortest legal
   duration; the fixed 480-sample window runs each move at `|delta|/480`
   per sample - at or below the bound, and *gentler the smaller the move*.
   Under dense fast-move automation (a retarget every pan sub-block, the
   exact correlation Louis reports) rate-exact turns the gain trajectory
   into a chain of maximum-steepness ramps separated by flats, maximizing
   the high-rate energy of the gain envelope on hot essence. Hardware
   verdict: more pops. The programme-head fade also reshapes the delivered
   programme (official renders deliver hot heads unfaded) and it fixed
   nothing, because the first-frame failure lives in the priming grammar
   (defect 1).
3. **The recovery constraint has no headroom for Core codec error.** What
   the reference decoder actually plays during forced first-frame/seek
   recovery is `clip23(decodedCore x sqrt(2))`, and the *decoded* Core is
   the ideal -3.0103 dB fold plus codec error, which peaks at loud
   transients - hot starts and object onsets. The composite guard
   (`DTS714RenderGuard`) bounded the ideal recovery values at *exact* full
   scale, so any positive codec error clips the recovery playback.
   Measured on the FULLSCALE_C controllable vector: 16 recovery-clipped
   samples, maximum scaled Core ~8.52M (+0.14 dB over full scale). Every
   stream start and every seek re-entry replays this window; on hot Atmos
   onsets, mid-stream re-sync recoveries do too.

## The mandated schemes (≥ 5)

### Scheme P1 - Delivery-grammar priming for the DTS:X public XLL (PICKED)

Stop forcing `.research` for the two Core-priming AUs when a private XLL-X
source is present. Priming AUs use the same delivery encoder (and therefore
the same channel-set declarations: no pairwise-decorrelation flag, natural
channel order, explicit entropy state) as every other access unit, exactly
as ordinary HDMA - hardware-certified OK - has always done. The compact
research form stays available only behind the explicit `compactXLLPriming`
differential control (`encode-dtsx-public-xll-control`), so byte-level
reference investigations keep their control.

*Why picked:* it is the diagnosed root cause of the exact reported symptom
(hot-start first frames unplayable until AU3, silent starts unaffected),
recorded independently in `PROJECT_MEMORY.md` from hardware experience; the
fix makes the declaration timeline constant from AU0; and it aligns DTS:X
with the ordinary-HDMA priming behavior that is already certified OK. Cost:
eight bytes per stream.

### Scheme P2 - Revert render onset machinery to the hardware-least-bad
### form, keeping only the above-unity rate-bound fix (PICKED)

Remove `beginFromSilence` (initial declarations install via
`setImmediately` again - no programme-start fade) and restore the fixed
480-sample window for slew-limited retargets. Keep one genuine fix from the
rate-exact work: an above-unity delta (positive object gain trim) stretches
the window to `ceil(|delta| x 480 / 2^30)` samples so no step ever exceeds
the 1/480-per-sample reference bound (`period = max(480, rate-exact)`).

*Why picked:* Louis's comparison point ("上一版") is the five-scheme tip,
which used exactly this configuration and measured *fewer* pops; both
deviations from it are hardware-evidence-negative. The revert restores the
least-bad measured render behavior while the real first-frame fix (P1)
lands at the encode stage. The above-unity extension is kept because a
faster-than-reference step is a genuine discontinuity carrier and extending
the window is strictly gentler.

### Scheme P3 - Core-codec-error recovery reserve in the composite guard
### (PICKED)

Bound every Core-mapped recovery value (C and LFE planes, the front L/R
height folds, and the two side+rear recovery sums) at full scale minus a
reserve of 2^18 = 262,144 LSBs (-0.27 dB, ~1.9x the worst measured codec
error overshoot of ~136k LSBs through the sqrt(2) recovery scale). The
plane and fold constraints stay at exact full scale, so delivered lossless
levels change only within the reserve of full scale on Core-mapped
constraints, with the same slew-bounded anticipatory envelope as before.
The built-in hot-start recovery gate now drives a full-scale centre so the
reserve is permanently regression-tested, and FULLSCALE_C goes from 16
recovery-clipped samples to zero.

*Why picked:* it closes the one *measured* clipping path left in the
startup window - `clip23(decodedCore x sqrt(2))` exceeding full scale
during forced recovery - which replays at every stream start, every seek,
and every mid-stream re-sync, i.e. exactly where hot Atmos onsets pop. It
is surgical: DTS:X 7.1.4 conditioning only, no HDMA/Core code touched, and
in-headroom content still passes bit-exact.

### Scheme P4 - Core-feed limiter after the -3.0103 dB fold (REJECTED)

Instead of reserving headroom in the source, clamp only the Core encoder's
input so the decoded Core stays below full scale over sqrt(2), keeping the
XLL primary at full range (the residual absorbs the difference losslessly).

*Why rejected:* it edits the shared HDMA/Core feed path that hardware
certifies OK (the explicit non-regression constraint); it silently breaks
the declared DownmixScale promise (`Core = primary x 1/sqrt(2)` on all six
channels) that both the recovery playback and the steady-state residual
combination rely on; and the residual growth reintroduces content-shaped
entropy exactly where the terminal is most fragile. P3 achieves the same
recovery bound from the DTS:X-only conditioning stage.

### Scheme P5 - Restructure priming (drop the priming AUs, or declare
### `nuInitLLDecDlyFrames > 0`) (REJECTED)

Remove the reconfiguration window entirely by removing the priming AUs or
by declaring an XLL initial decoding delay so the terminal skips them.

*Why rejected:* it contradicts the recovered perfect-stream grammar on
every axis - the Nature's Fury reference carries exactly two Core-priming
AUs of 512 samples and declares `nuInitLLDecDlyFrames = 0` (which this
encoder already emits). Restructuring the timeline is a grammar the corpus
never exercises, unverifiable without the blocked official binaries, and
strictly riskier than making the priming declarations match delivery (P1).

### Scheme P6 - A third round of onset conditioning (stronger head ramps,
### first-AU mute, or Core-only onset shaping) (REJECTED)

*Why rejected:* two independent hardware rounds are evidence-negative -
encode-boundary height ramps (O1/O2) increased pops, and render-native
silence-start slews (A2/A4) increased pops again while leaving the tbh
first frame unplayable. Official renders deliver hot programme heads
unfaded; the failing stages are the priming grammar (P1) and the
recovery-window headroom (P3), both of which are addressed without
reshaping programme content.

## Implementation map

| Scheme | Files |
| --- | --- |
| P1 | `DTSHDMA/HDMAEncoder.swift` (priming encoder selection); `DTSValidation/DTSXNativeEncoderVerifier.swift` (priming grammar pins → delivery form, 140-byte zero AU); `DTSValidation/DTSXEarlyProgrammeGrammarVerifier.swift` (research-syntax exclusion extended to priming AUs) |
| P2 | `DTSObjects/DTS714ObjectGainSmoother.swift` (fixed-480 window, above-unity extension, `beginFromSilence` removed); `DTSObjects/DTS714Renderer.swift` (`setImmediately` initial declarations); `DTSValidation/DTS714ObjectGainSmoothingVerifier.swift`, `DTSValidation/DTS714RenderStartupVerifier.swift` (contracts updated to the unfaded-start semantics) |
| P3 | `DTSObjects/DTS714RenderGuard.swift` (reserved Core-mapped recovery constraint); `DTSValidation/DTSXNativeEncoderVerifier.swift` (full-scale hot-start recovery gate) |

## Verification without the official binaries (no ffmpeg)

- `verify-dtsx-native-encoder` (Debug build): determinism, closed-loop
  bit-exactness, terminal grammar pins including the new delivery-grammar
  priming form, startup transition `[2,2,4,4,2]`, active-startup
  segmentation policy, object-gain smoothing contract (fixed-480 +
  above-unity extension), full-scale hot-start recovery window
  (`recoveryClipSampleCount == 0`), hostile-start early programme window.
- `verify-dtsx-render-guard`, `verify-dtsx-render-startup` (Debug):
  reserved recovery constraint closes with zero residual clips; unfaded
  hot start; bit-exact silent start; encode-boundary passthrough.
- Controllable vectors (`cloud-fixtures/test_X/pcm-sources`) through
  `encode-dtsx-native-source` + `verify-dtsx-recovery-window` +
  `verify-dtsx-early-programme`: FULLSCALE_C recovery clips 16 → 0; all
  vectors early-programme safe with delivery-grammar priming.
- HDMA/Core non-regression: plain HDMA priming behavior is untouched by
  construction (it never took the forced-research branch), and the HDMA
  verify suite must stay green.

## What still needs hardware / the parent upload

- A/B of this tip against `dtsx-atmos-object-onset-3541` on the tbh master
  (first-frame playability + pop count) and on Nature's Fury (must stay
  playable).
- The official `.dtshd` binaries remain required to byte-calibrate the
  priming-AU grammar and the recovery-handoff magnitudes
  (PARENT_UPLOAD_REQUIRED).
