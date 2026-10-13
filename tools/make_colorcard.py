#!/usr/bin/env python3
"""Draw a 1016x648 color test card: primaries, gradients, black text."""
import colorsys
import sys

from PIL import Image, ImageDraw, ImageFont

img = Image.new("RGB", (1016, 648), "white")
d = ImageDraw.Draw(img)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 40)
small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)

d.rectangle([40, 40, 160, 160], fill="black")                    # top-left marker
d.text((190, 60), "TOP-LEFT  YMCKO", font=font, fill="black")

patches = [("C", (0, 255, 255)), ("M", (255, 0, 255)), ("Y", (255, 255, 0)),
           ("R", (255, 0, 0)), ("G", (0, 255, 0)), ("B", (0, 0, 255))]
for i, (name, rgb) in enumerate(patches):
    x = 40 + i * 156
    d.rectangle([x, 190, x + 140, 330], fill=rgb)
    d.text((x + 70, 345), name, font=small, fill="black", anchor="mt")

for x in range(40, 976):                                          # hue sweep
    r, g, b = colorsys.hsv_to_rgb((x - 40) / 936, 1, 1)
    d.line([x, 400, x, 470], fill=(int(r * 255), int(g * 255), int(b * 255)))
for x in range(40, 976):                                          # gray ramp (CMY only)
    v = int(255 * (x - 40) / 935)
    d.line([x, 490, x, 560], fill=(v, v, v))

d.text((975, 610), "bottom-right", font=small, fill="black", anchor="rs")
img.save(sys.argv[1] if len(sys.argv) > 1 else "colorcard.png")
