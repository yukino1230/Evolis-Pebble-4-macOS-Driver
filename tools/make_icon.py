#!/usr/bin/env python3
"""Evolis Utility のアイコンを描く(カードプリンタからカードが出てくる絵)。

  python3 tools/make_icon.py app/Resources/AppIcon.icns
  python3 tools/make_icon.py icon.png        # 確かめる用
  python3 tools/make_icon.py --printer printer-app/printer-icon.png
                                             # プリンタのアイコン(Pebble 4 をデフォルメした絵、512 px)。Printer Application が使う

Evolis のロゴは使わない(商標)。1024 px で描いて、iconutil で .icns にまとめる。
"""
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

N = 1024
SS = 4                      # 4 倍で描いて縮め、縁を滑らかにする


def s(*v):
    return [round(x * SS) for x in v]


def draw():
    big = N * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    # 背景: macOS のアイコンの枠(824 px 角、角丸)に青のグラデーション
    grad = Image.new("RGBA", (big, big))
    gd = ImageDraw.Draw(grad)
    top, bottom = (74, 144, 226), (28, 64, 140)
    for y in range(big):
        t = y / big
        gd.line([(0, y), (big, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(s(100, 100, 924, 924), radius=185 * SS, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)

    # プリンタ(Pebble 4 をデフォルメした絵。プリンタのアイコンと同じ)を枠の中に置く
    printer = draw_printer(hires=True)
    size = 640 * SS
    img.alpha_composite(printer.resize((size, size), Image.LANCZOS), (round(150 * SS), round(165 * SS)))

    # 右下に歯車(設定や状態を見るアプリだとわかるように)
    gear(img, 716, 716, 150)

    return img.resize((N, N), Image.LANCZOS)


def draw_printer(hires=False):
    """プリンタのアイコン: Pebble 4 を横から見た形をデフォルメした絵(背景なし)。
    白い本体は前が低く、後ろへ盛り上がってから丸く下りる(かまぼこ形)。上を透明な緑のカバーが覆い、
    後ろの上にカードフィーダー、前の口からカードが出てくる。ロゴは描かない"""
    big = N * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    X0, X1, PEAK, BOTTOM, TOP = 170, 900, 640, 840, 330

    def top(x):
        """本体の上の輪郭の高さ(y)"""
        if x <= PEAK:
            u = (PEAK - x) / (PEAK - 130)
            return BOTTOM - (BOTTOM - TOP) * max(0.0, 1 - u * u) ** 0.5
        u = (x - PEAK) / (X1 - PEAK)
        return BOTTOM - (BOTTOM - TOP) * max(0.0, 1 - u ** 2.2) ** (1 / 2.2)

    xs = [X0 + (X1 - X0) * i / 400 for i in range(401)]
    outline = [(x, top(x)) for x in xs] + [(X1, BOTTOM), (X0, BOTTOM)]

    def poly_mask(points):
        m = Image.new("L", (big, big), 0)
        ImageDraw.Draw(m).polygon([(round(x * SS), round(y * SS)) for x, y in points], fill=255)
        return m

    body = poly_mask(outline)
    # 前の下の角を丸める
    corner = Image.new("L", (big, big), 255)
    cd = ImageDraw.Draw(corner)
    cd.rectangle(s(X0, BOTTOM - 40, X0 + 40, BOTTOM), fill=0)
    cd.pieslice(s(X0, BOTTOM - 80, X0 + 80, BOTTOM), 90, 180, fill=255)
    body = ImageChops.multiply(body, corner)

    # 影
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(s(180, 805, 900, 885), fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * SS)))

    # カードフィーダー(後ろの上、透明な緑の箱。中にカードの束)。下は本体に隠れる
    feeder = (540, 170, 770, 420)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(s(*feeder), radius=26 * SS, fill=(40, 150, 60, 255))
    d.rounded_rectangle(s(feeder[0] + 12, feeder[1] + 12, feeder[2] - 12, feeder[1] + 28), radius=8 * SS,
                        fill=(120, 205, 130, 255))
    for i in range(5):
        y = feeder[1] + 46 + i * 22
        d.rounded_rectangle(s(feeder[0] + 32, y, feeder[2] - 32, y + 12), radius=6 * SS, fill=(225, 245, 228, 255))

    # 縁取り(白い背景でも形がわかるように)と、白い本体
    img.paste((150, 158, 172, 255), (0, 0), body.filter(ImageFilter.MaxFilter(9)))
    base = Image.new("RGBA", (big, big))
    gd = ImageDraw.Draw(base)
    for y in range(big):
        c = round(250 - 36 * max(0.0, y / big - 0.5))
        gd.line([(0, y), (big, y)], fill=(c, c, min(255, c + 4), 255))
    img.paste(base, (0, 0), body)

    # 緑のカバー: 上の輪郭に沿った帯。前の方を厚くする(実物も排出口の上までカバーが下りている)
    def thick(x):
        t = (x - X0) / (X1 - X0)
        return 175 - 45 * t
    cx0, cx1 = X0 + 10, X1 - 60
    band = [(x, top(x) - 6) for x in xs if cx0 <= x <= cx1]
    band += [(x, top(x) + thick(x)) for x in reversed(xs) if cx0 <= x <= cx1]
    cover = ImageChops.multiply(poly_mask(band), body)
    green = Image.new("RGBA", (big, big))
    gd = ImageDraw.Draw(green)
    for y in range(big):
        t = y / big
        gd.line([(0, y), (big, y)], fill=(round(80 - 40 * t), round(200 - 60 * t), round(90 - 40 * t), 255))
    img.paste(green, (0, 0), cover)
    # カバーのつや(輪郭に沿った明るい線)
    gloss = [(x, top(x) + 24) for x in xs if 290 <= x <= 700]
    d = ImageDraw.Draw(img)
    d.line([(round(x * SS), round(y * SS)) for x, y in gloss], fill=(185, 240, 190, 255), width=14 * SS, joint="curve")

    # 横の操作パネル: カバーのすぐ下にランプ 4 つとボタン
    for i, x in enumerate((420, 460, 500, 540)):
        y = top(x) + thick(x) + 26
        d.ellipse(s(x - 9, y - 9, x + 9, y + 9), fill=(150, 158, 172, 255))
    bx = 370
    by = top(bx) + thick(bx) + 34
    d.ellipse(s(bx - 20, by - 20, bx + 20, by + 20), fill=(175, 182, 196, 255))

    # 前の口(カードが出てくるところ)と、出てくるカード(少し傾ける)
    d.rounded_rectangle(s(X0 - 6, 742, X0 + 70, 800), radius=22 * SS, fill=(55, 62, 76, 255))
    card = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    kx, ky, kw, kh = 40, 640, 200, 126
    cd.rounded_rectangle(s(kx, ky, kx + kw, ky + kh), radius=16 * SS, fill=(255, 255, 255, 255),
                         outline=(150, 158, 172, 255), width=4 * SS)
    cd.rectangle(s(kx + 14, ky + 14, kx + kw - 14, ky + 28), fill=(60, 110, 190, 255))
    cd.rounded_rectangle(s(kx + 16, ky + 40, kx + 64, ky + 108), radius=7 * SS, fill=(214, 228, 245, 255))
    cd.ellipse(s(kx + 30, ky + 50, kx + 50, ky + 70), fill=(60, 110, 190, 255))
    cd.pieslice(s(kx + 22, ky + 76, kx + 58, ky + 124), 180, 360, fill=(60, 110, 190, 255))
    for i, w in enumerate((96, 72, 84)):
        y = ky + 46 + i * 21
        cd.rounded_rectangle(s(kx + 78, y, kx + 78 + w, y + 10), radius=5 * SS, fill=(200, 208, 220, 255))
    card = card.rotate(-14, resample=Image.BICUBIC, center=(round((kx + kw) * SS), round((ky + kh) * SS)))
    img.alpha_composite(card)

    # 絵が枠いっぱいになるよう、まわりの余白を詰めて正方形の真ん中に置く(小さく出したときも見えるように)
    x0, y0, x1, y1 = img.getbbox()
    side = round(max(x1 - x0, y1 - y0) * 1.04)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(img.crop((x0, y0, x1, y1)), ((side - (x1 - x0)) // 2, (side - (y1 - y0)) // 2))
    return square if hires else square.resize((N, N), Image.LANCZOS)


def gear(img, cx, cy, r, teeth=8):
    """縁取りと影の付いた歯車を (cx, cy) に描く"""
    def outline(rad):
        pts = []
        for i in range(teeth * 4):
            a = 2 * math.pi * i / (teeth * 4) - math.pi / 2
            rr = rad if i % 4 in (0, 1) else rad * 0.78       # 歯の先 / 歯の根元
            pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        return [round(v * SS) for p in pts for v in p]

    big = img.size[0]
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.polygon(outline(r), fill=(0, 0, 0, 120))
    sd.line(outline(r) + outline(r)[:2], fill=(0, 0, 0, 120), width=28 * SS, joint="curve")
    img.alpha_composite(shadow.transform((big, big), Image.AFFINE, (1, 0, 0, 0, 1, -16 * SS))
                        .filter(ImageFilter.GaussianBlur(16 * SS)))
    d = ImageDraw.Draw(img)
    # 白い縁: 輪郭に太い線を引く(線の半分が外にはみ出す)
    d.polygon(outline(r), fill=(255, 255, 255, 255))
    d.line(outline(r) + outline(r)[:2], fill=(255, 255, 255, 255), width=28 * SS, joint="curve")
    # 本体は上から下へ明るいグレーから暗いグレー
    body = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(outline(r), fill=255)
    gd = ImageDraw.Draw(body)
    for y in range(round((cy - r) * SS), round((cy + r) * SS) + 1):
        t = (y / SS - (cy - r)) / (2 * r)
        c = tuple(round(a + (b - a) * t) for a, b in zip((120, 130, 146), (62, 70, 86)))
        gd.line([(0, y), (big, y)], fill=c + (255,))
    img.paste(body, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.ellipse(s(cx - r * 0.42, cy - r * 0.42, cx + r * 0.42, cy + r * 0.42), fill=(255, 255, 255, 255))
    d.ellipse(s(cx - r * 0.30, cy - r * 0.30, cx + r * 0.30, cy + r * 0.30), fill=(40, 46, 58, 255))


def main():
    args = sys.argv[1:]
    printer = "--printer" in args
    args = [a for a in args if a != "--printer"]
    out = args[0] if args else "AppIcon.icns"
    if printer:
        draw_printer().resize((512, 512), Image.LANCZOS).save(out, optimize=True)
        print(out)
        return
    icon = draw()
    if out.endswith(".png"):                  # 確かめる用に PNG でも出せる
        icon.save(out)
        print(out)
        return
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", "-o", out, iconset], check=True)
    print(out)


if __name__ == "__main__":
    main()
