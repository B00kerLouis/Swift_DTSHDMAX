# Controllable `test_X` vectors (cloud handoff)

Louis requested cloud staging of:

```text
/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/Swift_DTSHDMAX/Research/test_X
```

That Mac research volume is **not mounted** in this cloud VM, and `/Research/` is
gitignored on `main`. This directory is the **cloud-readable substitute** so
subagents can consume controllable 7.1.4 PCM without inventing `.dtshd` binaries.

## Layout

```text
cloud-fixtures/test_X/
  MANIFEST.json          # identity, grammar hints, per-vector SHA-256
  pcm-sources/
    ALL_MUTE/            # all-zero 7.1.4 mono 24-bit / 48 kHz WAVs
    LFH_ONLY/
    LFH_RFH/
    LFH_RFH_OPPOSED/
    IMPULSE_LFH/
    IMPULSE_L/
    FULLSCALE_C/
    FRAME_EDGE_Lsr/
    SILENCE/
    ALL_SINE/
    CHANNEL_WALK_COMPACT/
```

Each vector directory contains `input.{L,R,C,LFE,Lss,Rss,Lsr,Rsr,Lfh,Rfh,Lrh,Rrh}.wav`
(4 frames × 512 samples), matching `DTSXOracleVectorGenerator` / `DTS714SourceSet`
channel labels.

## Related grammar package

See `cloud-fixtures/perfect-stream-grammar/` for Nature's Fury recovered XLL / XLL-X
partition and priming notes (from prior handoff PR docs). Use those notes to
differential-check encode declarations — do **not** trust the existing Linux
regression suite as proof of terminal playability.

## Official Mac `.dtshd` names (when later mounted)

`verify-xllx-controlled-pcm` expects:

```text
ALL_MUTE.dtshd  LFH_ONLY.dtshd  LFH_RFH.dtshd
```

Do not fabricate those elementary streams. Encode from `pcm-sources/` with the
in-tree encoder under test, then inspect declarations against the perfect-stream
grammar.
