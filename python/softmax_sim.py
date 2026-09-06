#!/usr/bin/env python3
"""
Bit-exact-ish numerical reference for the three softmax implementations.

The hardware-oriented Version B uses Q4.4 t = -z * log2(e).
Tier 0: 2^-floor(t)
Tier 1: 2^-floor(t) * LUT(frac(t)), with 16 fractional entries.

Attention probabilities are emitted as unsigned integer weights in [0, 127].
"""

from __future__ import annotations
import argparse
from pathlib import Path
import numpy as np

LOG2E = 1.4426950408889634
FRAC_BITS = 4
FRAC_SCALE = 1 << FRAC_BITS
PROB_MAX = 127


def softmax_fp32(x):
    x = np.asarray(x, dtype=np.float64)
    z = x - np.max(x)
    e = np.exp(z)
    return e / np.sum(e)


def _normalize_weights(weights, out_max=PROB_MAX):
    weights = np.asarray(weights, dtype=np.int64)
    total = int(weights.sum())
    if total <= 0:
        return np.zeros_like(weights, dtype=np.int64)
    return (weights * out_max) // total


def _exp_lut_q16(n=256):
    # exp(z) for z in [-8,0], Q0.16
    z = -np.arange(n, dtype=np.float64) * 8.0 / (n - 1)
    return np.round(np.exp(z) * 65535.0).astype(np.int64)


def softmax_version_a_detour(x, descale_bits=4, lut_bits=8):
    """
    Structural fixed-point conventional detour.

    x is interpreted as integer attention scores. Descale by 2^descale_bits,
    approximate exp over [-8,0] with a 2^lut_bits-entry LUT, then normalize.
    """
    x = np.asarray(x, dtype=np.int64)
    z_int = x - int(x.max())
    scale = float(1 << descale_bits)
    z = np.clip(z_int / scale, -8.0, 0.0)

    n = 1 << lut_bits
    grid = np.linspace(-8.0, 0.0, n)
    lut = np.exp(grid)
    idx = np.rint((z + 8.0) * (n - 1) / 8.0).astype(np.int64)
    idx = np.clip(idx, 0, n - 1)
    weights_q16 = np.round(lut[idx] * 65535.0).astype(np.int64)
    return _normalize_weights(weights_q16)


def _tier1_lut_q16():
    f = np.arange(16, dtype=np.float64) / 16.0
    return np.round((2.0 ** (-f)) * 65535.0).astype(np.int64)


def _base2_weight_q16(z_int, tier=1, max_shift=15):
    z_int = np.asarray(z_int, dtype=np.int64)
    # Q4.4 representation of t=-z*log2(e)
    t_q4 = np.floor((-z_int * LOG2E) * FRAC_SCALE + 0.5).astype(np.int64)
    t_q4 = np.maximum(t_q4, 0)

    q = t_q4 >> FRAC_BITS
    f = t_q4 & (FRAC_SCALE - 1)
    q = np.minimum(q, max_shift)

    if tier == 0:
        # shift-only: fractional term discarded
        weights = np.left_shift(np.ones_like(q, dtype=np.int64), 15 - q)
        return np.maximum(weights, 1)

    lut = _tier1_lut_q16()
    frac_q16 = lut[f]
    weights = np.right_shift(frac_q16, q)
    return np.maximum(weights, 1)


def softmax_version_b_tier0(x, scale_factor=LOG2E):
    x = np.asarray(x, dtype=np.int64)
    z = x - int(x.max())
    w = _base2_weight_q16(z, tier=0)
    return _normalize_weights(w)


def softmax_version_b_tier1(x, lut_entries=16):
    if lut_entries != 16:
        raise ValueError("RTL Tier 1 is fixed at 16 fractional entries")
    x = np.asarray(x, dtype=np.int64)
    z = x - int(x.max())
    w = _base2_weight_q16(z, tier=1)
    return _normalize_weights(w)


def restoring_divider_sim(dividend, divisor, bits=16):
    dividend = int(dividend)
    divisor = int(divisor)
    if divisor <= 0:
        raise ZeroDivisionError("divisor must be positive")
    rem = 0
    quot = 0
    for i in range(bits - 1, -1, -1):
        rem = (rem << 1) | ((dividend >> i) & 1)
        if rem >= divisor:
            rem -= divisor
            quot |= (1 << i)
    return quot, rem


def metrics(ref, approx):
    eps = 1e-12
    ref = np.asarray(ref, dtype=np.float64)
    approx = np.asarray(approx, dtype=np.float64)
    refn = ref / max(float(ref.sum()), eps)
    appn = approx / max(float(approx.sum()), eps)
    mae = float(np.mean(np.abs(refn - appn)))
    mx = float(np.max(np.abs(refn - appn)))
    kl = float(np.sum(refn * np.log((refn + eps) / (appn + eps))))
    rank_inv = float(np.argmax(refn) != np.argmax(appn))
    return mae, mx, kl, rank_inv


def run_suite(seed=7, n_vectors=1000, length=8):
    rng = np.random.default_rng(seed)
    rows = []
    for _ in range(n_vectors):
        # Integer logits approximate the post-QK attention-score domain.
        x = rng.integers(-64, 65, size=length, dtype=np.int64)
        ref = softmax_fp32(x)
        for name, fn in [
            ("Version_A", softmax_version_a_detour),
            ("Tier_0", softmax_version_b_tier0),
            ("Tier_1", softmax_version_b_tier1),
        ]:
            a = fn(x)
            mae, mx, kl, ri = metrics(ref, a)
            rows.append((name, mae, mx, kl, ri))
    return rows


def summarize(rows):
    names = ["Version_A", "Tier_0", "Tier_1"]
    print(f"{'Variant':12s} {'MAE':>12s} {'MaxErr':>12s} {'KL':>12s} {'RankInv%':>12s}")
    print("-" * 64)
    for name in names:
        r = [x for x in rows if x[0] == name]
        vals = np.asarray([[x[1], x[2], x[3], x[4]] for x in r])
        print(f"{name:12s} {vals[:,0].mean():12.6g} {vals[:,1].mean():12.6g} "
              f"{vals[:,2].mean():12.6g} {100*vals[:,3].mean():11.3f}")


def export_vectors(outdir, count=32, length=8, seed=11):
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    with (out / "softmax_vectors.txt").open("w") as f:
        for _ in range(count):
            x = rng.integers(-64, 65, size=length)
            y0 = softmax_version_b_tier0(x)
            y1 = softmax_version_b_tier1(x)
            f.write(" ".join(map(str, x.tolist())) + "\n")
            f.write("T0 " + " ".join(map(str, y0.tolist())) + "\n")
            f.write("T1 " + " ".join(map(str, y1.tolist())) + "\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=int, default=1000)
    ap.add_argument("--length", type=int, default=8)
    ap.add_argument("--export", action="store_true")
    args = ap.parse_args()

    rows = run_suite(n_vectors=args.vectors, length=args.length)
    summarize(rows)

    for d in [1, 2, 3, 7, 15, 31, 127, 255, 1023, 32767]:
        q, r = restoring_divider_sim(d, 7, bits=16)
        assert q == d // 7 and r == d % 7
    print("\nRestoring divider Python self-check: PASS")

    if args.export:
        export_vectors(Path(__file__).resolve().parents[1] / "mem")
        print("Exported mem/softmax_vectors.txt")
