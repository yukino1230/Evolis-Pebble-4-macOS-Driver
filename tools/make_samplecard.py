#!/usr/bin/env python3
"""Draw a CR80 sample ID card as a vector PDF for checking the CUPS driver.

Left part (inside the half-panel color area): a portrait illustration,
a hue strip and a gray step wedge. Right part: black text and colored
headings/logo, which a half-panel ribbon prints as black halftone.
Bottom: a ruler in card dots around the half-panel boundary over a
full-width rainbow, to see where color stops and halftone starts.
"""
import colorsys
import sys

from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas

W, H = 85.6 * mm, 54.0 * mm
DOT = 72 / 300                   # 1 dot at 300 dpi, in points
OX = 2                           # the filter centers 1011 raster dots in the 1016-dot head
HALF_W = 430                     # driver/evolis_card.c


def dot_x(d):
    """Card dot (as the printer counts it) -> x in points."""
    return (d - OX) * DOT


pdfmetrics.registerFont(UnicodeCIDFont("HeiseiKakuGo-W5"))
JP = "HeiseiKakuGo-W5"

c = canvas.Canvas(sys.argv[1] if len(sys.argv) > 1 else "sample-card.pdf", pagesize=(W, H))
c.setTitle("Evolis Pebble 4 sample card")

# --- left: portrait illustration (color) ---
px, py, pw, ph = 4 * mm, 17 * mm, 25 * mm, 32 * mm
steps = 60
for i in range(steps):                                   # sky gradient
    t = i / (steps - 1)
    c.setFillColorRGB(0.55 + 0.35 * t, 0.75 + 0.2 * t, 0.95)
    c.rect(px, py + ph * i / steps, pw, ph / steps + 0.3, stroke=0, fill=1)
c.setFillColorRGB(0.2, 0.35, 0.65)                       # shoulders
c.ellipse(px + 2 * mm, py - 8 * mm, px + pw - 2 * mm, py + 11 * mm, stroke=0, fill=1)
c.setFillColorRGB(0.98, 0.82, 0.7)                       # face
c.circle(px + pw / 2, py + 19 * mm, 7 * mm, stroke=0, fill=1)
c.setFillColorRGB(0.35, 0.2, 0.12)                       # hair
c.wedge(px + pw / 2 - 7.3 * mm, py + 15.5 * mm, px + pw / 2 + 7.3 * mm, py + 30 * mm,
        0, 180, stroke=0, fill=1)
c.setFillColorRGB(1, 1, 1)                               # cover the sky below the photo
c.rect(px - 1, py - 9 * mm, pw + 2, 9 * mm, stroke=0, fill=1)

# --- left: gray step wedge (CMY composite; the darkest step goes to the K panel) ---
gx, gy, gw = 4 * mm, 11.5 * mm, 25 * mm
for i in range(10):
    v = i / 9
    c.setFillColorRGB(v, v, v)
    c.rect(gx + gw * i / 10, gy, gw / 10 + 0.2, 3.5 * mm, stroke=0, fill=1)

# --- right: header bar and logo (colored -> black halftone on a half panel) ---
c.setFillColorRGB(0.1, 0.3, 0.7)
c.rect(dot_x(HALF_W) + 2 * mm, H - 11 * mm, W - dot_x(HALF_W) - 4 * mm, 7 * mm, stroke=0, fill=1)
c.setFillColorRGB(1, 1, 1)
c.setFont("Helvetica-Bold", 9)
c.drawString(dot_x(HALF_W) + 4 * mm, H - 8.6 * mm, "IDENTITY CARD")
c.setFillColorRGB(0.85, 0.15, 0.15)                      # red logo
c.circle(W - 9 * mm, H - 20 * mm, 4.5 * mm, stroke=0, fill=1)
c.setFillColorRGB(1, 1, 1)
c.setFont("Helvetica-Bold", 8)
c.drawCentredString(W - 9 * mm, H - 21.3 * mm, "EVO")

# --- right: black text ---
tx = dot_x(HALF_W) + 4 * mm
c.setFillColorRGB(0, 0, 0)
c.setFont(JP, 7)
c.drawString(tx, H - 17 * mm, "氏名 / NAME")
c.setFont(JP, 13)
c.drawString(tx, H - 23 * mm, "見本 太郎")
c.setFont("Helvetica", 7)
c.drawString(tx, H - 27 * mm, "MIHON TARO")
c.setFont(JP, 7)
c.drawString(tx, H - 33 * mm, "番号 / No.  0000-0001")
c.drawString(tx, H - 37.5 * mm, "有効期限 / Valid  2027-10-13")

# --- bottom: full-width rainbow + ruler in card dots ---
ry = 2.5 * mm
n = 300
for i in range(n):
    r, g, b = colorsys.hsv_to_rgb(i / n, 1, 1)
    c.setFillColorRGB(r, g, b)
    c.rect(W * i / n, ry, W / n + 0.2, 3 * mm, stroke=0, fill=1)
c.setStrokeColorRGB(0, 0, 0)
c.setFillColorRGB(0, 0, 0)
c.setLineWidth(0.3)
for d in range(380, 481, 5):
    x = dot_x(d)
    tall = d % 10 == 0
    c.line(x, ry + 3 * mm, x, ry + 3 * mm + (2.2 if tall else 1.2) * mm)
    if d % 20 == 0:                                      # two rows so labels don't collide
        c.setFont("Helvetica", 4)
        c.drawCentredString(x, ry + (6 if d % 40 == 0 else 7.6) * mm, str(d))
c.setLineWidth(0.6)
c.line(dot_x(HALF_W), ry - 1 * mm, dot_x(HALF_W), ry + 5.5 * mm)   # driver's boundary
c.setFont("Helvetica", 4)
c.drawString(dot_x(HALF_W) + 1.5, ry - 1 * mm, f"driver {HALF_W}")

c.showPage()
c.save()
