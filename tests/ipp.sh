#!/bin/bash
# Printer Application の試作(ipp/evolis-ipp-server)を通しても、刷る内容が CUPS フィルタと同じかを確かめる。
# プリンタは要らない(USB に送らずに、印刷データをファイルに書かせて比べる)。
#   tests/ipp.sh
# 先に tests/run.sh を実行しておく(テスト用のラスタと、比べる記録を使う)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
WORK="$ROOT/build/tests/ipp"
PORT=8632
mkdir -p "$WORK/out"
find "$WORK/out" -name '*.prn' -delete

TMPDIR="$WORK" "$ROOT/ipp/evolis-ipp-server" --ribbon ymckos --port $PORT --no-dnssd --output "$WORK/out" \
  > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 60); do
  ipptool -q "ipp://localhost:$PORT/ipp/print" get-printer-attributes.test 2>/dev/null && break
  sleep 1
done

expected() { awk -v n="$1" '$1 == n { sub("exit=", "", $2); print $3 }' "$HERE/expected.txt"; }
FAIL=0
n=0
# 名前 | 送るラスタ | 形式 | 比べる記録(ymckos で刷った tests/run.sh の結果)
while read -r name file type want; do
  n=$((n + 1))
  # 1 ジョブずつしか受けないので、前のジョブが終わるまで待ってから送る
  for _ in $(seq 1 30); do
    ipptool -q -f "$ROOT/build/tests/$file" -d filetype="$type" "ipp://localhost:$PORT/ipp/print" print-job.test \
      2>/dev/null && break
    sleep 1
  done
  for _ in $(seq 1 30); do
    out="$(ls "$WORK/out"/$n-*.prn 2>/dev/null || true)"
    [ -n "$out" ] && grep -q "\[Job $n\] Command .*\(completed\|exited\)" "$WORK/server.log" && break
    sleep 1
  done
  got="$(shasum -a 256 < "${out:-/dev/null}" | cut -c1-16)"
  if [ "$got" = "$(expected "$want")" ]; then echo "OK   $name"; else echo "FAIL $name ($got)"; FAIL=1; fi
done <<'CASES'
pwg      color.ras    image/pwg-raster  ymckos
urf      urf.ras      image/urf         ymckos
portrait portrait.ras image/pwg-raster  ymckos
CASES
exit $FAIL
