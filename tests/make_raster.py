#!/usr/bin/env python3
"""テスト用の CUPS ラスタ(PWG ラスタ)を作る。印刷ダイアログを通さずに、フィルタの入力を毎回同じにするため。

  python3 tests/make_raster.py <種類> <出力>

種類:
  color       カード大(1011x638)、24bit RGB。色のグラデーション、グレーの段階、黒の文字代わりの帯
  portrait    同じ絵を縦長(638x1011)で
  gray        8bit グレー(sW)
  mono        1bit 黒(K)
  rle         color と同じ絵を v2 (RLE 圧縮) で
  blank2      1 ページ目が真っ白、2 ページ目が color
  a4          A4 (2480x3508) の 8bit。用紙サイズの間違いで止まるか
  urf         color と同じ絵を Apple ラスタ (URF、AirPrint の形式) で
  urfgray     gray と同じ絵を Apple ラスタで。行の右端の白は「残りを白で埋める」で書く
"""
import struct
import sys

W, H = 1011, 638


def header(w, h, bpp, cspace, ncolors):
    hdr = bytearray(1796)
    hdr[0:64] = b"PwgRaster".ljust(64, b"\0")
    stride = (w * bpp + 7) // 8

    def put(off, v):
        hdr[off:off + 4] = struct.pack(">I", v)
    put(276, 300)                      # HWResolution
    put(280, 300)
    put(352, round(w * 72 / 300))      # PageSize (pt)
    put(356, round(h * 72 / 300))
    put(372, w)                        # cupsWidth
    put(376, h)                        # cupsHeight
    put(384, 1 if bpp == 1 else 8)     # cupsBitsPerColor
    put(388, bpp)                      # cupsBitsPerPixel
    put(392, stride)                   # cupsBytesPerLine
    put(396, 0)                        # cupsColorOrder (chunky)
    put(400, cspace)                   # cupsColorSpace
    put(420, ncolors)                  # cupsNumColors
    return bytes(hdr), stride


def pixel(x, y):
    """カード上の (x, y) の RGB。上: 色相のグラデーション、中: グレー 11 段、下: 黒い帯と色のパッチ"""
    if y < 200:
        t = x / (W - 1)
        seg, f = int(t * 6) % 6, (t * 6) % 1
        v = [255, round(255 * f), 0] if seg == 0 else \
            [round(255 * (1 - f)), 255, 0] if seg == 1 else \
            [0, 255, round(255 * f)] if seg == 2 else \
            [0, round(255 * (1 - f)), 255] if seg == 3 else \
            [round(255 * f), 0, 255] if seg == 4 else [255, 0, round(255 * (1 - f))]
        light = y / 200                                    # 下へ行くほど白に寄せる
        return [round(c + (255 - c) * light * 0.6) for c in v]
    if y < 400:
        g = 255 - (x * 11 // W) * 255 // 10
        return [g, g, g]
    if y < 460:
        return [0, 0, 0] if (x // 40) % 2 == 0 else [255, 255, 255]
    patches = [[255, 0, 0], [0, 160, 0], [0, 0, 255], [20, 20, 20], [128, 64, 32], [255, 255, 255]]
    return patches[x * len(patches) // W]


def rgb_image(w, h, rotate=False):
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            # 縦長は、横長の絵を反時計回りに 90° 回したもの(フィルタが時計回りに戻す)
            px = pixel(W - 1 - y, x) if rotate else pixel(x, y)
            row += bytes(px)
        rows.append(bytes(row))
    return rows


def gray_rows(rows):
    return [bytes((299 * r[i] + 587 * r[i + 1] + 114 * r[i + 2] + 500) // 1000 for i in range(0, len(r), 3))
            for r in rows]


def mono_rows(gray, w):
    out = []
    for y, r in enumerate(gray):
        b = bytearray((w + 7) // 8)
        for x, v in enumerate(r):
            # 4x4 の組織的ディザで 1bit にする(K: 1 = 黒)
            t = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))[y % 4][x % 4]
            if v * 16 // 256 <= t:
                b[x >> 3] |= 0x80 >> (x & 7)
        out.append(bytes(b))
    return out


def rle(rows, px, apple=False):
    """CUPS ラスタ v2 の圧縮: 行ごとに「繰り返し数 - 1」、続けて同じ画素の繰り返しか、そのままの画素の並び。
    apple なら、行の右端に続く白を 128(残りを白で埋める)で書く"""
    out = bytearray()
    for r in rows:
        out.append(0)
        pixels = [r[i:i + px] for i in range(0, len(r), px)]
        end = len(pixels)
        if apple:
            while end > 0 and pixels[end - 1] == b"\xff" * px:
                end -= 1
        i = 0
        while i < end:
            j = i + 1
            while j < end and j - i < 128 and pixels[j] == pixels[i]:
                j += 1
            if j - i > 1:
                out.append(j - i - 1)
                out += pixels[i]
                i = j
            else:
                j = i + 1
                while j < end and j - i < 128 and (j + 1 >= end or pixels[j] != pixels[j + 1]):
                    j += 1
                out.append(0 if j - i == 1 else 257 - (j - i))   # 1 画素だけなら「1 回繰り返し」で書く
                for p in pixels[i:j]:
                    out += p
                i = j
        if end < len(pixels):
            out.append(128)
    return bytes(out)


def page(rows, w, h, bpp, cspace, ncolors, compress=False):
    hdr, stride = header(w, h, bpp, cspace, ncolors)
    data = rle(rows, max(1, bpp // 8)) if compress else b"".join(rows)
    return hdr + data


def urf(pages):
    """Apple ラスタ: "UNIRAST\\0" + ページ数、ページごとに 32 バイトのヘッダと圧縮した画素"""
    out = bytearray(b"UNIRAST\0" + struct.pack(">I", len(pages)))
    for rows, w, h, bpp in pages:
        hdr = bytearray(32)
        hdr[0] = bpp
        hdr[1] = 1 if bpp == 24 else 0           # sRGB / sGray
        hdr[12:24] = struct.pack(">III", w, h, 300)
        out += hdr + rle(rows, bpp // 8, apple=True)
    return bytes(out)


def main():
    kind, out = sys.argv[1], sys.argv[2]
    magic = b"RaS3"
    if kind == "color":
        pages = [page(rgb_image(W, H), W, H, 24, 1, 3)]
    elif kind == "portrait":
        pages = [page(rgb_image(H, W, rotate=True), H, W, 24, 1, 3)]
    elif kind == "gray":
        pages = [page(gray_rows(rgb_image(W, H)), W, H, 8, 18, 1)]
    elif kind == "mono":
        pages = [page(mono_rows(gray_rows(rgb_image(W, H)), W), W, H, 1, 3, 1)]
    elif kind == "rle":
        magic = b"RaS2"
        pages = [page(rgb_image(W, H), W, H, 24, 1, 3, compress=True)]
    elif kind == "blank2":
        white = [b"\xff" * (W * 3)] * H
        pages = [page(white, W, H, 24, 1, 3), page(rgb_image(W, H), W, H, 24, 1, 3)]
    elif kind == "urf":
        open(out, "wb").write(urf([(rgb_image(W, H), W, H, 24)]))
        return
    elif kind == "urfgray":
        open(out, "wb").write(urf([(gray_rows(rgb_image(W, H)), W, H, 8)]))
        return
    elif kind == "a4":
        pages = [page([b"\x80" * 2480] * 3508, 2480, 3508, 8, 18, 1)]
    else:
        sys.exit(f"unknown kind: {kind}")
    with open(out, "wb") as f:
        f.write(magic + b"".join(pages))


if __name__ == "__main__":
    main()
