#!/bin/bash
# Evolis Printer Application をビルドする(Intel / Apple Silicon 両対応)。
#   printer-app/build.sh [バージョン] [出力先]
# 先に printer-app/build-deps.sh で PAPPL と LibreSSL を作っておく(無ければ作る)。
set -euo pipefail
VER="${1:-2.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
DEPS="$ROOT/build/deps/universal"
OUT="${2:-$ROOT/build/printer-app}"
[ -f "$DEPS/lib/libpappl.a" ] || "$HERE/build-deps.sh"
mkdir -p "$OUT"
# Web の設定画面の英語と日本語(PPD と同じ表示名)
python3 "$HERE/mkstrings.py" > "$OUT/evolis-strings.h"
clang -O2 -Wall -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
      -DEVOLIS_VERSION="\"$VER\"" -I"$DEPS/include" -I"$OUT" \
      -o "$OUT/evolis-printer-app" \
      "$HERE/evolis-printer-app.c" "$HERE/usb-device.m" "$ROOT/driver/evolis_card.c" \
      "$DEPS/lib/libpappl.a" "$DEPS/lib/libssl.a" "$DEPS/lib/libcrypto.a" \
      -lcups -lz -lpthread -framework AppKit -framework CoreFoundation -framework SystemConfiguration \
      -framework Foundation -framework IOKit -framework IOUSBHost
echo "できました: $OUT/evolis-printer-app"
