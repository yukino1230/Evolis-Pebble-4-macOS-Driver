#!/usr/bin/env python3
"""Evolis Pebble 4（黒リボン・片面）用の PPD を生成する。

出力は Shift-JIS（PPD 仕様で UTF-8 は使えないため）。
"""
import sys

MM = 72 / 25.4
W, H = round(85.6 * MM, 2), round(54.0 * MM, 2)   # CR80 (ISO/IEC 7810 ID-1)、横長
FILTER = "/usr/local/libexec/cups/filter/rastertoevolis"


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
    w('*NickName: "Evolis Pebble 4 (black ribbon)"')
    w('*PCFileName: "PEBBLE4.PPD"')
    w('*Product: "(Pebble 4)"')
    w('*1284DeviceID: "MFG:EVOLIS;MDL:Pebble;"')
    w('*PSVersion: "(3010.000) 0"')
    w('*LanguageLevel: "3"')
    w('*ColorDevice: False')
    w('*DefaultColorSpace: Gray')
    w('*FileSystem: False')
    w('*Throughput: "1"')
    w('*cupsVersion: 2.3')
    w('*cupsModelNumber: 0')
    w('*cupsManualCopies: True')
    # PDF -> CUPSラスタ は macOS 標準の cgpdftoraster が行う(Ghostscript 不要)
    w(f'*cupsFilter: "application/vnd.cups-raster 0 {FILTER}"')
    w('')
    w('*OpenUI *ColorModel/カラーモード: PickOne')
    w('*DefaultColorModel: Gray1')
    w('*ColorModel Gray1/白黒: '
      '"<</cupsColorSpace 3/cupsBitsPerColor 1/cupsBitsPerPixel 1>>setpagedevice"')
    w('*CloseUI: *ColorModel')
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
