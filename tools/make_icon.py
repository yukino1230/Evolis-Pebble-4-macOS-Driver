#!/usr/bin/env python3
"""Evolis Utility のアイコンを描く(カードプリンタからカードが出てくる絵)。

  python3 tools/make_icon.py app/Resources/AppIcon.icns
  python3 tools/make_icon.py icon.png        # 確かめる用
  python3 tools/make_icon.py --printer printer-app/printer-icon.png
                                             # プリンタのアイコン(歯車なし、512 px)。Printer Application が使う

Evolis のロゴは使わない(商標)。1024 px で描いて、iconutil で .icns にまとめる。
"""
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

N = 1024
SS = 4                      # 4 倍で描いて縮め、縁を滑らかにする


def s(*v):
    return [round(x * SS) for x in v]


def draw(with_gear=True):
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

    # 出てくるカード(CR80 の縦横比 85.6:54)
    cx0, cy0, cw = 322, 238, 380
    ch = round(cw * 54 / 85.6)
    card = (cx0, cy0, cx0 + cw, cy0 + ch)
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(s(card[0] + 6, card[1] + 14, card[2] + 6, card[3] + 14),
                                             radius=26 * SS, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * SS)))
    d.rounded_rectangle(s(*card), radius=26 * SS, fill=(255, 255, 255, 255))
    # 顔写真の枠と人の形
    px0, py0 = cx0 + 34, cy0 + 40
    d.rounded_rectangle(s(px0, py0, px0 + 96, py0 + 118), radius=12 * SS, fill=(214, 228, 245, 255))
    d.ellipse(s(px0 + 28, py0 + 20, px0 + 68, py0 + 60), fill=(60, 110, 190, 255))
    d.pieslice(s(px0 + 12, py0 + 66, px0 + 84, py0 + 150), 180, 360, fill=(60, 110, 190, 255))
    # 文字の行
    for i, w in enumerate((190, 150, 170)):
        y = py0 + 12 + i * 34
        d.rounded_rectangle(s(px0 + 124, y, px0 + 124 + w, y + 16), radius=8 * SS, fill=(200, 208, 220, 255))
    # 上の帯(YMCK の色)
    band = [(250, 204, 21), (236, 72, 153), (14, 165, 233), (40, 40, 48)]
    bw = (cw - 68) / 4
    for i, c in enumerate(band):
        x = cx0 + 34 + i * bw
        d.rectangle(s(x, cy0 + 16, x + bw, cy0 + 26), fill=c + (255,))

    # プリンタ本体(カードの下半分を隠す)
    body = (214, 468, 810, 780)
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(s(body[0], body[1] + 24, body[2], body[3] + 24),
                                             radius=70 * SS, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22 * SS)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(s(*body), radius=70 * SS, fill=(244, 246, 250, 255))
    # 上面の明るい帯と、カードの出口
    d.rounded_rectangle(s(body[0], body[1], body[2], body[1] + 70), radius=70 * SS, fill=(255, 255, 255, 255))
    d.rectangle(s(body[0], body[1] + 40, body[2], body[1] + 70), fill=(255, 255, 255, 255))
    d.rounded_rectangle(s(cx0 - 22, body[1] - 10, cx0 + cw + 22, body[1] + 14), radius=12 * SS,
                        fill=(52, 60, 76, 255))
    # 前面のパネルと状態のランプ
    d.rounded_rectangle(s(body[0] + 56, body[1] + 120, body[2] - 56, body[1] + 140), radius=10 * SS,
                        fill=(214, 220, 230, 255))
    # 状態のランプ。歯車を付けるときは歯車に隠れないよう左に寄せる
    lamp = body[0] + 290 if with_gear else body[2] - 128
    d.ellipse(s(lamp, body[3] - 104, lamp + 36, body[3] - 68), fill=(34, 197, 94, 255))
    d.rounded_rectangle(s(body[0] + 64, body[3] - 96, body[0] + 260, body[3] - 76), radius=10 * SS,
                        fill=(214, 220, 230, 255))

    # 右下に歯車(設定や状態を見るアプリだとわかるように)。プリンタのアイコンには付けない
    if with_gear:
        gear(img, 716, 716, 150)

    return img.resize((N, N), Image.LANCZOS)


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
    icon = draw(with_gear=not printer)
    if printer:
        icon.resize((512, 512), Image.LANCZOS).save(out, optimize=True)
        print(out)
        return
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
