#!/usr/bin/env python3
"""
gen_sincos_lut.py — Generate the fp16 sin/cos LUT.

The 8-bit angle index represents a fraction of a full turn:
  index 0   -> 0          radians
  index 64  -> pi/2       radians (90 deg)
  index 128 -> pi         radians (180 deg)
  index 192 -> 3*pi/2     radians (270 deg)
  index 255 -> ~ 2*pi     radians (just shy of 360 deg)

The angular resolution is 360/256 = 1.40625 degrees per LSB.

Emits two files in $readmemh format:
  sin_lut.hex   — 256 entries, one fp16 sine value per line
  cos_lut.hex   — 256 entries, one fp16 cosine value per line

Usage:
  python3 gen_sincos_lut.py            # writes ../data/sin_lut.hex, ../data/cos_lut.hex
  python3 gen_sincos_lut.py out_dir    # writes to <out_dir>/sin_lut.hex, etc.
"""

import sys, os
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT_DIR = os.path.normpath(os.path.join(_HERE, "..", "data"))

def build():
    sins, coss = [], []
    for i in range(256):
        theta = (i / 256.0) * 2.0 * np.pi
        sins.append(np.float16(np.sin(theta)).view(np.uint16))
        coss.append(np.float16(np.cos(theta)).view(np.uint16))
    return sins, coss

if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT_DIR
    os.makedirs(out_dir, exist_ok=True)
    sins, coss = build()
    sp = os.path.join(out_dir, "sin_lut.hex")
    cp = os.path.join(out_dir, "cos_lut.hex")
    with open(sp, "w") as f:
        for v in sins: f.write(f"{v:04x}\n")
    with open(cp, "w") as f:
        for v in coss: f.write(f"{v:04x}\n")
    print(f"wrote sin_lut.hex and cos_lut.hex ({len(sins)} entries each) to {out_dir}")
