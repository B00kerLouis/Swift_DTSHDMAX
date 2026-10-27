# Decoder validation

Copyright (c) 2026 B00kerLouis. LGPL-2.1-or-later.

## Verified delivery profiles

The decoder is independent C17/C++17. Its targets do not link the Swift encoder or an external codec. Qualification is limited to this project's 48 kHz/24-bit delivery grammar.

| Presentation | Transport and PCM evidence |
| --- | --- |
| Standard 7.1.4, branch 0 | Synthetic Core/public/private vectors and complete programmes |
| Fixed 7.1.3, 7.1.2F, 7.1.2S, 5.1.5, 5.1.4, 5.1.3 | Auto/standard synthetic vectors, shared-width rejection, channel permutation and complete programmes |
| Fixed IMAX 12.1, D0 | Thirteen feeds, separate TFC/unity folds and complete programmes |
| Dynamic 7.1.4+4, D3 | Four aggregates, fixed height quartet, continuous fold recovery and software 7.1.4 rendering; complete programmes |
| Dynamic 7.1.5+4, D4 | Synthetic auto/standard transport, reserved TFC isolation and continuous 7.1.4-based software image; full programme and physical IMAX acceptance remain unqualified |

## Programme investigation, 2026-10-27

The local `Run_20261026_164624` corpus contained 24 files: Nature's Fury, TBH and Water, each in seven standard fixed layouts plus fixed IMAX. Its manifest also listed three missing dynamic 7.1.4+4 files. Those were regenerated from their original indexed IAB/DAMF masters, with source stems and per-AU positions retained.

- All 27 files decode through EOF. Exact source counts are 5,200,000, 11,036,000 and 4,468,000 samples/channel respectively. Each programme exceeds 90 seconds. Container priming and padded tails are removed once.
- All 24 fixed presentations match the corresponding full renderer PCM, using the encoder's Release configuration, with maximum error **0 LSB** on every channel. This compares an independent decoder against known input PCM; it is separate from native encoder self-round-trip.
- The three regenerated dynamic presentations match an independently evaluated continuous speaker image from Swift targets and coded source stems within **1 LSB**. This checks software presentation recovery, not original IAB track recovery.
- Against existing official full-programme exports of the matching NF/TBH D3 streams, maximum absolute differences are **621/627 LSB**. Maximum per-channel relative RMS errors are **0.000369888/0.000255944**. All channels have zero full-scale samples, zero missing 10 ms windows and zero windows below 20% of an audible reference. The software panner is **not bit-exact to the official renderer**.
- All 27 programmes pass exact indexed seeks at AU boundaries, arbitrary positions and near EOF, plus cancellation/pending-PCM preservation and restart. Object reference and display gains are included in the bounded history snapshots.

Evidence, generated streams, PCM exports, hashes, metrics and scripts remain local under ignored `Research/Decoder_Master_QC_20261027/`. `fixed-comparison.json`, `dynamic-reference-comparison.json`, `official-comparison.json`, `programme-seek-results.json` and `decode-results.json` distinguish these checks. The existing official exports and their original validation records remain under `Research/DynamicRepair_20261026/`. A follow-up GUI campaign loaded and played all 27 complete programme files through EOF in both the official DTS:X MediaPlayer and `hdmaxdec QC`. The player recognized the three regenerated D3 files as “7.1.4, 4 Objects.” Downmix and Legacy monitoring stayed Off. The 1,994,280-row meter capture spanned 6,091.8 seconds, reported zero clipped samples and peaked at -1.45 dBFS. The playback ledger and capture remain local under `Research/Decoder_Master_QC_20261027/`. The selected MacBook Pro output has two channels, so the official player warned that it could not monitor every immersive feed; meter playback demonstrates software parsing and decoding, not full physical-feed playback or DTS certification.

Native 7.1.2S positions are TSL/TSR, which the ordinary WAVE mask cannot accurately represent. Use explicit-layout raw PCM, the C/AVFrame API, or labelled mono WAVs. Do not relabel them as front heights.

## Repeatable engineering checks

Build both product families with the root Xcode `Build ALL` scheme in Release and optimized Debug. Decoder tests also build independently:

```sh
cmake -S hdmaxdec -B Build/DecoderQC -DCMAKE_BUILD_TYPE=Release -DHDMAXDEC_FFMPEG=ON
cmake --build Build/DecoderQC --parallel 4
ctest --test-dir Build/DecoderQC --output-on-failure
```

Omit `HDMAXDEC_FFMPEG` when libavutil is unavailable. The AVFrame adapter is optional. `hdmaxdec_tests FILE...` checks full-programme EOF/priming/restart, and `hdmaxdec_seek_tests FILE...` compares sequential PCM with prepared-index seeks. Synthetic fixtures contain no user media. They exercise all six additional fixed formats and both dynamic roles in auto and standard modes, CRC rejection, enclosing NAVI widths, source PCM, stereo monitoring, and continuous state. Existing malformed vectors, export/cancellation, Unicode paths and optional AVFrame tests remain active.

## Limits

Core Huffman/non-AMODE-9 profiles, non-48-kHz audio, fragmented PBR, multiple assets, other commercial object grammars and research routing branches 1/2/3 remain outside qualification. New layouts do not expand those public codec claims. Hardware DTS:X/IMAX presentation and formal DTS certification remain external requirements.
