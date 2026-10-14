#!/usr/bin/env python3
"""Printer Application の Web の設定画面に出す英語と日本語の文字列を作る(C のヘッダにして埋め込む)。

表示名は PPD と同じものを使う(driver/mkppd.py の表から作る)。
  python3 printer-app/mkstrings.py > build/printer-app/evolis-strings.h
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "driver"))
import mkppd  # noqa: E402

# 独自属性 -> PPD のキー
LEVEL_ATTRS = {
    "EvolisContrastK": "evolis-black-density",
    "EvolisContrastColor": "evolis-color-density",
    "EvolisBrightness": "evolis-color-brightness",
    "EvolisContrastOverlay": "evolis-overlay-density",
}


def strings(lang):
    i = 0 if lang == "en" else 1
    out = []

    def add(key, en, ja):
        text = (en, ja)[i].replace('"', '\\"')
        out.append(f'"{key}" = "{text}";')
    add("evolis-ribbon", "Ribbon", "リボン")
    for v, en, ja in mkppd.RIBBONS:
        add(f"evolis-ribbon.{v}", en, ja)
    add("evolis-overlay", "Overlay (protective layer)", "オーバーレイ (保護層)")
    for v, en, ja in mkppd.OVERLAYS:
        add(f"evolis-overlay.{v}", en, ja)
    add("evolis-black-mode", "Black panel rendering", "黒パネルの処理")
    for v, en, ja in mkppd.KMODES:
        add(f"evolis-black-mode.{v}", en, ja)
    for key, en, ja, _order, _low, _high in mkppd.LEVELS:
        add(LEVEL_ATTRS[key], f"{en}, 0-20 (standard 10)", f"{ja}、0〜20 (標準 10)")
    add("media.om_cr80_85.6x54mm", *mkppd.CARD)
    return "\n".join(out) + "\n"


def c_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n\"\n  \"") + '"'


print("/* printer-app/mkstrings.py が作る。手で直さない */")
for lang in ("en", "ja"):
    print(f"static const char STRINGS_{lang.upper()}[] =\n  {c_string(strings(lang))};")
