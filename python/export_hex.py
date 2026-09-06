#!/usr/bin/env python3
from pathlib import Path
import argparse
import numpy as np


def signed8_hex(x):
    return f"{int(np.int8(x)) & 0xff:02x}"


def export_vector(values, path, width_bits=8):
    path = Path(path)
    mask = (1 << width_bits) - 1
    with path.open("w") as f:
        for v in values:
            f.write(f"{int(v) & mask:0{width_bits//4}x}\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()
    vals = np.loadtxt(args.input, dtype=np.int64).reshape(-1)
    export_vector(vals, args.output)
    print(f"Wrote {len(vals)} entries to {args.output}")
