#!/bin/bash
# フィルタの出力が変わっていないかを確かめる。
#   tests/run.sh            expected.txt と比べる
#   tests/run.sh --update   今の出力を expected.txt に記録する(刷り方を意図して変えたとき)
#
# 入力は tests/make_raster.py で作るラスタ。出力(プリンタに送るバイト列)の SHA-256 と終了コードを比べる。
# 刷られるカードが同じかどうかは、出力が 1 バイトも変わらないことで確かめる。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
WORK="$ROOT/build/tests"
mkdir -p "$WORK"

clang -O2 -Wall -Werror -o "$WORK/rastertoevolis" "$ROOT"/driver/rastertoevolis.c "$ROOT"/driver/evolis_card.c
for kind in color portrait gray mono rle blank2 a4 urf urfgray; do
  [ -s "$WORK/$kind.ras" ] || python3 "$HERE/make_raster.py" "$kind" "$WORK/$kind.ras"
done
# キューの PPD の既定値を読むか(DefaultEvolisRibbon を ymckos にしたもの)
python3 "$ROOT/driver/mkppd.py" | sed 's/^\*DefaultEvolisRibbon: k$/*DefaultEvolisRibbon: ymckos/' > "$WORK/test.ppd"

# 名前 | 入力 | オプション | PPD を使うか
CASES='
k            | color    | EvolisRibbon=k                       |
ymcko        | color    | EvolisRibbon=ymcko                   |
ymckos       | color    | EvolisRibbon=ymckos                  |
ko           | color    | EvolisRibbon=ko                      |
kr           | color    | EvolisRibbon=kr                      |
ymckos-chip  | color    | EvolisRibbon=ymckos EvolisOverlay=chipiso |
ymcko-mag    | color    | EvolisRibbon=ymcko EvolisOverlay=magstripe |
ymcko-noov   | color    | EvolisRibbon=ymcko EvolisOverlay=none |
k-line       | color    | EvolisRibbon=k EvolisKMode=line      |
ymckos-line  | color    | EvolisRibbon=ymckos EvolisKMode=line |
levels32     | color    | EvolisRibbon=ymcko EvolisColorLevels=32 |
levels64     | color    | EvolisRibbon=ymcko EvolisColorLevels=64 |
levels       | color    | EvolisRibbon=ymcko EvolisContrastK=4 EvolisContrastColor=16 EvolisBrightness=14 EvolisContrastOverlay=6 |
bad-values   | color    | EvolisRibbon=zzz EvolisContrastK=99 EvolisOverlay=x EvolisColorLevels=50 |
portrait     | portrait | EvolisRibbon=ymckos                  |
gray         | gray     | EvolisRibbon=k                       |
mono         | mono     | EvolisRibbon=k                       |
rle          | rle      | EvolisRibbon=ymckos                  |
blank-page   | blank2   | EvolisRibbon=ymckos                  |
a4           | a4       | EvolisRibbon=k                       |
urf          | urf      | EvolisRibbon=ymckos                  |
urf-gray     | urfgray  | EvolisRibbon=k                       |
ppd-default  | color    |                                      | ppd
ppd-override | color    | EvolisRibbon=k                       | ppd
'

RESULT="$WORK/result.txt"; : > "$RESULT"
while IFS='|' read -r name input opts ppd; do
  name="$(echo $name)"; [ -n "$name" ] || continue
  input="$(echo $input)"; opts="$(echo $opts)"; ppd="$(echo $ppd)"
  set +e
  if [ -n "$ppd" ]; then
    PPD="$WORK/test.ppd" LANG=C "$WORK/rastertoevolis" 1 user title 1 "$opts" "$WORK/$input.ras" > "$WORK/$name.out" 2> "$WORK/$name.log"
  else
    env -u PPD LANG=C "$WORK/rastertoevolis" 1 user title 1 "$opts" "$WORK/$input.ras" > "$WORK/$name.out" 2> "$WORK/$name.log"
  fi
  code=$?
  set -e
  printf '%-13s exit=%d %s\n' "$name" "$code" "$(shasum -a 256 < "$WORK/$name.out" | cut -c1-16)" >> "$RESULT"
done <<< "$CASES"

if [ "${1:-}" = "--update" ]; then
  cp "$RESULT" "$HERE/expected.txt"; echo "expected.txt を更新しました"; exit 0
fi
if diff -u "$HERE/expected.txt" "$RESULT"; then
  echo "OK: $(wc -l < "$RESULT" | tr -d ' ') 件とも同じ"
else
  echo "出力が変わりました(意図した変更なら tests/run.sh --update)"; exit 1
fi
