#!/usr/bin/env python3
"""
gen_recip_lut.py — Generate the fp16 reciprocal mantissa LUT.

For each 10-bit input mantissa m (representing 1.m in [1.0, 2.0)), compute
1.0 / (1.m) in fp16, then extract the OUTPUT mantissa for the hardware LUT.

Because 1 / (1.m) is in (0.5, 1.0] except at m=0 (where it's exactly 1.0),
the reciprocal's actual normalized fp16 value has:
  - exponent that we compute separately in hardware (depends on m == 0)
  - a 10-bit mantissa we just look up here

What we store per entry:
  - For m == 0:    1.0 / 1.0 = 1.0, fp16 mantissa bits = 0
  - For m != 0:    let r = 1.0 / (1.m); r is in (0.5, 1.0).
                   Normalize r into [1.0, 2.0) by doubling (left-shift mantissa
                   by 1, exponent -= 1). The hardware does the -1 to the
                   exponent unconditionally for m != 0 entries.
                   We store the post-normalize 10-bit mantissa.

Output: one hex value per line (10 bits => 3 hex chars, but $readmemh accepts
arbitrary widths and zero-pads from the left), 1024 lines total.

Usage:
  python3 gen_recip_lut.py                  # writes ../data/recip_lut.mem
  python3 gen_recip_lut.py path/to/out.hex  # writes to the given path
"""

import os
import sys
import numpy as np

# Default output path: data/recip_lut.mem at the project root.
# The script lives in scripts/, so the project root is one level up.
_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.normpath(os.path.join(_HERE, "data", "recip_lut.mem"))

def build_lut():
    entries = []
    for m in range(1024):
        # The true input value is 1.m in [1.0, 2.0)
        # Represented exactly in fp16 with exponent = 15 (biased) and mantissa = m
        # Take its reciprocal in higher precision, then convert back to fp16.
        x_input = 1.0 + (m / 1024.0)            # exact for these m / 2^10 values
        r_exact = 1.0 / x_input                  # in (0.5, 1.0]

        if m == 0:
            # 1.0 / 1.0 = 1.0 exactly. Output mantissa = 0.
            out_mantissa = 0
        else:
            # r is in (0.5, 1.0). Multiply by 2 to normalize into [1.0, 2.0),
            # so it has the standard fp16 "1.mantissa" layout. We then read
            # the mantissa bits.
            r_norm = r_exact * 2.0               # in (1.0, 2.0)
            # Convert to fp16, then read the mantissa bits.
            r_fp16 = np.float16(r_norm)
            bits   = r_fp16.view(np.uint16)
            out_mantissa = bits & 0x3FF          # low 10 bits
        entries.append(out_mantissa)
    return entries

if __name__ == "__main__":
    out_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    lut = build_lut()
    with open(out_path, "w") as f:
        for v in lut:
            f.write(f"{v:03x}\n")
    print(f"wrote {len(lut)} entries to {out_path}")
