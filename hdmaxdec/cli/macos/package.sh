#!/bin/sh
# Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
# Packaging only. Decoder and GUI behavior remain in C/C++.
set -eu
products="$1"
executable="$2"
sources="$3"
bundle="$products/hdmaxdec QC.app/Contents"
mkdir -p "$bundle/MacOS"
cp "$executable" "$bundle/MacOS/hdmaxdec"
cp "$sources/cli/macos/Info.plist" "$bundle/Info.plist"
if [ -d "$products/libhdmaxdec.framework" ]; then
  : # Xcode embeds this framework with its native Copy Files phase.
else
  # Portable macOS test builds produce a dylib beside the executable.
  cp "$products/libhdmaxdec.dylib" "$bundle/MacOS/libhdmaxdec.dylib"
fi
