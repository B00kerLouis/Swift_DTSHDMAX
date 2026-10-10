# Swift_DTSHDMAX component license

Copyright (c) 2026 B00kerLouis.

The encoder portions of this repository are not released under an OSI-approved
open-source license. The project-owned encoder implementation and its associated
build and documentation support use the research license below. The independent
hdmaxdec decoder has the separate LGPL grant described below.

## Encoder: LicenseRef-Swift-DTSHDMAX-Research

The following project-owned components are available under
[`LicenseRef-Swift-DTSHDMAX-Research.txt`](LicenseRef-Swift-DTSHDMAX-Research.txt):

- `Swift_DTSHDMAX/`, including the native DTS-HD MA / DTS:X implementation,
  CLI and Framework entry points, format readers and writers, and validation
  code;
- encoder-specific portions of `Swift_DTSHDMAX.xcodeproj/`, its workspace and
  shared schemes; decoder-specific additions are covered by the LGPL grant;
- encoder-specific material in `README.md` and this license index.

Downstream permission is limited to noncommercial encoding research with the
Swift implementation, education, and experimental validation. Commercial use,
reverse engineering, and translation or reimplementation of protected Encoder
code in another language require separate written authorization, subject to the
exceptions in that license. This is a source-available research license, not an
OSI open-source license. It does not restrict the rights holder's own use or
separately authorized uses.

No commercial permission is granted by this license. Any person or organization
that wishes to use the Encoder for commercial activity must obtain separate
written commercial authorization in advance from DTS, Inc., its parent company
Xperi Inc., and B00kerLouis, each to the extent of the rights that party owns
or controls.
Authorization from one party does not replace authorization from the others.

## Decoder: LGPL-2.1-or-later

`hdmaxdec/`, the `decoder cli` and `decoder framework` Xcode target additions
and shared schemes, and `.github/workflows/hdmaxdec.yml` are independently
licensed under GNU LGPL version 2.1 or, at your option, any later version.
The copyright and grant are in
[`hdmaxdec-LGPL-2.1-or-later.txt`](hdmaxdec-LGPL-2.1-or-later.txt).
The complete terms are in [`LGPL-2.1.txt`](LGPL-2.1.txt), with the incorporated
GNU GPL terms in [`GPL-2.0.txt`](GPL-2.0.txt). The decoder grant covers its CLI,
macOS QC interface, Framework, FFmpeg adapter, tests and build support. The
encoder's noncommercial, reverse-engineering and reimplementation restrictions
do not apply to these LGPL components.

This is the same license choice as [FFmpeg's default LGPL configuration](https://ffmpeg.org/legal.html).
FFmpeg builds that enable optional GPL components are instead governed by the
corresponding GPL terms. The optional AVFrame adapter links a separately
installed libavutil; this repository does not distribute that library or grant
rights in FFmpeg's code.

Component paths in this index are relative to the repository root. All project
license texts are maintained in this directory. CMake installs the decoder
grant, LGPL text and incorporated GPL text together with decoder distributions.

## Third-party material

This grant covers only rights controlled by B00kerLouis. DTS, Inc. and its parent
company Xperi Inc. retain all independent commercial, copyright, patent, trademark,
certification, licensing, and enforcement rights they own or control. Third-party
code, documentation, media, and other material remain under their own applicable
terms and are not granted or relicensed by this project. This notice does not
make DTS, Inc. or Xperi Inc. a licensor of B00kerLouis's code, state that either
company owns that code, or imply endorsement by either company.

B00kerLouis's own use, modification, licensing, distribution, and commercialization
of B00kerLouis's work are expressly exempt from the downstream restrictions.
Any separate authorization from B00kerLouis grants only rights controlled by
B00kerLouis and does not grant DTS or Xperi rights.

The full terms are in
[`LicenseRef-Swift-DTSHDMAX-Research.txt`](LicenseRef-Swift-DTSHDMAX-Research.txt).
