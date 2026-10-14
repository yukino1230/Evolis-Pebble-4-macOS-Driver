#!/bin/bash
# Printer Application(printer-app/)を通しても、刷る内容が CUPS フィルタと同じかを確かめる。
# プリンタは要らない(出力先がファイルのプリンタを作って、印刷データを比べる)。
#   tests/printer-app.sh
# 先に tests/run.sh(テスト用のラスタと比べる記録)と printer-app/build.sh を実行しておく。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
WORK="$ROOT/build/tests/printer-app"
rm -rf "$WORK"; mkdir -p "$WORK/home/Library/Application Support" "$WORK/out" "$WORK/spool"
# 名前を変えたコピーで動かす。サブコマンドがつなぐソケット(/tmp/<名前><uid>.sock)と状態のファイルの名前が
# プログラムの名前で決まるので、ふだん使うサーバ(evolis-printer-app)とぶつからない
APP="$WORK/evolis-printer-app-test"
cp "$ROOT/build/printer-app/evolis-printer-app" "$APP"
SOCK="/tmp/evolis-printer-app-test$(id -u).sock"
rm -f "$SOCK"                     # 前の回のソケットが残っていると、起動を待たずに先へ進んでしまう
export HOME="$WORK/home"

# private-server: ネットワークでは待ち受けず、ソケットだけで受ける(テスト用のプリンタを広告しない)
"$APP" server -o private-server=true -o log-level=debug -o log-file="$WORK/server.log" \
       -o spool-directory="$WORK/spool" -o server-options=no-tls > "$WORK/stdout.txt" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
# サーバが待ち受けるまで待つ。その前にサブコマンドを使うと、サブコマンドが別のサーバを立ち上げてしまう
for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "the server did not start"; exit 1; }
# USB のプリンタが自動で追加されていたら消す(テストで刷らないように)
"$APP" printers | while read -r p; do "$APP" delete -d "$p"; done
"$APP" add -d Test -v "file://$WORK/out" -m evolis_pebble4
U="ipp://$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SOCK")/ipp/print/Test"

expected() { awk -v n="$1" '$1 == n { print $3 }' "$HERE/expected.txt"; }
FAIL=0
check() {   # 名前 結果 期待
  if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 ($2, expected $3)"; FAIL=1; fi
}
finished() { grep -c -E '\] (Completed|Aborted|Canceled)' "$WORK/server.log" || true; }
send() {    # 名前 ラスタ 形式 リボン オーバーレイ 黒の処理
  local before; before="$(finished)"
  ipptool -q -f "$ROOT/build/tests/$2" -d name="$1" -d filetype="$3" -d ribbon="$4" -d overlay="$5" -d kmode="$6" \
          "$U" "$HERE/print-job.test" 2>/dev/null || true
  for _ in $(seq 1 60); do [ "$(finished)" -gt "$before" ] && break; sleep 0.5; done
  if [ -s "$WORK/out/$1.prn" ]; then shasum -a 256 < "$WORK/out/$1.prn" | cut -c1-16; else echo none; fi
}

# 名前 | ラスタ | 形式 | リボン | オーバーレイ | 黒の処理 | 比べる記録(tests/run.sh)
while read -r name file type ribbon overlay kmode want; do
  check "$name" "$(send "$name" "$file" "$type" "$ribbon" "$overlay" "$kmode")" "$(expected "$want")"
done <<'CASES'
pwg-ymckos    color.ras    image/pwg-raster ymckos full      gray ymckos
urf-ymckos    urf.ras      image/urf        ymckos full      gray ymckos
portrait      portrait.ras image/pwg-raster ymckos full      gray ymckos
k             color.ras    image/pwg-raster k      full      gray k
ymcko         color.ras    image/pwg-raster ymcko  full      gray ymcko
ko            color.ras    image/pwg-raster ko     full      gray ko
chip          color.ras    image/pwg-raster ymckos chipiso   gray ymckos-chip
magstripe     color.ras    image/pwg-raster ymcko  magstripe gray ymcko-mag
k-line        color.ras    image/pwg-raster k      full      line k-line
gray          gray.ras     image/pwg-raster k      full      gray gray
urf-gray      urfgray.ras  image/urf        k      full      gray urf-gray
blank-page    blank2.ras   image/pwg-raster ymckos full      gray blank-page
CASES

# macOS からのジョブには独自属性が付かないので、プリンタの既定値(Web の設定画面や modify で決めたもの)で刷る
"$APP" modify -d Test -o evolis-ribbon=ymckos -o evolis-overlay=chipiso
before="$(finished)"
ipptool -q -f "$ROOT/build/tests/color.ras" -d filetype=image/pwg-raster "$U" /usr/share/cups/ipptool/print-job.test 2>/dev/null || true
for _ in $(seq 1 60); do [ "$(finished)" -gt "$before" ] && break; sleep 0.5; done
out="$(ls -t "$WORK/out"/*.prn | head -1)"
check printer-defaults "$(shasum -a 256 < "$out" | cut -c1-16)" "$(expected ymckos-chip)"

# 変換済みのデータ(application/vnd.evolis)はそのまま送る。evolis-tool がテストカードなどのコマンドを送るのに使う
before="$(finished)"
printf '\033St\r' | "$APP" submit -d Test -o document-format=application/vnd.evolis -o job-name=raw - >/dev/null
for _ in $(seq 1 60); do [ "$(finished)" -gt "$before" ] && break; sleep 0.5; done
check raw-command "$(od -An -c "$WORK/out/raw.prn" 2>/dev/null | tr -s ' ' | sed 's/ *$//')" " 033 S t \r"

# 用紙がカードでないジョブは刷らずに止める(出力が無い。PAPPL が先に開くので空のファイルは残る)
check a4 "$(send a4 a4.ras image/pwg-raster k full gray)" none
# 印刷ダイアログと同じ形(用紙を media-col の大きさで指定)のジョブを受け付けるか(刷らない)
if ipptool -q "$U" "$HERE/validate-job.test"; then echo "OK   validate-job (media-col)"; else echo "FAIL validate-job"; FAIL=1; fi
exit $FAIL
