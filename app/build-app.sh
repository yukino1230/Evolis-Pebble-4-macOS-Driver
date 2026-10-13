#!/bin/bash
# Evolis Utility.app をビルドする(Intel / Apple Silicon 両対応)
#   app/build-app.sh [バージョン] [出力先ディレクトリ]
# Developer ID Application の証明書があれば Hardened Runtime 付きで署名する
set -euo pipefail
VER="${1:-1.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${2:-$HERE/../build/app}"
APP="$OUT/Evolis Utility.app"
SIGN_APP="${EVOLIS_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for arch in arm64 x86_64; do
  echo "==> ビルド ($arch)"
  swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macos13.0" \
         -o "$TMP/EvolisUtility-$arch" "$HERE"/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Evolis Utility" "$TMP"/EvolisUtility-arm64 "$TMP"/EvolisUtility-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Evolis Utility</string>
  <key>CFBundleDisplayName</key><string>Evolis Utility</string>
  <key>CFBundleExecutable</key><string>Evolis Utility</string>
  <key>CFBundleIdentifier</key><string>jp.yukino.evolis-utility</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 画面の訳(英語がキーで、ja.lproj に日本語)
cp -R "$HERE"/Resources/*.lproj "$APP/Contents/Resources/"

xattr -cr "$APP" 2>/dev/null || true
if [ -n "$SIGN_APP" ]; then
  echo "==> 署名: $SIGN_APP"
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$APP"
  codesign --verify --strict --deep "$APP"
else
  echo "==> Developer ID Application が無いので未署名のままにします"
fi
echo "できました: $APP"
