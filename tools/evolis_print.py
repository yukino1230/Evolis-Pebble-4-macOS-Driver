#!/usr/bin/env python3
"""Print a monochrome image on the front of a card with a black (K) ribbon.

Usage: evolis_print.py IMAGE [--out job.bin] [--send]
  IMAGE is scaled to the full card, 1016x648 dots (300 dpi, landscape).
  --out writes the raw job; --send streams it to the printer over USB.
"""
import argparse

from PIL import Image

from evolis_query import open_printer, query

CARD_W, CARD_H = 1016, 648  # landscape, 300 dpi


def esc(cmd):
    return b"\x1b" + cmd + b"\r"


def bitmap(img):
    # Rotate so each printhead line is 648 dots (81 bytes); 1 bit = black.
    img = img.convert("L").resize((CARD_W, CARD_H)).transpose(Image.Transpose.ROTATE_270)
    bw = img.point(lambda v: 255 if v < 128 else 0).convert("1")
    return bw.tobytes()  # "1" mode packs MSB-first, 1 = white -> inverted above


def build_job(img):
    return b"".join([
        esc(b"Pr;k"),
        esc(b"Ss"),
        esc(b"Sr"),
        esc(b"Db;k;2;" + bitmap(img)),
        esc(b"Se"),
        b"\x00" * 64,
    ])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--out")
    ap.add_argument("--send", action="store_true")
    args = ap.parse_args()

    job = build_job(Image.open(args.image))
    print(f"job: {len(job)} bytes")
    if args.out:
        with open(args.out, "wb") as f:
            f.write(job)
    if args.send:
        dev, intf, ep_out, ep_in = open_printer()
        ep_out.write(job, timeout=30000)
        print("sent; Rtp ->", query(ep_out, ep_in, "Rtp"))


if __name__ == "__main__":
    main()
