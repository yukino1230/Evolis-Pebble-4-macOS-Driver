#!/usr/bin/env python3
"""Halftone calibration card for the black (K) panel.

Right of the half-panel boundary, each row is an 11-step wedge (0..100 %
nominal coverage) rendered with one halftone method and tone curve, to find
a setting that survives resin dot gain. Row labels are drawn on the left.

Usage: make_halftone_cal.py [--ribbon ymckos] [--preview out.png] [--out job.bin] [--send]
"""
import argparse

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from evolis_print import CARD_H, CARD_W, esc, pack
from evolis_query import open_printer

X0, STEP_W, STEPS = 445, 51, 11
ROW_H, ROW_GAP, Y0 = 62, 15, 20

def cluster(n):
    """n x n clustered-dot threshold matrix: cells ordered by distance from the center."""
    c = (n - 1) / 2
    cells = sorted(((y - c) ** 2 + (x - c) ** 2, np.arctan2(y - c, x - c), y, x)
                   for y in range(n) for x in range(n))
    m = np.zeros((n, n), dtype=int)
    for rank, (_, _, y, x) in enumerate(cells):
        m[y, x] = rank
    return m


def fs(cov):
    """Floyd-Steinberg on coverage (1 = black)."""
    a = cov.astype(np.float32).copy()
    h, w = a.shape
    out = np.zeros_like(a, dtype=bool)
    for y in range(h):
        for x in range(w):
            out[y, x] = a[y, x] >= 0.5
            e = a[y, x] - out[y, x]
            if x + 1 < w: a[y, x + 1] += e * 7 / 16
            if y + 1 < h:
                if x > 0: a[y + 1, x - 1] += e * 3 / 16
                a[y + 1, x] += e * 5 / 16
                if x + 1 < w: a[y + 1, x + 1] += e / 16
    return out


def ordered(cov, matrix, y0, x0):
    n = matrix.shape[0]
    h, w = cov.shape
    ys, xs = np.mgrid[y0:y0 + h, x0:x0 + w]
    thr = (matrix[ys % n, xs % n] + 0.5) / matrix.size
    return cov > thr


ROWS = [
    ("A  diffusion  as is (now)", "fs", 1.0),
    ("B  diffusion  ^1.6", "fs", 1.6),
    ("C  diffusion  ^2.2", "fs", 2.2),
    ("D  cluster4  as is", "c4", 1.0),
    ("E  cluster4  ^1.6", "c4", 1.6),
    ("F  cluster4  ^2.2", "c4", 2.2),
    ("G  cluster6  ^1.6", "c6", 1.6),
    ("H  cluster6  ^2.2", "c6", 2.2),
]


def build():
    k = np.zeros((CARD_H, CARD_W), dtype=bool)          # card coords [y][x]
    label = Image.new("1", (CARD_W, CARD_H), 0)
    d = ImageDraw.Draw(label)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
    matrices = {"c4": cluster(4), "c6": cluster(6)}
    for s in range(STEPS):
        d.text((X0 + s * STEP_W + STEP_W // 2, 2), f"{s * 10}", font=small, fill=1, anchor="mt")
    for r, (name, method, gamma) in enumerate(ROWS):
        y = Y0 + r * (ROW_H + ROW_GAP)
        d.text((20, y + ROW_H // 2), name, font=font, fill=1, anchor="lm")
        for s in range(STEPS):
            x = X0 + s * STEP_W
            cov = np.full((ROW_H, STEP_W - 4), (s / 10) ** gamma)
            dots = fs(cov) if method == "fs" else ordered(cov, matrices[method], y, x)
            k[y:y + ROW_H, x:x + STEP_W - 4] = dots
    k |= np.asarray(label, dtype=bool)
    return k


def job(k, ribbon):
    head = np.rot90(k, -1)                  # card [y][x] -> head line x, dot (647 - y)
    zeros = np.zeros(head.shape, dtype=np.uint8)
    parts = [esc(b"Pr;" + ribbon.encode()), esc(b"Ss"), esc(b"Sr")]
    if ribbon != "k":
        parts += [esc(b"Db;%s;32;" % p + pack(zeros, 5)) for p in (b"y", b"m", b"c")]
    parts.append(esc(b"Db;k;2;" + pack(head, 1)))
    if ribbon != "k":
        parts.append(esc(b"Db;o;2;" + pack(np.ones(head.shape, dtype=bool), 1)))
    parts.append(esc(b"Se"))
    return b"".join(parts) + b"\x00" * 64


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ribbon", choices=["k", "ymcko", "ymckos"], default="ymckos")
    ap.add_argument("--preview")
    ap.add_argument("--out")
    ap.add_argument("--send", action="store_true")
    args = ap.parse_args()
    k = build()
    if args.preview:
        Image.fromarray(~k).save(args.preview)
    data = job(k, args.ribbon)
    print(f"job: {len(data)} bytes")
    if args.out:
        open(args.out, "wb").write(data)
    if args.send:
        dev, intf, ep_out, ep_in = open_printer()
        ep_out.write(data, timeout=60000)
        print("sent")


if __name__ == "__main__":
    main()
