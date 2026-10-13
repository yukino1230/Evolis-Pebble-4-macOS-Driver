#!/usr/bin/env python3
"""Draw a 1016x648 orientation test card: border, corner marker, text."""
import sys

from PIL import Image, ImageDraw, ImageFont

img = Image.new("L", (1016, 648), 255)
d = ImageDraw.Draw(img)
d.rectangle([20, 20, 995, 627], outline=0, width=6)
d.rectangle([40, 40, 160, 160], fill=0)  # top-left marker
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 80)
small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 40)
d.text((200, 60), "TOP-LEFT", font=small, fill=0)
d.text((508, 324), "Pebble 4 / macOS", font=font, fill=0, anchor="mm")
d.text((975, 600), "bottom-right", font=small, fill=0, anchor="rs")
img.save(sys.argv[1] if len(sys.argv) > 1 else "testcard.png")
