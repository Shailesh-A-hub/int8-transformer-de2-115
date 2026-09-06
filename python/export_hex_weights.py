#!/usr/bin/env python3
"""
Converts INT8 weight text files into Verilog $readmemh compatible hexadecimal files.
Signed 8-bit integers [-128, 127] are represented as 2-digit hex (two's complement, 00-FF).
"""

from pathlib import Path
import numpy as np


def export_hex_file(src_path: Path, dst_path: Path, width_bytes: int = 1):
    vals = np.loadtxt(src_path, dtype=np.int64).reshape(-1)
    mask = (1 << (width_bytes * 8)) - 1
    with dst_path.open("w") as f:
        for v in vals:
            unsigned_v = int(v) & mask
            f.write(f"{unsigned_v:0{width_bytes*2}x}\n")
    print(f"Exported {len(vals)} values from {src_path.name} -> {dst_path.name}")


def main():
    base_dir = Path(__file__).resolve().parents[1]
    mem_dir = base_dir / "mem"
    mem_dir.mkdir(parents=True, exist_ok=True)

    tensors = ["embedding", "W_Q", "W_K", "W_V", "W_cls"]
    for t in tensors:
        src = mem_dir / f"{t}.txt"
        dst = mem_dir / f"{t}.hex"
        if src.exists():
            export_hex_file(src, dst, width_bytes=1)
        else:
            print(f"Warning: {src} not found")


if __name__ == "__main__":
    main()
