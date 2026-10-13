# Evolis Pebble 4 を macOS から使う

ID カードプリンタ **Evolis Pebble 4** を macOS から印刷できるようにする試みです。
Evolis は現行の macOS ドライバを Pebble 世代には出していません（互換性表に Pebble の行が無い）。

> Driving the Evolis Pebble 4 ID card printer from macOS. Evolis ships no current macOS driver for
> this generation, but the printer's command set is documented and the transport is USB printer class.

**macOS の印刷ダイアログから印刷できます（2026-10-13、macOS 27.0.1 / Apple Silicon で確認）。** 黒（K）リボンと、カラー（YMCKO）リボンのハーフパネル（R3013）で実機確認済みです。全面パネルの YMCKO リボンは設定を用意してありますが、実機では試していません。Pebble 4 は片面専用の機種です。

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

### カラー（YMCKO）の印刷（2026-10-13、ツールから成功）

[A5013](https://idoc.pub/documents/programming-guide-evolis-qu2-en5k9g7wqpno) と
[qz-tray の実装](https://github.com/qzind/tray/blob/master/src/qz/printer/action/raw/converter/Evolis.java)に従った形で刷れた。

```
ESC Pr;ymckos CR                    リボン（R3013 ハーフパネルなら ymckos、全面パネルなら ymcko）
ESC Ss CR
ESC Sr CR
ESC Db;y;32;<411480 バイト> CR      Y/M/C は 1 ドット 5bit をビット単位で詰める（MSB が先）。値はインク量で 0 = 塗らない
ESC Db;m;32;<411480 バイト> CR
ESC Db;c;32;<411480 バイト> CR
ESC Db;k;2;<82296 バイト> CR        黒（樹脂）は 1bit
ESC Db;o;2;<82296 バイト> CR        オーバーレイ。1 = 保護層を乗せる
ESC Se CR
```

- ドットの並びは黒と同じ（カードを時計回りに 90° 回し、1 行 648 ドット × 1016 行）
- **`Pr` で設定したリボンの種類は本体に保存される。** `Rr;p` で読める
- **リボンの種類を間違えるとジャムる。** ハーフパネルの R3013 に `ymcko` を送ったら、印刷途中で止まってカードが詰まった
- **ハーフパネル（R3013）で色が乗るのはカードの左側だけ。** 左端から約 43%（約 435 ドット）。黒とオーバーレイは全面
- 黒に近い色（RGB の最大値が 15% 未満）は黒パネルに回している。グレーの階調に段差が出るので要改善
- **黒パネルの網点は、点を散らす誤差拡散だと 60% 前後で真っ黒に潰れる**（樹脂の黒が 1 ドットごとににじむ）。
  点を中心から太らせる 6×6 の網点（50 線）にして、[目盛りカード](tools/make_halftone_cal.py)で測った補正をかけている。
  R3013 の黒パネルで刷って測った結果（指定 % → 見た目の %）:

  | 指定 | 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 |
  |---|---|---|---|---|---|---|---|---|---|
  | 誤差拡散（補正なし） | 8 | 14 | 40 | 74 | 53 | 101 | 106 | 106 | 106 |
  | 6×6 網点、指定^1.6 | 0 | 10 | 17 | 30 | 47 | 63 | 76 | 92 | 103 |
- 黒パネルでは、色は明るさだけのグレーにして網点で刷る（真っ黒は黒ベタ）。濃さ 60% 以上を黒ベタに
  切り替える版も試したが、グラデーションが途中で急に黒ベタになるのでやめた。
- **ハーフパネルのリボンでカードを作るときは、色を使う部分を左側（約 36mm）に置き、右側は黒と白だけで作る。**
  右側の色はグレーの網点になる（たとえば濃い青の帯は濃さ 72% の網点）。黒ベタで出したい部分は、
  ドライバに任せずデザインの段階で黒にしておく

```bash
cd tools
../.venv/bin/python make_colorcard.py /tmp/colorcard.png
../.venv/bin/python evolis_print.py /tmp/colorcard.png --ribbon ymckos --send
```

## CUPS ドライバ

[`driver/`](driver/) に、印刷ダイアログから使うための CUPS フィルタと PPD がある。
[MultiImpact 700XX のドライバ](https://github.com/yukino1230/multiimpact-700xx-macos-driver)と同じ作りで、
PDF → ラスタ変換は macOS 標準の `cgpdftoraster` に任せ、ラスタ → `Db` の変換だけを C で書いている。
libcups にも Ghostscript にも依存しない。

| | |
|---|---|
| 用紙 | CR80（85.6×54mm、横長）。縁なしでカード全面に印刷する |
| 解像度 | 300dpi、1bit 白黒 |
| 1 ページ | カード 1 枚（ページごとに `Ss`〜`Se`） |
| 配置 | 1011×638 ドットのラスタを、プリンタの 1016×648 の中央に置く。縦長のページは横向きに回す |

```bash
xcode-select --install                 # clang が要る
sudo driver/install.sh                 # USB の Evolis を探してキュー Evolis_Pebble_4 を作る
sudo driver/install.sh --uninstall
```

テストカードの PDF を `cupsfilter` → `rastertoevolis` に通し、出力のビットマップを画像に戻して、
向きと位置が元画像と一致することを確かめた。そのうえで、実機の印刷ダイアログからカードが刷れることを確認済み（macOS 27.0.1 / Apple Silicon、USB 接続）。

## 最初にやること

1. ~~USB で Mac に繋ぎ、`system_profiler SPUSBDataType` と `lpinfo -v` で見えるか確認する~~ ✅
2. ~~双方向に話すために `libusb` を入れる（`brew install libusb`）~~ ✅
3. ~~**`ESC Rtp` を投げて機種名が返るか**を見る~~ ✅ `Pebble 4` が返った
4. ~~ラスタ → `Db` の変換~~ ✅ 片面・黒で成功
5. ~~CUPS から使えるようにする~~ ✅ 印刷ダイアログから印刷できた
6. ~~カラー（YMCKO）をツールから刷る~~ ✅
7. ~~CUPS ドライバのカラー対応~~ ✅ 印刷ダイアログでリボンを選べる
8. コントラストなどのオプション、配布用の pkg

## 進め方のメモ

- **実際にカードを走らせる前には必ず声をかける。** カードとリボンは消耗品
- 黒単色（K）リボンなら上のコマンド列がそのまま使える。カラー（YMCKO）はパネルごとの送信（`Dbp` / `Sp`）を実機で詰める必要がある
- 機種は **Pebble 4**（本体で確認済み）。A5013 は "New Pebble" 世代の表なので、`ESC Rtp` の返事で実機との対応を確かめる

## 参考

- [NEC MultiImpact 700XX の macOS ドライバ](https://github.com/yukino1230/multiimpact-700xx-macos-driver) — 同じ作り方（キャプチャと仕様書から自前のフィルタを書く）で作ったドットインパクトプリンタ用ドライバ。CUPS フィルタと PAPPL のプリンタアプリの両方の実装例がある
