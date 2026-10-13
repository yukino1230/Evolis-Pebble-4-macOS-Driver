#!/bin/bash
# Evolis Pebble 4 ドライバの配布パッケージを作る
#   driver/build-pkg.sh [バージョン]
#
# 署名と公証は「できるならする」。Developer ID 証明書が無い環境では
# 未署名のパッケージができるだけで、ビルドは失敗しない。
#   EVOLIS_NOTARY=<notarytool のプロファイル名>   公証まで行う
#   EVOLIS_SIGN_APP= / EVOLIS_SIGN_PKG=           証明書を明示する(既定は自動検出)
set -euo pipefail
VER="${1:-1.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/../build/pkg"
ROOT="$BUILD/payload"
export COPYFILE_DISABLE=1                       # ._ ファイルを作らせない

# Developer ID 証明書を探す(指定があればそれを使う)
find_id() { security find-identity -v ${2:-} 2>/dev/null \
              | sed -n "s/.*\"\($1: [^\"]*\)\".*/\1/p" | head -1; }
SIGN_APP="${EVOLIS_SIGN_APP:-$(find_id 'Developer ID Application' '-p codesigning')}"
SIGN_PKG="${EVOLIS_SIGN_PKG:-$(find_id 'Developer ID Installer')}"
NOTARY="${EVOLIS_NOTARY:-}"

rm -rf "$BUILD"; mkdir -p "$ROOT" "$BUILD/scripts"
mkdir -p "$ROOT/usr/local/libexec/cups/filter" "$ROOT/usr/local/bin" "$ROOT/usr/local/share/evolis" \
         "$ROOT/Library/Printers/PPDs/Contents/Resources" "$ROOT/Applications"

echo "==> CUPS フィルタをビルド(ユニバーサル)"
FILTER="$ROOT/usr/local/libexec/cups/filter/rastertoevolis"
clang -O2 -Wall -arch arm64 -arch x86_64 -o "$FILTER" "$HERE/rastertoevolis.c" "$HERE/evolis_card.c"
chmod 755 "$FILTER"
if [ -n "$SIGN_APP" ]; then
  echo "==> フィルタに署名: $SIGN_APP"
  # 公証には Hardened Runtime と署名時刻が要る
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$FILTER"
  codesign --verify --strict "$FILTER"
else
  echo "==> Developer ID Application が無いので未署名のままにします"
fi

echo "==> PPD を生成"
EVOLIS_VERSION="$VER" python3 "$HERE/mkppd.py" > "$BUILD/Pebble4.ppd"
# ビルド時はフィルタもアプリもまだ入っていないので、その指摘だけ除外して判定する。
# cupstestppd は失敗を返すので、パイプ(pipefail)ではなく出力を受け取ってから調べる
PROBLEMS="$(cupstestppd "$BUILD/Pebble4.ppd" 2>&1 | grep -F '**FAIL**' \
            | grep -v -e rastertoevolis -e APPrinterUtilityPath || true)"
if [ -n "$PROBLEMS" ]; then
  echo "$PROBLEMS"; echo "PPD に問題があります"; exit 1
fi
install -m 644 "$BUILD/Pebble4.ppd" "$ROOT/usr/local/share/evolis/Pebble4.ppd"
# 「設定」>「プリンタとスキャナ」で追加するときに macOS が見つける場所
gzip -c "$BUILD/Pebble4.ppd" > "$ROOT/Library/Printers/PPDs/Contents/Resources/EvolisPebble4.ppd.gz"
chmod 644 "$ROOT/Library/Printers/PPDs/Contents/Resources/EvolisPebble4.ppd.gz"

echo "==> キュー登録コマンドと本体の機能を呼ぶコマンドを配置"
install -m 755 "$HERE/evolis-setup" "$ROOT/usr/local/bin/evolis-setup"
install -m 755 "$HERE/evolis-tool"  "$ROOT/usr/local/bin/evolis-tool"

echo "==> Evolis Utility.app をビルド"
EVOLIS_SIGN_APP="$SIGN_APP" "$HERE/../app/build-app.sh" "$VER" "$ROOT/Applications"

echo "==> 拡張属性を除去"
xattr -cr "$ROOT" 2>/dev/null || true
find "$ROOT" -name '._*' -delete

cat > "$BUILD/scripts/postinstall" <<'EOS'
#!/bin/bash
# CUPS に新しい PPD を認識させる
killall -HUP cupsd 2>/dev/null || true
exit 0
EOS
chmod 755 "$BUILD/scripts/postinstall"

echo "==> パッケージを作成"
PKG="$BUILD/evolis-pebble4-$VER.pkg"
# アプリは必ず /Applications に入れる(既定ではインストーラが既存のアプリの場所を探して上書きする)
pkgbuild --analyze --root "$ROOT" "$BUILD/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/components.plist"
pkgbuild --root "$ROOT" --scripts "$BUILD/scripts" --component-plist "$BUILD/components.plist" \
         --identifier jp.yukino.evolis-pebble4 --version "$VER" \
         --ownership recommended --install-location / \
         "$PKG"

if [ -n "$SIGN_PKG" ]; then
  echo "==> パッケージに署名: $SIGN_PKG"
  productsign --sign "$SIGN_PKG" "$PKG" "$PKG.signed"
  mv "$PKG.signed" "$PKG"
  pkgutil --check-signature "$PKG" | head -3
else
  echo "==> Developer ID Installer が無いので未署名のままにします"
fi

if [ -n "$NOTARY" ]; then
  [ -n "$SIGN_PKG" ] || { echo "公証には Developer ID Installer の署名が要ります"; exit 1; }
  echo "==> 公証に出します(数分かかります)"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$PKG"        # 結果を pkg に貼って、オフラインでも通るようにする
  xcrun stapler validate "$PKG"
elif [ -n "$SIGN_PKG" ]; then
  echo "==> 公証はしていません。EVOLIS_NOTARY=<プロファイル名> を付けると公証まで行います"
fi

echo
echo "できました: $PKG"
