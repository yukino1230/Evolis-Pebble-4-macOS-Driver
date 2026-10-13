#!/usr/bin/env python3
"""Send read-only status queries (ESC R... CR) to an Evolis Pebble over USB.

These commands never feed a card or advance the ribbon.
Usage: evolis_query.py [CMD ...]   e.g. evolis_query.py Rtp Rfv "Rc;k"
"""
import sys
import time

import usb.backend.libusb1
import usb.core
import usb.util

VID = 0x0F49
DEFAULT_CMDS = ["Rtp", "Rfv", "Rsn", "Rco;p"]


def open_printer():
    backend = usb.backend.libusb1.get_backend() or usb.backend.libusb1.get_backend(
        find_library=lambda _: "/opt/homebrew/lib/libusb-1.0.dylib")
    dev = usb.core.find(idVendor=VID, backend=backend)
    if dev is None:
        sys.exit("Evolis printer not found (VID 0x0F49)")
    cfg = dev.get_active_configuration()
    intf = usb.util.find_descriptor(cfg, bInterfaceClass=7)
    if dev.is_kernel_driver_active(intf.bInterfaceNumber):
        dev.detach_kernel_driver(intf.bInterfaceNumber)
    usb.util.claim_interface(dev, intf.bInterfaceNumber)
    ep_out = usb.util.find_descriptor(
        intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
    ep_in = usb.util.find_descriptor(
        intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
    return dev, intf, ep_out, ep_in


def query(ep_out, ep_in, cmd, timeout=2.0):
    # The printer keeps replaying the last answer (NUL-terminated) on every IN
    # read until the next command arrives, so stop at the first NUL.
    ep_out.write(b"\x1b" + cmd.encode("ascii") + b"\r")
    buf = b""
    deadline = time.monotonic() + timeout
    while b"\x00" not in buf and time.monotonic() < deadline:
        try:
            buf += bytes(ep_in.read(ep_in.wMaxPacketSize, timeout=200))
        except usb.core.USBTimeoutError:
            pass
    return buf.split(b"\x00", 1)[0].decode("ascii", "replace")


def main():
    dev, intf, ep_out, ep_in = open_printer()
    try:
        for cmd in sys.argv[1:] or DEFAULT_CMDS:
            print(f"{cmd:8} -> {query(ep_out, ep_in, cmd)}")
    finally:
        usb.util.release_interface(dev, intf.bInterfaceNumber)
        usb.util.dispose_resources(dev)


if __name__ == "__main__":
    main()
