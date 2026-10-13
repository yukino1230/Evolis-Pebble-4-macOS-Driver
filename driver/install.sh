#!/bin/bash
# Evolis Pebble 4 用 macOS ドライバのインストール
#   sudo driver/install.sh [--ribbon k|ymcko|ymckos] [--queue Evolis_Pebble_4] [--uri usb://EVOLIS/Pebble?location=...]
#     --ribbon は印刷ダイアログの既定のリボン(装着しているものに合わせる。既定 k)
#       k 黒 / ymcko / ymckos(ハーフパネル) / ko 黒+オーバーレイ /
#       kw 白 / kr 赤 / kbl 青 / kgr 緑 / kgo 金 / ksi 銀 / ksc スクラッチ / ka 黒ワックス
#   sudo driver/install.sh --uninstall
set -euo pipefail

QUEUE="Evolis_Pebble_4"
URI=""
RIBBON="k"
UNINSTALL=0
# メッセージの言語: LANG が ja なら日本語、それ以外は英語。LANG が無いとき(sudo で消えたときなど)は
# macOS の言語設定(AppleLanguages の先頭)を見る
lang="${LANG:-}"
if [ -z "$lang" ]; then
  u="${SUDO_USER:-$(id -un)}"
  lang="$( (if [ "$(id -u)" = 0 ] && [ "$u" != root ]; then sudo -u "$u" defaults read -g AppleLanguages; \
           else defaults read -g AppleLanguages; fi) 2>/dev/null | sed -n '2s/[^a-z]*\([a-z][a-z]\).*/\1/p')"
fi
case "$lang" in ja*) JA=1 ;; *) JA=0 ;; esac
say() { if [ "$JA" = 1 ]; then echo "$2"; else echo "$1"; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    --queue)     QUEUE="$2"; shift 2 ;;
    --uri)       URI="$2"; shift 2 ;;
    --ribbon)    RIBBON="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) say "Unknown argument: $1" "不明な引数: $1"; exit 1 ;;
  esac
done

case "$RIBBON" in k|ymcko|ymckos|ko|kw|kr|kbl|kgr|kgo|ksi|ksc|ka) ;;
  *) say "--ribbon must be one of k / ymcko / ymckos / ko / kw / kr / kbl / kgr / kgo / ksi / ksc / ka" \
         "--ribbon は k / ymcko / ymckos / ko / kw / kr / kbl / kgr / kgo / ksi / ksc / ka のどれか"; exit 1 ;; esac
[ "$(id -u)" = "0" ] || { say "Run with sudo" "sudo で実行してください"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
FILTER=/usr/local/libexec/cups/filter/rastertoevolis
SHARE=/usr/local/share/evolis

if [ "$UNINSTALL" = "1" ]; then
  say "==> Removing the queue: $QUEUE" "==> キューを削除: $QUEUE"
  lpadmin -x "$QUEUE" 2>/dev/null || say "    (no such queue)" "    (キューは存在しませんでした)"
  rm -f "$FILTER"
  rm -rf "$SHARE"
  say "Done." "完了しました。"
  exit 0
fi

say "==> Looking for the printer" "==> プリンタを探す"
if [ -z "$URI" ]; then
  URI="$(lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\/EVOLIS\// {print $2; exit}')"
fi
[ -n "$URI" ] || { say "    No Evolis printer found on USB. Check the power and cable, or pass --uri" \
                        "    USB で Evolis が見つかりません。電源と接続を確認するか --uri で指定してください"; exit 1; }
echo "    $URI"

say "==> Building (universal) and installing the CUPS filter" "==> CUPS フィルタをビルド(ユニバーサル)して設置"
install -d -o root -g wheel -m 755 /usr/local/libexec/cups/filter "$SHARE"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
clang -O2 -Wall -arch arm64 -arch x86_64 -o "$TMP/rastertoevolis" "$HERE/rastertoevolis.c"
install -o root -g wheel -m 755 "$TMP/rastertoevolis" "$FILTER"
echo "    $FILTER"

say "==> Generating the PPD" "==> PPD を生成"
PPD="$SHARE/Pebble4.ppd"
python3 "$HERE/mkppd.py" > "$PPD"
chown root:wheel "$PPD"; chmod 644 "$PPD"
# Evolis Utility.app は pkg で入れるもので、install.sh では入らないので、その指摘は除外する
PROBLEMS="$(cupstestppd "$PPD" 2>&1 | grep -F '**FAIL**' | grep -v -e APPrinterUtilityPath || true)"
if [ -n "$PROBLEMS" ]; then
  echo "$PROBLEMS"; say "The PPD has problems" "PPD に問題があります"; exit 1
fi
echo "    OK"

say "==> Creating the printer queue: $QUEUE" "==> プリンタキューを登録: $QUEUE"
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" \
        -D "Evolis Pebble 4" -L "USB" -o printer-is-shared=false -o EvolisRibbon="$RIBBON" \
        -o printer-error-policy=abort-job
# USB の送信処理が失敗したとき(ジョブの途中で電源を切ったときなど)、キュー全体を止めずにそのジョブだけ取り消す。
# ドライバ(フィルタ)が止めたジョブは、この設定と関係なくそのジョブだけが止まる
say "    Default ribbon: $RIBBON" "    既定のリボン: $RIBBON"

echo
say "Done. \"Evolis Pebble 4\" appears in the print dialog." "完了しました。印刷ダイアログに「Evolis Pebble 4」が出ます。"
say "  Uninstall: sudo $0 --uninstall" "  アンインストール: sudo $0 --uninstall"
