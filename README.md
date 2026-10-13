# Evolis Pebble 4 を macOS から使う

ID カードプリンタ **Evolis Pebble 4** を macOS から印刷できるようにする試みです。
Evolis は現行の macOS ドライバを Pebble 世代には出していません（互換性表に Pebble の行が無い）。

> Driving the Evolis Pebble 4 ID card printer from macOS. Evolis ships no current macOS driver for
> this generation, but the printer's command set is documented and the transport is USB printer class.

**黒（K）リボンで片面印刷ができました（2026-10-13）。** CUPS からはまだ使えません。

## 分かっていること（2026-10-13 時点の調査）

| | |
|---|---|
| コマンドリファレンス | **公式の [Evolis Card Printers Programming Guide A5013](https://manualzz.com/doc/1932591/evolis-card-printers-programming-guide-a5013_reve)** が New Pebble / Tattoo / Dualys / Quantum / Kiosk をカバー。[Rev.D2 は表紙が "NEW PEBBLE PROGRAMMING GUIDE"](https://www.yumpu.com/en/document/view/54519120/new-pebble-programming-guide-a5013-revd2/9) |
| 公式 Linux ドライバ | 2014年12月に **Pebble 2 / 3 / 4** を含む世代向けの RPM / DEB が出ている（現在はレガシー扱い） |
| 公式 macOS ドライバ | [現行の互換性表](https://www.evolis.com/wp-content/uploads/2022/05/Drivers-Compatibility-Chart-ENG.pdf)に **Pebble の行は無い** |
| オープンソースの実装例 | [dpavlin/Printer-EVOLIS](https://github.com/dpavlin/Printer-EVOLIS)（Dualys 3 向け、Perl、GPLv2+）。実際に送るバイト列が読める |
| 接続 | **USB プリンタクラス**（Windows が `USBPRINT\EVOLISPEBBLE…` として認識する）。macOS でも生バイトを流せるはずで、カーネル拡張は要らない |

### コマンドの形

`ESC` + ASCII + `CR`。[`evolis-driver.pl`](https://github.com/dpavlin/Printer-EVOLIS/blob/master/scripts/evolis-driver.pl) より:

```
ESC Pr;k      CR   リボン: 黒
ESC Pmi;F;s   CR   挿入モード
ESC Pc;k;=;10 CR   コントラスト
ESC Ss        CR   シーケンス開始
ESC Sr        CR   表面
ESC Db;k;2;<ビットマップ> CR   ビットマップ送信(1bit パック)
ESC Sv        CR   裏面
ESC Se        CR   シーケンス終了
+ 0x00 x 64 のパディング
```

問い合わせ系（[`evolis-command.pl`](https://github.com/dpavlin/Printer-EVOLIS/blob/master/scripts/evolis-command.pl) より）。**カードもリボンも使いません**:

| コマンド | 返るもの |
|---|---|
| `ESC Rtp CR` | プリンタの機種名 |
| `ESC Rfv CR` | ファームウェアのバージョン |
| `ESC Rsn CR` | シリアル番号 |
| `ESC Rco;l CR` | リボンのカウンタ |

## 実機で確かめたこと（2026-10-13）

| | |
|---|---|
| USB | VID `0x0F49` / PID `0x0100`、bcdDevice `0x0602`。インターフェース 0 がプリンタクラス（class 7 / protocol 2 = 双方向、bulk OUT/IN）。CUPS からは `usb://EVOLIS/Pebble?location=20100000` |
| 通信 | macOS は class 7 を掴まないので、libusb（pyusb）でそのまま claim できる |
| 返事の形 | ASCII + `\0` 終端。**次のコマンドを送るまで、IN を読むたびに同じ返事が繰り返し返ってくる**ので最初の `\0` で切る |

[`tools/evolis_query.py`](tools/evolis_query.py) の結果:

| コマンド | 返事 |
|---|---|
| `Rtp` | `Pebble 4` — A5013 のコマンド体系がそのまま通る |
| `Rfv` | `1012` |
| `Rsn` | `PB0839xxxxxxx` |
| `Rco;l` | `2`（リボン残量？ 単位は要確認） |
| `Rkn` | `411-D85xxxxx-D`（リボンの識別子？） |
| `Rse` | `ERROR CDE` — 未知コマンドはこの形で返る |

```bash
python3 -m venv .venv && .venv/bin/pip install pyusb
.venv/bin/python tools/evolis_query.py            # Rtp Rfv Rsn Rco;l
.venv/bin/python tools/evolis_query.py "Rco;l" Rkn
```

### 片面・黒の印刷（2026-10-13 成功）

[`tools/evolis_print.py`](tools/evolis_print.py) が送るのは次の最小構成。`Pmi`（挿入モード）と `Pc`（コントラスト）は送らず、本体の既定値で通った。

```
ESC Pr;k CR
ESC Ss CR
ESC Sr CR
ESC Db;k;2;<82296 バイト> CR
ESC Se CR
0x00 x 64
```

- 画像はカード全面 **1016×648 ドット（300dpi、横長）**
- 時計回りに 90° 回したものを送る。1 行が 648 ドット = 81 バイトで、それが 1016 行。MSB が先で **1 = 黒**
- この向きで、画面で見たままカードに刷られた（上下左右の反転なし）

```bash
.venv/bin/pip install pillow
cd tools
../.venv/bin/python make_testcard.py /tmp/testcard.png
../.venv/bin/python evolis_print.py /tmp/testcard.png --send
```

## 最初にやること

1. ~~USB で Mac に繋ぎ、`system_profiler SPUSBDataType` と `lpinfo -v` で見えるか確認する~~ ✅
2. ~~双方向に話すために `libusb` を入れる（`brew install libusb`）~~ ✅
3. ~~**`ESC Rtp` を投げて機種名が返るか**を見る~~ ✅ `Pebble 4` が返った
4. ~~ラスタ → `Db` の変換~~ ✅ 片面・黒で成功
5. CUPS から使えるようにする（CUPS フィルタか PAPPL のプリンタアプリ）

## 進め方のメモ

- **実際にカードを走らせる前には必ず声をかける。** カードとリボンは消耗品
- 黒単色（K）リボンなら上のコマンド列がそのまま使える。カラー（YMCKO）はパネルごとの送信（`Dbp` / `Sp`）を実機で詰める必要がある
- 機種は **Pebble 4**（本体で確認済み）。A5013 は "New Pebble" 世代の表なので、`ESC Rtp` の返事で実機との対応を確かめる

## 参考

- [NEC MultiImpact 700XX の macOS ドライバ](https://github.com/yukino1230/multiimpact-700xx-macos-driver) — 同じ作り方（キャプチャと仕様書から自前のフィルタを書く）で作ったドットインパクトプリンタ用ドライバ。CUPS フィルタと PAPPL のプリンタアプリの両方の実装例がある
