#!/usr/bin/env python3
"""Evolis Pebble 4（片面）用の PPD を生成する。

出力は Shift-JIS（PPD 仕様で UTF-8 は使えないため）。
"""
import sys

MM = 72 / 25.4
W, H = round(85.6 * MM, 2), round(54.0 * MM, 2)   # CR80 (ISO/IEC 7810 ID-1)、横長
FILTER = "/usr/local/libexec/cups/filter/rastertoevolis"
# Pr に送る値と表示名。driver/rastertoevolis.c の RIBBONS と合わせる
RIBBONS = [
    ("k", "黒 (モノクロ)"),
    ("ymcko", "YMCKO カラー (全面パネル)"),
    ("ymckos", "YMCKO カラー (ハーフパネル R3013 など)"),
    ("ko", "黒 + オーバーレイ (KO)"),
    ("kw", "白 (モノクロ)"),
    ("kr", "赤 (モノクロ)"),
    ("kbl", "青 (モノクロ)"),
    ("kgr", "緑 (モノクロ)"),
    ("kgo", "金 (モノクロ)"),
    ("ksi", "銀 (モノクロ)"),
    ("ksc", "スクラッチ (モノクロ)"),
    ("ka", "黒ワックス (モノクロ)"),
]


def main():
    p = []
    def w(s): p.append(s)
    w('*PPD-Adobe: "4.3"')
    w('*FormatVersion: "4.3"')
    w('*FileVersion: "1.0"')
    w('*LanguageEncoding: JIS83-RKSJ')
    w('*LanguageVersion: Japanese')
    w('*Manufacturer: "Evolis"')
    w('*ModelName: "Evolis Pebble 4"')
    w('*ShortNickName: "Evolis Pebble 4"')
    w('*NickName: "Evolis Pebble 4"')
    w('*PCFileName: "PEBBLE4.PPD"')
    w('*Product: "(Pebble 4)"')
    w('*1284DeviceID: "MFG:EVOLIS;MDL:Pebble;"')
    # 「設定」>「プリンタとスキャナ」の「プリンタユーティリティを開く」で起動するアプリ
    w('*APPrinterUtilityPath: "/Applications/Evolis Utility.app"')
    w('*PSVersion: "(3010.000) 0"')
    w('*LanguageLevel: "3"')
    w('*ColorDevice: True')
    w('*DefaultColorSpace: RGB')
    w('*FileSystem: False')
    w('*Throughput: "1"')
    w('*cupsVersion: 2.3')
    w('*cupsModelNumber: 0')
    w('*cupsManualCopies: True')
    # PDF -> CUPSラスタ は macOS 標準の cgpdftoraster が行う(Ghostscript 不要)
    w(f'*cupsFilter: "application/vnd.cups-raster 0 {FILTER}"')
    w('')
    # 黒リボンでもフィルタが RGB からディザするので、ラスタは常に RGB 8bit
    w('*OpenUI *ColorModel/カラーモード: PickOne')
    w('*DefaultColorModel: RGB')
    w('*ColorModel RGB/カラー: '
      '"<</cupsColorSpace 1/cupsBitsPerColor 8/cupsBitsPerPixel 24>>setpagedevice"')
    w('*CloseUI: *ColorModel')
    w('')
    # 本体に装着したリボンと合わせる。違うとカードが詰まる
    w('*OpenUI *EvolisRibbon/リボン: PickOne')
    w('*OrderDependency: 10 AnySetup *EvolisRibbon')
    w('*DefaultEvolisRibbon: k')
    for v, label in RIBBONS:
        w(f'*EvolisRibbon {v}/{label}: ""')
    w('*CloseUI: *EvolisRibbon')
    w('')
    # オーバーレイ(保護層)を乗せる範囲。オーバーレイのあるリボン(YMCKO、KO)だけで使う
    w('*OpenUI *EvolisOverlay/オーバーレイ (保護層): PickOne')
    w('*OrderDependency: 12 AnySetup *EvolisOverlay')
    w('*DefaultEvolisOverlay: full')
    w('*EvolisOverlay full/全面: ""')
    w('*EvolisOverlay none/なし: ""')
    w('*EvolisOverlay chipiso/IC チップを避ける (ISO 7816): ""')
    w('*EvolisOverlay magstripe/磁気ストライプを避ける (ISO 7811、裏面用): ""')
    w('*CloseUI: *EvolisOverlay')
    w('')
    # 黒パネルの処理(黒・単色リボンと、ハーフパネルの右側)。公式ドライバの Gray / Line Mode に当たる
    w('*OpenUI *EvolisKMode/黒パネルの処理: PickOne')
    w('*OrderDependency: 13 AnySetup *EvolisKMode')
    w('*DefaultEvolisKMode: gray')
    w('*EvolisKMode gray/グレー (網点で濃淡を出す): ""')
    w('*EvolisKMode line/線画 (黒か白かに分ける): ""')
    w('*CloseUI: *EvolisKMode')
    w('')
    # コントラスト (Pc)。本体は 0..20、工場出荷時 10。黒の網点の補正は 10 で測ったもの
    for key, label, order in (("EvolisContrastK", "黒 / 単色リボンの濃さ", 20),
                              ("EvolisContrastColor", "カラーの濃さ (カラーリボン)", 30),
                              ("EvolisBrightness", "カラーの明るさ (カラーリボン、大きいほど明るい)", 31),
                              ("EvolisContrastOverlay", "オーバーレイの濃さ", 32)):
        w(f'*OpenUI *{key}/{label}: PickOne')
        w(f'*OrderDependency: {order} AnySetup *{key}')
        w(f'*Default{key}: 10')
        for v in range(0, 21, 2):
            note = " (標準)" if v == 10 else " (薄い)" if v == 0 else " (濃い)" if v == 20 else ""
            w(f'*{key} {v}/{v}{note}: ""')
        w(f'*CloseUI: *{key}')
    w('')
    w('*OpenUI *Resolution/解像度: PickOne')
    w('*DefaultResolution: 300dpi')
    w('*Resolution 300dpi/300 dpi: "<</HWResolution[300 300]>>setpagedevice"')
    w('*CloseUI: *Resolution')
    w('')
    for key in ("PageSize", "PageRegion"):
        w(f'*OpenUI *{key}/用紙サイズ: PickOne')
        w(f'*Default{key}: CR80')
        w(f'*{key} CR80/カード CR80 (85.6 x 54 mm): "<</PageSize[{W:g} {H:g}]>>setpagedevice"')
        w(f'*CloseUI: *{key}')
        w('')
    # カード全面に印刷する(縁なし)
    w('*DefaultImageableArea: CR80')
    w(f'*ImageableArea CR80/カード CR80 (85.6 x 54 mm): "0 0 {W:g} {H:g}"')
    w('*DefaultPaperDimension: CR80')
    w(f'*PaperDimension CR80/カード CR80 (85.6 x 54 mm): "{W:g} {H:g}"')
    w('*HWMargins: 0 0 0 0')
    sys.stdout.buffer.write(("\n".join(p) + "\n").encode("shift_jis"))


if __name__ == "__main__":
    main()
