#!/usr/bin/env python3
"""Check whether the printer wants cleaning, or run the cleaning cycle.

Usage: evolis_clean.py          read the cleaning counters and Rlr;r (no card, no ribbon used)
       evolis_clean.py --run    run the cleaning cycle (Scp): remove the ribbon and
                                put a cleaning card in the feeder first

A5013 Rev.E:
  Rco;n / Rco;a / Rco;m  number of cleanings / average and maximum cards between cleanings
  Rlr;r                  "ERR NEED CLEANING" when the cleaning counter is out
  Scp                    checks there is no ribbon, inserts a cleaning card, moves it five
                         times under the rollers and the print head, and ejects it
"""
import argparse
import time

import usb.core
import usb.util

from evolis_query import open_printer, query


def ask(o, i, cmd, timeout=4.0):
    query(o, i, "Rtp")          # flush whatever the printer is still replaying
    return query(o, i, cmd, timeout=timeout).strip()


def status(o, i):
    rows = [("Rco;c", "入れたカードの数"), ("Rco;n", "クリーニングの回数"),
            ("Rco;a", "クリーニングの平均間隔（枚）"), ("Rco;m", "クリーニングの最大間隔（枚）"),
            ("Rlr;r", "クリーニングの時期")]
    for cmd, label in rows:
        print(f"{label:20} {cmd:6} -> {ask(o, i, cmd)}")


def run(o, i):
    print("クリーニングを実行します。")
    print("  1. リボンを外してください")
    print("  2. クリーニングカードをフィーダーに入れてください")
    if input("準備ができたら yes と入力: ").strip() != "yes":
        print("やめました"); return
    o.write(b"\x1bScp\r")
    print("実行中…")
    start = time.monotonic()
    while time.monotonic() - start < 180:
        time.sleep(5)
        try:
            if ask(o, i, "Rtp", timeout=2) == "Pebble 4":
                break
        except usb.core.USBError:
            pass            # busy while cleaning
    print(f"終わりました（{time.monotonic() - start:.0f} 秒）。最後の返事: {ask(o, i, 'Rlr;p')}")
    status(o, i)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    args = ap.parse_args()
    dev, intf, o, i = open_printer()
    try:
        run(o, i) if args.run else status(o, i)
    finally:
        usb.util.release_interface(dev, intf.bInterfaceNumber)
        usb.util.dispose_resources(dev)


if __name__ == "__main__":
    main()
