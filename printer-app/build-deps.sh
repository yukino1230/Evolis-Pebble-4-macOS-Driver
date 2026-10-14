#!/bin/bash
# Printer Application が使うライブラリ(PAPPL と LibreSSL)をソースからビルドする。
#   printer-app/build-deps.sh
#
# どちらも静的ライブラリにして、Intel / Apple Silicon の両方を lipo で 1 つにまとめる。
# 出来上がり: build/deps/universal/{include,lib}
#
# - PAPPL: Printer Application を作るためのライブラリ(Apache 2.0)。IPP Everywhere のサーバ、
#   Web の設定画面、DNS-SD の広告、ジョブの管理を受け持つ
# - LibreSSL: PAPPL が要る TLS(ISC / OpenSSL ライセンス)。macOS には開発用のものが無いので自分で入れる
# - USB は libusb を使わず、IOUSBHost で自前の仕組みを PAPPL に登録する(usb-device.m)。
#   JPEG / PNG は使わない(IPP Everywhere / AirPrint ではラスタで届く)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPS="$HERE/../build/deps"
SRC="$DEPS/src"
OUT="$DEPS/universal"
export MACOSX_DEPLOYMENT_TARGET=13.0
JOBS="$(sysctl -n hw.ncpu)"

PAPPL_VER=1.4.12
PAPPL_SHA=1684c4e06446e9f7d93a39729fa0ba56f07a4007560080fdad7d0e2076a3615f
LIBRESSL_VER=4.3.3
LIBRESSL_SHA=ff97c432457f349e6ba3d416ab903bc7468f1436f0f32efe5fff808de292c7b8

fetch() {   # URL ファイル名 SHA-256
  [ -f "$SRC/$2" ] || curl -fsSL -o "$SRC/$2" "$1"
  echo "$3  $SRC/$2" | shasum -a 256 -c - >/dev/null || { echo "SHA-256 が合いません: $2" >&2; exit 1; }
}
mkdir -p "$SRC"
fetch "https://github.com/michaelrsweet/pappl/releases/download/v$PAPPL_VER/pappl-$PAPPL_VER.tar.gz" \
      "pappl-$PAPPL_VER.tar.gz" "$PAPPL_SHA"
fetch "https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-$LIBRESSL_VER.tar.gz" \
      "libressl-$LIBRESSL_VER.tar.gz" "$LIBRESSL_SHA"

for arch in arm64 x86_64; do
  PREFIX="$DEPS/$arch"
  HOST="$([ $arch = arm64 ] && echo aarch64 || echo x86_64)-apple-darwin"
  export CC="clang -arch $arch" CFLAGS="-O2 -arch $arch" LDFLAGS="-arch $arch"

  if [ ! -f "$PREFIX/lib/libssl.a" ]; then
    echo "==> LibreSSL $LIBRESSL_VER ($arch)"
    B="$DEPS/build-$arch/libressl"; rm -rf "$B"; mkdir -p "$B"
    tar xzf "$SRC/libressl-$LIBRESSL_VER.tar.gz" -C "$B" --strip-components 1
    (cd "$B" && ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --enable-static \
                 --disable-tests >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  fi

  if [ ! -f "$PREFIX/lib/libpappl.a" ]; then
    echo "==> PAPPL $PAPPL_VER ($arch)"
    B="$DEPS/build-$arch/pappl"; rm -rf "$B"; mkdir -p "$B"
    tar xzf "$SRC/pappl-$PAPPL_VER.tar.gz" -C "$B" --strip-components 1
    # サブコマンド(options / modify など)がサーバにつなげないとき、自分でサーバを立ち上げないようにする。
    # このドライバでは Printer Application は LaunchDaemon で動かすので、立ち上がると同じ状態のファイルを
    # 使うサーバが 2 つになってしまう(つながらないときは、エラーで終わればよい)
    sed -i '' 's/if (!http \&\& auto_start)/if (!http \&\& auto_start \&\& getenv("EVOLIS_ALLOW_PRIVATE_SERVER"))/' \
        "$B/pappl/mainloop-support.c"
    grep -q 'EVOLIS_ALLOW_PRIVATE_SERVER' "$B/pappl/mainloop-support.c" || { echo "PAPPL に変更を当てられません" >&2; exit 1; }
    (cd "$B" && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
       ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --with-tls=libressl \
                   --with-dnssd=mdnsresponder --disable-libjpeg --disable-libpng --disable-libusb \
                   --disable-libpam >/dev/null \
       && make -C pappl -j"$JOBS" libpappl.a >/dev/null)
    mkdir -p "$PREFIX/lib" "$PREFIX/include/pappl"
    cp "$B/pappl/libpappl.a" "$PREFIX/lib/"
    cp "$B"/pappl/*.h "$PREFIX/include/pappl/"
  fi
done

echo "==> まとめる(lipo)"
rm -rf "$OUT"; mkdir -p "$OUT/lib"
cp -R "$DEPS/arm64/include" "$OUT/"
for lib in libpappl.a libssl.a libcrypto.a libtls.a; do
  lipo -create -output "$OUT/lib/$lib" "$DEPS/arm64/lib/$lib" "$DEPS/x86_64/lib/$lib"
done
lipo -info "$OUT/lib/libpappl.a"
echo "できました: $OUT"
