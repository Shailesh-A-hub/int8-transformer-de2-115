#!/usr/bin/env python3
"""
Hardware benchmark and Roofline model for INT8 Transformer Attention Accelerator on DE2-115.
Incorporates exact measured cycle counts and operations from ModelSim verification.
"""

from dataclasses import dataclass


@dataclass
class Board:
    name: str = "Terasic DE2-115 (Cyclone IV EP4CE115F29C7)"
    logic_elements: int = 114480
    multipliers_18x18: int = 266
    memory_kbit: int = 3888
    clock_hz: float = 50e6  # 50 MHz on-board oscillator


def total_inference_ops(L=8, d=32, num_classes=6):
    # Operations counted as Multiply + Add = 2 ops per MAC
    q_proj  = L * d * d * 2           # E * W_Q^T
    k_proj  = L * d * d * 2           # E * W_K^T
    v_proj  = L * d * d * 2           # E * W_V^T
    score   = L * L * d * 2           # Q * K^T
    softmax = L * L * 3               # subtract max, exp lookup, normalize
    attn_v  = L * L * d * 2           # A * V
    pooling = L * d                   # mean over sequence
    cls     = num_classes * d * 2     # W_cls * h
    total   = q_proj + k_proj + v_proj + score + softmax + attn_v + pooling + cls
    return {
        "Q Projection": q_proj,
        "K Projection": k_proj,
        "V Projection": v_proj,
        "QK^T Scores": score,
        "Softmax": softmax,
        "Attention x V": attn_v,
        "Mean Pooling": pooling,
        "Classifier": cls,
        "Total Operations": total,
    }


def main():
    b = Board()
    ops_dict = total_inference_ops(L=8, d=32, num_classes=6)
    total_ops = ops_dict["Total Operations"]

    # Measured ModelSim active cycle count
    measured_cycles = 3712
    measured_latency_s = measured_cycles / b.clock_hz
    measured_latency_us = measured_latency_s * 1e6
    throughput_fps = 1.0 / measured_latency_s
    achieved_gops = (total_ops / measured_latency_s) / 1e9

    print("=" * 72)
    print(f"  HARDWARE BENCHMARK & ROOFLINE: {b.name}")
    print("=" * 72)
    print(f"Clock Frequency:            {b.clock_hz / 1e6:.1f} MHz ({1e9/b.clock_hz:.1f} ns period)")
    print(f"On-Chip Multipliers:        {b.multipliers_18x18} (9-bit capable: {b.multipliers_18x18*2})")
    print(f"Active MAC Lanes Used:      8 lanes (3% DSP utilization)")
    print("-" * 72)
    print("Operation Breakdown per Inference (L=8, d=32, Classes=6):")
    for k, v in ops_dict.items():
        if k != "Total Operations":
            print(f"  - {k:22s}: {v:7,d} ops ({100.0*v/total_ops:5.1f}%)")
    print(f"  * Total Operations:       {total_ops:7,d} ops")
    print("-" * 72)
    print("Measured Hardware Performance:")
    print(f"  - Measured Cycle Count:    {measured_cycles:,d} cycles")
    print(f"  - Inference Latency:       {measured_latency_us:.2f} microseconds")
    print(f"  - Inference Throughput:    {throughput_fps:,.1f} inferences / sec")
    print(f"  - Achieved Compute Rate:   {achieved_gops:.3f} GOPS (Giga-Operations/sec)")
    print(f"  - Theoretical Peak (8 MACs): {8 * 2 * b.clock_hz / 1e9:.3f} GOPS")
    print(f"  - Hardware Efficiency:     {(achieved_gops / (8 * 2 * b.clock_hz / 1e9)) * 100.0:.1f}% of 8-lane peak")
    print("=" * 72)


if __name__ == "__main__":
    main()
