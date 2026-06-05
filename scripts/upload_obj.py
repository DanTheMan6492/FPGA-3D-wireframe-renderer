#!/usr/bin/env python3
# upload_obj.py - Upload an OBJ mesh to the FPGA wireframe renderer over UART.
#
# Usage:
#   python3 upload_obj.py mesh.obj COM4             (Windows)
#   python3 upload_obj.py mesh.obj /dev/ttyUSB0     (Linux/Mac)
#   python3 upload_obj.py mesh.obj --dry-run
#   python3 upload_obj.py mesh.obj COM4 --decimate  (auto-reduce if too large)
#
# Wire format:
#   byte 0              : vertex_count (V)
#   byte 1              : face_count (F)
#   bytes [2..2+3V-1]   : vertex coords, signed int8, xyz per vertex
#   bytes [2+3V..end]   : face indices, uint8, abc per face
#
# Coordinates are centered and scaled to fit [-COORD_MAX, +COORD_MAX].
# Hardware limits: 255 vertices, 255 faces.
# Use --decimate for models that exceed these limits.

import argparse
import math
import sys
from pathlib import Path

BAUD_RATE    = 9600
COORD_MAX    = 100
MAX_VERTICES = 255
MAX_FACES    = 255


# ---------------------------------------------------------------------------
# OBJ parser
# ---------------------------------------------------------------------------

def parse_obj(path):
    vertices = []
    faces = []
    with open(path) as f:
        for line_no, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            tag = parts[0]
            if tag == "v":
                if len(parts) < 4:
                    raise ValueError(f"line {line_no}: bad vertex: {raw!r}")
                vertices.append(tuple(map(float, parts[1:4])))
            elif tag == "f":
                idxs = []
                for tok in parts[1:]:
                    first = tok.split("/")[0]
                    idx = int(first)
                    if idx < 0:
                        idx = len(vertices) + idx + 1
                    idxs.append(idx - 1)
                if len(idxs) < 3:
                    raise ValueError(f"line {line_no}: face needs >= 3 verts")
                for k in range(1, len(idxs) - 1):
                    faces.append((idxs[0], idxs[k], idxs[k + 1]))
    return vertices, faces


# ---------------------------------------------------------------------------
# Decimation (edge collapse)
# ---------------------------------------------------------------------------

def decimate(vertices, faces, target_faces, target_vertices=MAX_VERTICES):
    verts = list(vertices)
    faces = [list(f) for f in faces]

    def elen(i, j):
        ax, ay, az = verts[i]; bx, by, bz = verts[j]
        return math.sqrt((ax-bx)**2 + (ay-by)**2 + (az-bz)**2)

    for _ in range(len(faces) * 10):
        nf = len(faces)
        nv = sum(1 for v in verts if v is not None)
        if nf <= target_faces and nv <= target_vertices:
            break

        edges = set()
        for f in faces:
            a, b, c = f
            edges.add((min(a,b), max(a,b)))
            edges.add((min(b,c), max(b,c)))
            edges.add((min(a,c), max(a,c)))

        best, best_len = None, float("inf")
        for i, j in edges:
            if verts[i] is None or verts[j] is None:
                continue
            l = elen(i, j)
            if l < best_len:
                best_len = l; best = (i, j)
        if best is None:
            break

        i, j = best
        ax, ay, az = verts[i]; bx, by, bz = verts[j]
        verts[i] = ((ax+bx)/2, (ay+by)/2, (az+bz)/2)
        verts[j] = None

        new_faces = []
        for f in faces:
            nf2 = [i if v == j else v for v in f]
            if len(set(nf2)) == 3:
                new_faces.append(nf2)
        faces = new_faces

    old_to_new = {}
    new_verts = []
    for old_idx, v in enumerate(verts):
        if v is not None:
            old_to_new[old_idx] = len(new_verts)
            new_verts.append(v)

    new_faces = []
    for f in faces:
        mapped = tuple(old_to_new[v] for v in f)
        if len(set(mapped)) == 3:
            new_faces.append(mapped)

    return new_verts, new_faces


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

def normalize_vertices(vertices, coord_max=COORD_MAX):
    if not vertices:
        return []
    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    zs = [v[2] for v in vertices]
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2
    cz = (min(zs) + max(zs)) / 2
    half = max(max(xs)-cx, max(ys)-cy, max(zs)-cz,
               cx-min(xs), cy-min(ys), cz-min(zs))
    if half == 0:
        return [(0, 0, 0)] * len(vertices)
    scale = coord_max / half
    result = []
    for x, y, z in vertices:
        result.append((
            max(-128, min(127, int(round((x-cx)*scale)))),
            max(-128, min(127, int(round((y-cy)*scale)))),
            max(-128, min(127, int(round((z-cz)*scale)))),
        ))
    return result


# ---------------------------------------------------------------------------
# Packet builder
# ---------------------------------------------------------------------------

def build_packet(vertices, faces):
    V, F = len(vertices), len(faces)
    if V == 0: raise ValueError("mesh has no vertices")
    if F == 0: raise ValueError("mesh has no faces")
    if V > MAX_VERTICES:
        raise ValueError(
            f"too many vertices ({V}); max is {MAX_VERTICES}. "
            f"Use --decimate to reduce automatically.")
    if F > MAX_FACES:
        raise ValueError(
            f"too many faces ({F}); max is {MAX_FACES}. "
            f"Use --decimate to reduce automatically.")
    for i, (a, b, c) in enumerate(faces):
        for idx, lbl in ((a,"a"),(b,"b"),(c,"c")):
            if not (0 <= idx < V):
                raise ValueError(f"face {i} index {lbl}={idx} out of range")
    out = bytearray([V, F])
    for x, y, z in vertices:
        out += bytes([x & 0xff, y & 0xff, z & 0xff])
    for a, b, c in faces:
        out += bytes([a & 0xff, b & 0xff, c & 0xff])
    return bytes(out)


# ---------------------------------------------------------------------------
# obj_mem writer (for FPGA BRAM preload)
# ---------------------------------------------------------------------------

def int8_to_fp16(x):
    if x == 0: return 0
    sign = 1 if x < 0 else 0
    mag  = abs(x)
    msb  = mag.bit_length() - 1
    return (sign << 15) | ((15 + msb) << 10) | ((mag << (10 - msb)) & 0x3FF)


def build_obj_mem_words(vertices, faces):
    words = []
    for x, y, z in vertices:
        words += [int8_to_fp16(x), int8_to_fp16(y), int8_to_fp16(z)]
    for a, b, c in faces:
        words += [a & 0xff, b & 0xff, c & 0xff]
    return words


# ---------------------------------------------------------------------------
# Serial transport
# ---------------------------------------------------------------------------

def send_packet(packet, port, baud=BAUD_RATE):
    try:
        import serial
    except ImportError:
        print("Error: pyserial not installed.  pip install pyserial",
              file=sys.stderr)
        sys.exit(1)
    with serial.Serial(port, baudrate=baud, bytesize=8,
                       parity="N", stopbits=1, timeout=5.0) as ser:
        ser.write(packet)
        ser.flush()


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def report(packet, vertices, faces, raw_v, raw_f, dec_v=None, dec_f=None):
    V, F = len(vertices), len(faces)
    print(f"  Parsed:  {raw_v} vertices, {raw_f} faces")
    if dec_v is not None:
        print(f"  Decimated to: {dec_v} vertices, {dec_f} faces")
    print(f"  Sending: V={V}, F={F}  ({len(packet)} bytes)")
    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    zs = [v[2] for v in vertices]
    print(f"  x: [{min(xs)}, {max(xs)}]  "
          f"y: [{min(ys)}, {max(ys)}]  "
          f"z: [{min(zs)}, {max(zs)}]")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("obj",  type=Path)
    ap.add_argument("port", nargs="?",
                    help="serial port, e.g. COM4 or /dev/ttyUSB0")
    ap.add_argument("--dry-run",      action="store_true")
    ap.add_argument("--baud",         type=int, default=BAUD_RATE)
    ap.add_argument("--coord-max",    type=int, default=COORD_MAX)
    ap.add_argument("--decimate",     action="store_true",
                    help="auto-reduce face/vertex count to fit hardware limits")
    ap.add_argument("--target-faces", type=int, default=MAX_FACES)
    ap.add_argument("--target-verts", type=int, default=MAX_VERTICES)
    ap.add_argument("--hex",          action="store_true",
                    help="print packet bytes as hex")
    ap.add_argument("--hex-file",     type=Path, default=None,
                    help="write packet to .mem file (testbench)")
    ap.add_argument("--obj-mem-hex",  type=Path, default=None,
                    help="write obj_mem init .mem file (FPGA preload)")
    args = ap.parse_args()

    if not args.obj.exists():
        print(f"Error: {args.obj} not found", file=sys.stderr); sys.exit(1)

    if (not args.dry_run and args.hex_file is None
            and args.obj_mem_hex is None and args.port is None):
        print("Error: serial port required "
              "(or use --dry-run / --hex-file / --obj-mem-hex)",
              file=sys.stderr)
        sys.exit(1)

    print(f"Reading {args.obj} ...")
    float_verts, faces = parse_obj(args.obj)
    raw_v, raw_f = len(float_verts), len(faces)

    if not float_verts: print("Error: no vertices", file=sys.stderr); sys.exit(1)
    if not faces:       print("Error: no faces",    file=sys.stderr); sys.exit(1)

    dec_v = dec_f = None
    too_big = (raw_v > args.target_verts or raw_f > args.target_faces)

    if too_big and not args.decimate:
        print(f"Error: model has {raw_v} vertices and {raw_f} faces.",
              file=sys.stderr)
        print(f"  Hardware limits: {MAX_VERTICES} vertices, {MAX_FACES} faces.",
              file=sys.stderr)
        print(f"  Re-run with --decimate to reduce automatically.",
              file=sys.stderr)
        sys.exit(1)

    if too_big:
        print(f"  Decimating {raw_v}V/{raw_f}F -> "
              f"<={args.target_verts}V/{args.target_faces}F ...")
        float_verts, faces = decimate(float_verts, faces,
                                      target_faces=args.target_faces,
                                      target_vertices=args.target_verts)
        dec_v, dec_f = len(float_verts), len(faces)
        print(f"  Result: {dec_v}V, {dec_f}F")

    vertices = normalize_vertices(float_verts, coord_max=args.coord_max)

    try:
        packet = build_packet(vertices, faces)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr); sys.exit(1)

    report(packet, vertices, faces, raw_v, raw_f, dec_v, dec_f)

    if args.hex:
        print("\n  Hex dump:")
        for i in range(0, len(packet), 16):
            print("    " + " ".join(f"{b:02x}" for b in packet[i:i+16]))

    if args.hex_file:
        with open(args.hex_file, "w") as f:
            for b in packet: f.write(f"{b:02x}\n")
        print(f"\nWrote {len(packet)} bytes to {args.hex_file}")

    if args.obj_mem_hex:
        words = build_obj_mem_words(vertices, faces)
        with open(args.obj_mem_hex, "w") as f:
            for w in words: f.write(f"{w:04x}\n")
        print(f"\nWrote {len(words)} words to {args.obj_mem_hex}")

    if args.dry_run or args.port is None:
        print("\n(dry run)" if args.dry_run else "\n(no port - file(s) written)")
        return

    print(f"\nSending to {args.port} at {args.baud} baud ...")
    send_packet(packet, args.port, baud=args.baud)
    print("Done.")


if __name__ == "__main__":
    main()