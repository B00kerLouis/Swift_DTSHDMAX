# TBH pop windows — reinvestigation scheme census (post PR #27 integration)

Branch: `cursor/tbh-pop-reinvestigate-3fca`
Baseline: `origin/cursor/dtsx-damf-input-tbh-pop-3541` @ `c7021d6` (integrates closed PR #26:
corpus zero-plane declaration, canonical NAVI width 11, grammar timeline tools, DAMF sibling-audio
fallback, stamped reference gate). Rollback anchor for first-frame play + file encode:
`main` @ `08b4478` (2026-08-27 00:47:48 UTC ≈ 08:47 Beijing; user-requested ~16:00 baseline
maps to this tip plus PR #25–#27 landed fixes, not a later broken tip).

Hardware verdict driving this run: pops inside `00:00:21:06`–`00:00:24:00` (stream AU 1994–2252)
and `00:02:51:00`–`00:02:56:00` (stream AU 16033–16502 at 24 fps) **survived PR #25, #26, and #27**.
No ffmpeg anywhere. Model: `claude-fable-5-thinking-xhigh` (cloud subagent bc-1ae999d1 + parent sync).

## Timestamped materials — PARENT_UPLOAD_REQUIRED (not skipped)

Still missing on `origin/cursor/cloud-materials-3541`:

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt
```

Mac sources (from `WHERE_TO_PUT_ENCODES.md`):

| Role | Path |
| --- | --- |
| TBH encode | `/Users/sunyun_louis/Downloads/tbh.dtshd` |
| NF encode | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` |
| TBH IAB master | `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf` |

Without these, byte-exact grammar census and real-master render audit cannot pass silently.

## Schemes considered (seven mechanisms; ≥5 required)

| # | Scheme | Verdict | One-line reason |
| --- | --- | --- | --- |
| 1 | Re-land NAVI 11/13/14 ladder (PR #20/#22) | REJECT | Hardware-failed; forbidden |
| 2 | Renderer onset ramps / `beginFromSilence` / delivery-boundary conditioner | REJECT | Hardware measurably worsened pops |
| 3 | Further private grammar mutation (zero/NAVI/partition) on integrated PR #27 tip | REJECT | Field-complete census on surrogate shows every locally attestable declaration already on corpus form; no width/form flapping |
| 4 | Mixed-segment zero plane beside dense Rice: Rice-0 unary runs vs per-channel linear-0 | DEFERRED | Corpus-blocked; flipping without `tbh_<STAMP>.dtshd` risks PR #24 regression |
| 5 | Dense-segment ABIT: zigzag-mapped mean vs raw-magnitude mean | DEFERRED | Corpus-blocked; entropy safety analyzer ties official form to raw abs mean |
| 6 | Mid-stream `bUseSegStateCodeParm=1` entropy state reuse | DEFERRED | Delivery profile pins reuse off; census needed on reference |
| 7 | **IAB render-window PCM + render-guard audit over real TBH master** | **择优 — landed** | Only locally actionable path left without inventing bitstream bytes; separates render overload/discontinuity from encode grammar |

### Scheme 7 detail (landed)

- **Mechanism.** New verifier `DTSXWindowRenderAuditVerifier` and CLI
  `hdmax verify-tbh-window-render INPUT_IAB.mxf` map the two TBH pop windows,
  render through production `DTS714Renderer.render(iab:)`, capture the whole-programme
  `DTS714RenderGuardReport`, and measure per-window adjacent-sample deltas,
  full-scale hits, and height activity. Surrogate encodes stay transparent to the guard;
  real TBH IAB motion may not — this command is the gate before any further grammar guess.
- **Why 择优.** PR #27 proved the delivery encoder path byte-identical to PR #26 for
  identical inputs; hardware pops therefore implicate either (a) render-side headroom
  engagement on the real master, or (b) a declaration the reference stream alone can
  adjudicate (schemes 4–6). Scheme 7 is the only safe, non-invented next step.
- **Playbook once `QWER_TBH_IAB_<STAMP>.mxf` lands:**
  ```bash
  hdmax verify-tbh-window-render cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
  hdmax verify-reference-streams
  hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
    tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00
  ```

## Abandoned PR cleanup (integrated vs closed)

| PR | Branch | Status | Disposition |
| --- | --- | --- | --- |
| #24 | `cursor/dtsx-tbh-pop-windows-3541` | CLOSED | Tools integrated (timecode mapping, pop census) |
| #25 | `cursor/dtsx-tbh-render-unsafe-3541` | CLOSED | Corpus zero-plane fix integrated |
| #26 | `cursor/dtsx-tbh-window-pop-continued-3541` | CLOSED | NAVI width-11 repair integrated; HW pops remain |
| #27 | `cursor/dtsx-damf-input-tbh-pop-3541` | DRAFT | DAMF fallback + gate; base of this branch |

## Verification record (parent VM, no macOS xcodebuild)

Linux parent cannot run `xcodebuild`; subagent `bc-1ae999d1` (claude-fable-5-thinking-xhigh)
was dispatched for full Swift build + encode loop. This branch adds one verifier file and one
CLI subcommand on top of PR #27 tip — compile gate deferred to Mac/subagent CI.

Model slug: `claude-fable-5-thinking-xhigh`.
