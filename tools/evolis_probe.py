#!/usr/bin/env python3
"""Record how the printer answers a fixed set of commands, to compare firmware versions.

Usage: evolis_probe.py [--save out.json] [--compare before.json]
       evolis_probe.py --scan-reads names.txt --save scan.json   try every read command in the list
No card and no ribbon are used. Settings that are changed to test whether a
command is accepted are put back right away (ribbon type, insertion mode).
"""
import argparse
import json

import usb.util

from evolis_query import open_printer, query

READS = ["Rtp", "Rfv", "Rr", "Rr;p", "Rc;a", "Rc;k", "Rc;o", "Rl;y", "Rmi", "Rrs", "Rro", "Rsp",
         "Rx", "Ry", "Rco;c", "Rco;p", "Rco;n", "Rco;a", "Rco;m", "Rlr;r", "Rlr;p", "Rcr", "Rrm",
         "Rkn", "Rpk", "Rmk", "Rbm", "Rem", "Rck", "Rnl", "Rnw", "Rfn", "Rpn"]
# commands that may or may not be accepted; each is followed by the command that restores the setting
TRIES = [("Pr;ymckos;t", None), ("Pr;k;t", None), ("Pmi;B", None), ("Pmi;M", "Pmi;F"),
         ("Pc;k;=;21", None), ("Pl;a;=;21", None), ("Rco;I", None), ("Rco;l", None),
         ("Rse", None), ("Rse;c", None), ("Rrt", None), ("Rps;c", None)]


def ask(o, i, cmd, timeout=4):
    query(o, i, "Rtp")                  # flush the previous answer the printer keeps replaying
    r = query(o, i, cmd, timeout=timeout).strip()
    if r == "Pebble 4" and cmd != "Rtp":    # the answer was not ready yet; read once more
        r = query(o, i, cmd, timeout=timeout).strip()
    return r


def scan(o, i, names):
    """Only read commands (R...). Anything but 'ERROR CDE' (unknown command) is kept."""
    found = {}
    for n, c in enumerate(names):
        if not c.startswith("R") or c in ("Reset", "Red"):
            continue
        r = ask(o, i, c, timeout=1.5)
        if r != "ERROR CDE":
            found[c] = r
            print(f"{c:8} {r!r}", flush=True)
        if n % 1000 == 0:
            print(f"# {n}/{len(names)}", flush=True)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save")
    ap.add_argument("--compare")
    ap.add_argument("--scan-reads")
    args = ap.parse_args()
    dev, intf, o, i = open_printer()
    result = {}
    if args.scan_reads:
        try:
            result = scan(o, i, open(args.scan_reads).read().split())
        finally:
            usb.util.release_interface(dev, intf.bInterfaceNumber)
            usb.util.dispose_resources(dev)
        if args.save:
            json.dump(result, open(args.save, "w"), ensure_ascii=False, indent=1)
        return
    try:
        ribbon = ask(o, i, "Rr")        # put the ribbon type back afterwards
        mode = ask(o, i, "Rmi")
        for c in READS:
            result[c] = ask(o, i, c)
        for c, restore in TRIES:
            result[c] = ask(o, i, c)
            if restore:
                ask(o, i, restore)
        ask(o, i, f"Pr;{ribbon}")
        ask(o, i, "Pmi;M" if mode.startswith("Manual") else "Pmi;F")
        result["(restored Rr)"] = ask(o, i, "Rr")
        result["(restored Rmi)"] = ask(o, i, "Rmi")
    finally:
        usb.util.release_interface(dev, intf.bInterfaceNumber)
        usb.util.dispose_resources(dev)
    before = json.load(open(args.compare)) if args.compare else {}
    for k, v in result.items():
        mark = "" if not before else ("  (同じ)" if before.get(k) == v else f"  ← 前: {before.get(k)!r}")
        print(f"{k:14} {v!r}{mark}")
    if args.save:
        json.dump(result, open(args.save, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
