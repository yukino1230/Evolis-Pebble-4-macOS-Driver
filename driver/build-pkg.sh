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
         "$ROOT/Applications" \
         "$ROOT/usr/local/libexec/evolis" "$ROOT/Library/LaunchDaemons"

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

echo "==> Printer Application をビルド(ユニバーサル)"
# PAPPL と LibreSSL は初回だけソースからビルドする(printer-app/build-deps.sh)
"$HERE/../printer-app/build.sh" "$VER" "$BUILD/printer-app" >/dev/null
PAPP="$ROOT/usr/local/libexec/evolis/evolis-printer-app"
install -m 755 "$BUILD/printer-app/evolis-printer-app" "$PAPP"
ln -s ../libexec/evolis/evolis-printer-app "$ROOT/usr/local/bin/evolis-printer-app"
# 組み込んだライブラリのライセンス(PAPPL: Apache 2.0、LibreSSL: OpenSSL / ISC)
mkdir -p "$ROOT/usr/local/share/evolis/licenses"
DEPSB="$HERE/../build/deps/build-arm64"
install -m 644 "$DEPSB/pappl/LICENSE" "$ROOT/usr/local/share/evolis/licenses/PAPPL-LICENSE"
install -m 644 "$DEPSB/pappl/NOTICE" "$ROOT/usr/local/share/evolis/licenses/PAPPL-NOTICE"
install -m 644 "$DEPSB/libressl/COPYING" "$ROOT/usr/local/share/evolis/licenses/LibreSSL-COPYING"
# 起動したときから動かす(root の LaunchDaemon)。postinstall で読み込む
install -m 644 "$HERE/../printer-app/jp.yukino.evolis-printer-app.plist" "$ROOT/Library/LaunchDaemons/"
if [ -n "$SIGN_APP" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$PAPP"
  codesign --verify --strict "$PAPP"
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
# PPD は /Library/Printers/PPDs には入れない(--ppd のときだけ使う)。システム設定でプリンタを追加するときは、
# Bonjour の Evolis Pebble 4(Printer Application)を選んでもらい、PPD と取り違えないようにする

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
# v2.0 までが入れた PPD を消す(システム設定でプリンタを追加するときに取り違えないように)。
# 中身が変わったことを CUPS に知らせる
rm -f /Library/Printers/PPDs/Contents/Resources/EvolisPebble4.ppd.gz
killall -HUP cupsd 2>/dev/null || true
# Printer Application を(入れ直したときは止めてから)起動する
LABEL=jp.yukino.evolis-printer-app
# ほかの機器と共有するかの設定。無ければ(初めてと v2.0.x から上げたとき)、この Mac からだけ使う設定にする
CONF="/Library/Application Support/evolis-printer-app.conf"
if [ ! -f "$CONF" ]; then
  mkdir -p "/Library/Application Support"
  printf '%s\n' "# evolis-setup --share / --no-share が書き換える(この 2 行があると、この Mac からだけ使える)" \
                 "listen-hostname=localhost" "server-hostname=localhost" > "$CONF"
  chmod 644 "$CONF"
fi
mkdir -p /private/var/spool/evolis-printer-app
# 止めるのは非同期なので、止まりきってから起動する(止まる前に起動すると失敗し、動かないままになる)
launchctl bootout "system/$LABEL" 2>/dev/null || true
# v2.1.1 までの evolis-printer-app のサブコマンドが立ち上げてしまったサーバ(private-server)が残っていれば止める
pkill -f "evolis-printer-app server -o private-server=true" 2>/dev/null || true
for _ in $(seq 1 40); do launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
for _ in 1 2 3 4 5; do
  launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null && break
  launchctl print "system/$LABEL" >/dev/null 2>&1 && break
  sleep 1
done
# Printer Application の中にプリンタを作っておく(USB につないでいなくても作れる)。
# これで、ターミナルを使わなくても「プリンタを追加」に Bonjour の Evolis Pebble 4 が出る
# 待ち受けるまで待ってから呼ぶ。前のソケットのファイルが残っていることがあるので、ファイルがあるかではなく、
# ポート 8630 で待ち受けているかを見る(待ち受ける前に呼ぶと、evolis-printer-app が別のサーバを立ち上げてしまう)
APP=/usr/local/libexec/evolis/evolis-printer-app
listening() { lsof -nP -iTCP:8630 -sTCP:LISTEN 2>/dev/null | grep -q evolis; }
for _ in $(seq 1 60); do listening && break; sleep 0.25; done
if listening; then
  "$APP" printers 2>/dev/null | grep -qx "Evolis Pebble 4" \
    || "$APP" add -d "Evolis Pebble 4" -v "evolis-usb://Evolis/Pebble%204" -m evolis_pebble4 >/dev/null 2>&1 || true
fi
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
