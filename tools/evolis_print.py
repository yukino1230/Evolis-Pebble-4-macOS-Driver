#!/usr/bin/env python3
"""Print an image on the front of a card.

Usage: evolis_print.py IMAGE [--ribbon k|ymcko|ymckos] [--out job.bin] [--send]
  IMAGE is scaled to the full card, 1016x648 dots (300 dpi, landscape).
  --ribbon k       black ribbon (default)
           ymcko   full-panel color ribbon: Y/M/C at 32 levels, K, full-card overlay
           ymckos  half-panel color ribbon (e.g. R3013): Y/M/C cover only part of the card
  --out writes the raw job; --send streams it to the printer over USB.
"""
import argparse

import numpy as np
from PIL import Image

from evolis_query import open_printer, query

CARD_W, CARD_H = 1016, 648  # landscape, 300 dpi


def esc(cmd):
    return b"\x1b" + cmd + b"\r"


def to_head(img):
    # Rotate so each printhead line is 648 dots; returns (1016, 648) array.
    return np.asarray(img.resize((CARD_W, CARD_H)).transpose(Image.Transpose.ROTATE_270))


def pack(values, bits):
    # Concatenate each value's low `bits` bits, MSB first (A5013: "each bit is useful").
    v = values.astype(np.uint8).reshape(-1, 1)
    planes = (v >> np.arange(bits - 1, -1, -1, dtype=np.uint8)) & 1
    return np.packbits(planes.reshape(-1)).tobytes()


def mono_job(img):
    black = to_head(img.convert("L")) < 128
    return [esc(b"Pr;k"), esc(b"Ss"), esc(b"Sr"),
            esc(b"Db;k;2;" + pack(black, 1)), esc(b"Se")]


def color_job(img, ribbon):
    rgb = to_head(img.convert("RGB")).astype(np.float32) / 255
    black = rgb.max(axis=2) < 0.15            # near-black goes to the K resin panel
    cmy = 1 - rgb
    cmy[black] = 0
    y, m, c = (np.rint(cmy[..., i] * 31) for i in (2, 1, 0))
    overlay = np.ones(black.shape, dtype=bool)
    return [esc(b"Pr;" + ribbon.encode()), esc(b"Ss"), esc(b"Sr"),
            esc(b"Db;y;32;" + pack(y, 5)),
            esc(b"Db;m;32;" + pack(m, 5)),
            esc(b"Db;c;32;" + pack(c, 5)),
            esc(b"Db;k;2;" + pack(black, 1)),
            esc(b"Db;o;2;" + pack(overlay, 1)),
            esc(b"Se")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--ribbon", choices=["k", "ymcko", "ymckos"], default="k")
    ap.add_argument("--out")
    ap.add_argument("--send", action="store_true")
    args = ap.parse_args()

    img = Image.open(args.image)
    parts = mono_job(img) if args.ribbon == "k" else color_job(img, args.ribbon)
    job = b"".join(parts) + b"\x00" * 64
    print(f"job: {len(job)} bytes")
    if args.out:
        with open(args.out, "wb") as f:
            f.write(job)
    if args.send:
        dev, intf, ep_out, ep_in = open_printer()
        ep_out.write(job, timeout=60000)
        print("sent")


if __name__ == "__main__":
    main()
