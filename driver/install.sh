#!/bin/bash
# Evolis Pebble 4 用 macOS ドライバのインストール
#   sudo driver/install.sh [--queue Evolis_Pebble_4] [--uri usb://EVOLIS/Pebble?location=...]
#   sudo driver/install.sh --uninstall
set -euo pipefail

QUEUE="Evolis_Pebble_4"
URI=""
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --queue)     QUEUE="$2"; shift 2 ;;
    --uri)       URI="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "不明な引数: $1"; exit 1 ;;
  esac
done

[ "$(id -u)" = "0" ] || { echo "sudo で実行してください"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
FILTER=/usr/local/libexec/cups/filter/rastertoevolis
SHARE=/usr/local/share/evolis

if [ "$UNINSTALL" = "1" ]; then
  echo "==> キューを削除: $QUEUE"
  lpadmin -x "$QUEUE" 2>/dev/null || echo "    (キューは存在しませんでした)"
  rm -f "$FILTER"
  rm -rf "$SHARE"
  echo "完了しました。"
  exit 0
fi

echo "==> プリンタを探す"
if [ -z "$URI" ]; then
  URI="$(lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\/EVOLIS\// {print $2; exit}')"
fi
[ -n "$URI" ] || { echo "    USB で Evolis が見つかりません。電源と接続を確認するか --uri で指定してください"; exit 1; }
echo "    $URI"

echo "==> CUPS フィルタをビルド(ユニバーサル)して設置"
install -d -o root -g wheel -m 755 /usr/local/libexec/cups/filter "$SHARE"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
clang -O2 -Wall -arch arm64 -arch x86_64 -o "$TMP/rastertoevolis" "$HERE/rastertoevolis.c"
install -o root -g wheel -m 755 "$TMP/rastertoevolis" "$FILTER"
echo "    $FILTER"

echo "==> PPD を生成"
PPD="$SHARE/Pebble4.ppd"
python3 "$HERE/mkppd.py" > "$PPD"
chown root:wheel "$PPD"; chmod 644 "$PPD"
if cupstestppd "$PPD" | grep -qE "FAIL|失敗"; then
  cupstestppd "$PPD" | grep -E "FAIL|失敗"
  echo "PPD に問題があります"; exit 1
fi
echo "    OK"

echo "==> プリンタキューを登録: $QUEUE"
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" \
        -D "Evolis Pebble 4" -L "USB" -o printer-is-shared=false

echo
echo "完了しました。印刷ダイアログに「Evolis Pebble 4」が出ます。"
echo "  アンインストール: sudo $0 --uninstall"
