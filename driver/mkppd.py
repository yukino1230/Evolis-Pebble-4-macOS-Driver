#!/usr/bin/env python3
"""Evolis Pebble 4（片面）用の PPD を生成する。

表示は英語が基本で、日本語の訳を *cupsLanguages / *ja. で同じファイルに入れる。
macOS は言語設定に合わせて切り替える。訳の文字列は UTF-8（CUPS の決まり）、
英語の部分は ASCII だけにしているので、ファイル全体を UTF-8 で書き出す。
"""
import os
import sys

MM = 72 / 25.4
W, H = round(85.6 * MM, 2), round(54.0 * MM, 2)   # CR80 (ISO/IEC 7810 ID-1)、横長
FILTER = "/usr/local/libexec/cups/filter/rastertoevolis"

# Pr に送る値と表示名 (英語, 日本語)。driver/rastertoevolis.c の RIBBONS と合わせる
RIBBONS = [
    ("k", "Black (monochrome)", "黒 (モノクロ)"),
    ("ymcko", "YMCKO color (full panel)", "YMCKO カラー (全面パネル)"),
    ("ymckos", "YMCKO color (half panel, e.g. R3013)", "YMCKO カラー (ハーフパネル R3013 など)"),
    ("ko", "Black + overlay (KO)", "黒 + オーバーレイ (KO)"),
    ("kw", "White (monochrome)", "白 (モノクロ)"),
    ("kr", "Red (monochrome)", "赤 (モノクロ)"),
    ("kbl", "Blue (monochrome)", "青 (モノクロ)"),
    ("kgr", "Green (monochrome)", "緑 (モノクロ)"),
    ("kgo", "Gold (monochrome)", "金 (モノクロ)"),
    ("ksi", "Silver (monochrome)", "銀 (モノクロ)"),
    ("ksc", "Scratch-off (monochrome)", "スクラッチ (モノクロ)"),
    ("ka", "Black wax (monochrome)", "黒ワックス (モノクロ)"),
]
OVERLAYS = [
    ("full", "Full card", "全面"),
    ("none", "None", "なし"),
    ("chipiso", "Avoid IC chip (ISO 7816)", "IC チップを避ける (ISO 7816)"),
    ("magstripe", "Avoid magnetic stripe (ISO 7811, back side)", "磁気ストライプを避ける (ISO 7811、裏面用)"),
]
KMODES = [
    ("gray", "Gray (halftone)", "グレー (網点で濃淡を出す)"),
    ("line", "Line art (black or white)", "線画 (黒か白かに分ける)"),
]
# (キー, 英語, 日本語, 順番, 0 の注記, 20 の注記)。本体は 0..20、工場出荷時 10
LEVELS = [
    ("EvolisContrastK", "Black / monochrome ribbon density", "黒 / 単色リボンの濃さ", 20,
     ("lighter", "薄い"), ("darker", "濃い")),
    ("EvolisContrastColor", "Color density (color ribbons)", "カラーの濃さ (カラーリボン)", 30,
     ("lighter", "薄い"), ("darker", "濃い")),
    ("EvolisBrightness", "Color brightness (color ribbons, higher = lighter)",
     "カラーの明るさ (カラーリボン、大きいほど明るい)", 31,
     ("darker", "暗い"), ("lighter", "明るい")),
    ("EvolisContrastOverlay", "Overlay density", "オーバーレイの濃さ", 32,
     ("lighter", "薄い"), ("darker", "濃い")),
]
CARD = ("CR80 card (85.6 x 54 mm)", "カード CR80 (85.6 x 54 mm)")


def main():
    p = []
    def w(s): p.append(s)

    def ui(key, en, ja, order, default, choices):
        """choices: [(値, 英語, 日本語, PostScript)]"""
        w(f'*OpenUI *{key}/{en}: PickOne')
        if order is not None:
            w(f'*OrderDependency: {order} AnySetup *{key}')
        w(f'*Default{key}: {default}')
        for v, cen, _, ps in choices:
            w(f'*{key} {v}/{cen}: "{ps}"')
        w(f'*CloseUI: *{key}')
        w(f'*ja.Translation {key}/{ja}: ""')
        for v, _, cja, _ in choices:
            w(f'*ja.{key} {v}/{cja}: ""')
        w('')

    w('*PPD-Adobe: "4.3"')
    w('*FormatVersion: "4.3"')
    # 「設定」>「プリンタとスキャナ」の「ドライバのバージョン」に出る。build-pkg.sh が pkg の版を渡す
    w(f'*FileVersion: "{os.environ.get("EVOLIS_VERSION", "1.2")}"')
    w('*LanguageEncoding: ISOLatin1')
    w('*LanguageVersion: English')
    w('*cupsLanguages: "ja"')
    w('*Manufacturer: "Evolis"')
    w('*ModelName: "Evolis Pebble 4"')
    w('*ShortNickName: "Evolis Pebble 4"')
    w('*NickName: "Evolis Pebble 4"')
    w('*PCFileName: "PEBBLE4.PPD"')
    w('*Product: "(Pebble 4)"')
    w('*1284DeviceID: "MFG:EVOLIS;MDL:Pebble;"')
    # 「プリンタユーティリティを開く」で起動するアプリ(今の macOS には入口が無い)
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
    ui("ColorModel", "Color Mode", "カラーモード", None, "RGB",
       [("RGB", "Color", "カラー", "<</cupsColorSpace 1/cupsBitsPerColor 8/cupsBitsPerPixel 24>>setpagedevice")])
    # 本体に装着したリボンと合わせる。違うとカードが詰まったりリボンが切れたりする
    ui("EvolisRibbon", "Ribbon", "リボン", 10, "k", [(v, en, ja, "") for v, en, ja in RIBBONS])
    # オーバーレイ(保護層)を乗せる範囲。オーバーレイのあるリボン(YMCKO、KO)だけで使う
    ui("EvolisOverlay", "Overlay (protective layer)", "オーバーレイ (保護層)", 12, "full",
       [(v, en, ja, "") for v, en, ja in OVERLAYS])
    # 黒パネルの処理(黒・単色リボンと、ハーフパネルの右側)。公式ドライバの Gray / Line Mode に当たる
    ui("EvolisKMode", "Black panel rendering", "黒パネルの処理", 13, "gray",
       [(v, en, ja, "") for v, en, ja in KMODES])
    # コントラスト (Pc) と明るさ (Pl)。黒の網点の補正は 10 で測ったもの
    for key, en, ja, order, low, high in LEVELS:
        choices = []
        for v in range(0, 21, 2):
            note = ("standard", "標準") if v == 10 else low if v == 0 else high if v == 20 else None
            choices.append((str(v), f"{v} ({note[0]})" if note else str(v),
                            f"{v} ({note[1]})" if note else str(v), ""))
        ui(key, en, ja, order, "10", choices)
    ui("Resolution", "Resolution", "解像度", None, "300dpi",
       [("300dpi", "300 dpi", "300 dpi", "<</HWResolution[300 300]>>setpagedevice")])
    for key in ("PageSize", "PageRegion"):
        ui(key, "Media Size", "用紙サイズ", None, "CR80",
           [("CR80", CARD[0], CARD[1], f"<</PageSize[{W:g} {H:g}]>>setpagedevice")])
    # カード全面に印刷する(縁なし)
    w('*DefaultImageableArea: CR80')
    w(f'*ImageableArea CR80/{CARD[0]}: "0 0 {W:g} {H:g}"')
    w('*DefaultPaperDimension: CR80')
    w(f'*PaperDimension CR80/{CARD[0]}: "{W:g} {H:g}"')
    w('*HWMargins: 0 0 0 0')
    sys.stdout.buffer.write(("\n".join(p) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
