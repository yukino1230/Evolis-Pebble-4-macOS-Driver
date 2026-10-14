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
# プリンタのアイコン(Evolis Utility の絵から歯車を除いたもの。tools/make_icon.py --printer で作る)。
# macOS の「プリンタとスキャナ」などに出る。48 / 128 / 512 px
for size in 48 128 512; do
  sips -s format png -z $size $size "$HERE/printer-icon.png" --out "$OUT/icon-$size.png" >/dev/null
done
python3 - "$OUT" > "$OUT/evolis-icons.h" <<'PY'
import sys
out = sys.argv[1]
print("/* printer-app/build.sh が printer-app/printer-icon.png から作る。手で直さない */")
for size in (48, 128, 512):
    data = open(f"{out}/icon-{size}.png", "rb").read()
    body = ",".join(str(b) for b in data)
    print(f"static const unsigned char ICON_{size}[] = {{{body}}};")
PY
clang -O2 -Wall -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
      -DEVOLIS_VERSION="\"$VER\"" -I"$DEPS/include" -I"$OUT" \
      -o "$OUT/evolis-printer-app" \
      "$HERE/evolis-printer-app.c" "$HERE/usb-device.m" "$ROOT/driver/evolis_card.c" \
      "$DEPS/lib/libpappl.a" "$DEPS/lib/libssl.a" "$DEPS/lib/libcrypto.a" \
      -lcups -lz -lpthread -framework AppKit -framework CoreFoundation -framework SystemConfiguration \
      -framework Foundation -framework IOKit -framework IOUSBHost
echo "できました: $OUT/evolis-printer-app"
