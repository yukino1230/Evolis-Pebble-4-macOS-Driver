# Evolis Pebble 4 を macOS から使う

ID カードプリンタ **Evolis Pebble 4** を macOS から印刷できるようにする試みです。
Evolis は現行の macOS ドライバを Pebble 世代には出していません（互換性表に Pebble の行が無い）。

> Driving the Evolis Pebble 4 ID card printer from macOS. Evolis ships no current macOS driver for
> this generation, but the printer's command set is documented and the transport is USB printer class.

**まだ何も動いていません。** 分かっていることと、最初にやることを書いた状態です。

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

## 最初にやること

1. USB で Mac に繋ぎ、`system_profiler SPUSBDataType` と `lpinfo -v` で見えるか確認する
2. 双方向に話すために `libusb` を入れる（`brew install libusb`）
3. **`ESC Rtp` を投げて機種名が返るか**を見る。これが通れば A5013 のコマンド表が使えることが確定する
4. 返事の形を見てから、ラスタ → `Db` の変換（CUPS フィルタか PAPPL のプリンタアプリ）に進む

## 進め方のメモ

- **実際にカードを走らせる前には必ず声をかける。** カードとリボンは消耗品
- 黒単色（K）リボンなら上のコマンド列がそのまま使える。カラー（YMCKO）はパネルごとの送信（`Dbp` / `Sp`）を実機で詰める必要がある
- 機種は **Pebble 4**（本体で確認済み）。A5013 は "New Pebble" 世代の表なので、`ESC Rtp` の返事で実機との対応を確かめる

## 参考

- [NEC MultiImpact 700XX の macOS ドライバ](https://github.com/yukino1230/multiimpact-700xx-macos-driver) — 同じ作り方（キャプチャと仕様書から自前のフィルタを書く）で作ったドットインパクトプリンタ用ドライバ。CUPS フィルタと PAPPL のプリンタアプリの両方の実装例がある
