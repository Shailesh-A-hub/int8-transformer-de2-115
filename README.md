# INT8 Transformer Attention Accelerator on Terasic DE2-115 FPGA

[![FPGA](https://img.shields.io/badge/FPGA-Cyclone%20IV%20EP4CE115-blue.svg)](https://www.intel.com/content/www/us/en/products/details/fpga/cyclone/iv.html)
[![Board](https://img.shields.io/badge/Target%20Board-Terasic%20DE2--115-green.svg)](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&CategoryNo=139&No=502)
[![Simulation](https://img.shields.io/badge/ModelSim%2010.5b-18%2F18%20PASS-brightgreen.svg)]()
[![Precision](https://img.shields.io/badge/Datapath-Pure%20INT8%20Dynamic-orange.svg)]()
[![Division](https://img.shields.io/badge/Divider-24--bit%20Sequential%20Restoring-purple.svg)]()

A complete, cycle-accurate, synthesizable hardware implementation of a **Transformer Attention Accelerator for Edge Intent Classification**, designed and verified for the **Terasic DE2-115 FPGA (Altera/Intel Cyclone IV EP4CE115F29C7)**.

---

## 🔬 Research Focus & Architectural Innovation

Transformer models traditionally require floating-point (FP32) arithmetic for self-attention, specifically in the exponential and normalization stages of **Softmax**. On resource-constrained edge FPGAs lacking hard FPUs, deploying attention requires either:
1. **Conventional Fixed-Point Detour (Version A)**: De-scale the quantized scores $\to$ compute wider exponential approximation via large 256-entry lookup tables $\to$ accumulate $\to$ multi-cycle division $\to$ re-quantize back to INT8.
2. **Integer-Native Base-2 Softmax (Proposed Version B)**: Transform $e^z = 2^{z \cdot \log_2(e)}$, keeping the exponentiation natively inside integer domain:
   - **Tier 0 (Shift-Only Base-2)**: Pure linear shift-amount calculation and power-of-two barrel shifting. **Zero LUTs, zero DSPs/multipliers**.
   - **Tier 1 (Base-2 + 16-LUT Refinement)**: Fixed-point Q4.4 decomposition ($q = t[7:4], f = t[3:0]$), indexing a tiny 16-entry fractional table for $2^{-f}$ followed by barrel shifting. High fidelity with minimal logic footprint.

```text
==============================================================================================
                                  ARCHITECTURAL COMPARISON
==============================================================================================
   Conventional Detour (Version A)                Integer-Native Softmax (Proposed Version B)
-------------------------------------         --------------------------------------------------
 INT8 Attention Scores                         INT8 Attention Scores
          │                                             │
          ▼                                             ▼
 [Stage 1: Find Row Max]                       [Stage 1: Find Row Max]
          │                                             │
          ▼                                             ▼
 [Stage 2: Fixed-Point Descale]  (8 cycles)    [Stage 2: Folded Scale & Integer Base-2 Exp]
          │                                             ├── Tier 0: Pure Barrel Shift (0 LUTs)
          ▼                                             └── Tier 1: Barrel Shift + 16-LUT Refinement
 [Stage 3: 256-entry Exp LUT]    (8 cycles)             │
          │                                             ▼
          ▼                                    [Stage 3: 24-bit Sequential Restoring Divider]
 [Stage 4: 24-bit Restoring Divider]                    │ (8 elems x 24 cycles = 192 cycles/row)
          │ (192 cycles/row)                            ▼
          ▼                                    [INT8 Normalized Probabilities A[i,j]]
 [Stage 5: Requantize to INT8]   (8 cycles)    
          │                                    * Eliminates Descaling & Requantization Stages
          ▼                                    * Eliminates 256-entry LUT (0 LUTs in Tier 0)
 [INT8 Normalized Probabilities A[i,j]]        * Exactly 128 Cycles Saved per Inference
==============================================================================================
```

---

## ⚡ Cycle-Accurate ModelSim Verification & Benchmark

All division operations in RTL execute sequentially via a **parameterized 24-bit restoring divider FSM** (`restoring_divider.v`). **No un-synthesizable combinational division (`/ sumw`) is used.**

### End-to-End System Regression Results (ModelSim 10.5b)

```text
===================================================================================================================
                          CROSS-ARCHITECTURE HARDWARE TIMING & RESOURCE PROFILING SUMMARY                           
===================================================================================================================
 Softmax Variant        | Softmax Cycles   | Total Cycles     | Latency @ 50MHz | Test Vectors | Cycle Delta 
-------------------------------------------------------------------------------------------------------------------
 Version A (Detour)     |          2008 c |          5688 c |      113.76 us |   6/6 passed | baseline
 Tier 0 (Shift-Only)    |          1880 c |          5560 c |      111.20 us |   6/6 passed | -128 cycles
 Tier 1 (16-LUT Refine) |          1880 c |          5560 c |      111.20 us |   6/6 passed | -128 cycles
-------------------------------------------------------------------------------------------------------------------
 Key Architectural Findings:
   1. Softmax Acceleration: Tier 0 and Tier 1 save 128 clock cycles per inference vs Version A (+128 cycle penalty).
   2. Division Hardware: All 3 variants use 24-bit multi-cycle restoring dividers (24 cycles/elem, NO combinational '/').
   3. Memory/Resource Trade-off:
      - Tier 0: 0 LUTs, 0 DSPs (pure barrel shifter) -> Ideal for ultra-constrained edge FPGA.
      - Tier 1: 16-entry fractional LUT -> High precision with minimal LE footprint.
      - Version A: 256-entry exponential LUT + descaling + requantization stages (heavy resource & cycle overhead).
   4. Test Vector Verification: 18 / 18 Tests Passed (6/6 selected test vectors passed across all 3 variants).
   5. Note: Timing represents RTL-simulated latency at nominal 50 MHz clock; FPGA post-fit timing via Quartus next.
===================================================================================================================
```

---

## 🛠️ Complete On-Chip Dynamic Datapath

The FPGA executes the entire inference pipeline at runtime; only pre-trained model weights are stored in on-chip ROMs:
$$\text{Tokens } [x_0..x_7] \xrightarrow{\text{ROM}} E \xrightarrow{W_Q, W_K, W_V} Q, K, V \xrightarrow{QK^T} S \xrightarrow{\text{Softmax}} A \xrightarrow{A \times V} H \xrightarrow{\text{Mean Pool}} P \xrightarrow{W_{cls}} \text{Logits} \xrightarrow{\text{Argmax}} \text{Intent ID}$$

1. **Embedding Lookup**: 8 tokens $\times$ 32 dimensions fetched from internal table.
2. **Q, K, V Projections**: 8-lane parallel INT8 MAC array computing $Q = E W_Q^T$, $K = E W_K^T$, $V = E W_V^T$.
3. **Score Matrix ($QK^T$)**: Parallel dot products with unified scaling (`>>> 15`).
4. **Softmax Normalization**: Row-wise sequential multi-cycle FSM with 24-bit restoring divider.
5. **Context ($A \times V$)**: Weighted sum over value vectors.
6. **Mean Pooling & Classification**: Sequence dimension reduction and projection to 6 intent logits.
7. **Argmax & Telemetry**: Identification of highest logit; packet emitted over UART (115,200 baud) and displayed on 7-segment LEDs (`HEX0`–`HEX7`).

---

## 📁 Repository Structure

```text
.
├── rtl/                               # Synthesizable Verilog & SystemVerilog RTL
│   ├── transformer_pkg.sv             # Architectural constants (L=8, D=32, LANES=8, CLASSES=6)
│   ├── restoring_divider.v            # Parameterized 24-bit sequential restoring divider
│   ├── softmax_tier0.sv               # Integer-native shift-only base-2 Softmax FSM
│   ├── softmax_tier1.sv               # Integer-native base-2 + 16-entry fractional LUT Softmax FSM
│   ├── softmax_detour_vA.sv           # Conventional fixed-point detour Softmax FSM (256-LUT)
│   ├── int8_mac_array.v               # 8-lane parallel signed INT8 multiply-accumulate array
│   ├── attention_engine.sv            # 11-stage master attention & classification datapath
│   ├── weight_roms.v                  # On-chip parameter storage initialized with hex weights
│   ├── cycle_counter.v                # Hardware inference cycle counter & latch
│   ├── uart_tx.v, uart_rx.v           # 115,200-baud serial telemetry interface
│   └── de2_115_top.sv                 # Top-level module with DE2-115 pinouts & 7-seg displays
├── quartus/                           # Quartus Prime synthesis & fitting project skeleton
│   ├── int8_transformer_de2_115.qpf  # Quartus project revision file
│   ├── int8_transformer_de2_115.qsf  # Cyclone IV device settings (pinout requires verification; see docs/PINOUT_REQUIRED.md)
│   ├── int8_transformer_de2_115.sdc  # 50.0 MHz SDC timing constraints & I/O delays
│   └── mem/                           # Mirrored .hex weight files for standalone compilation
├── tb/                                # Self-checking simulation testbenches
│   ├── tb_full_transformer.sv         # 18-test end-to-end regression across all 3 Softmax modes
│   ├── tb_attention_engine.sv         # Attention datapath integration testbench
│   ├── tb_softmax_tier0.sv            # Tier 0 unit testbench
│   ├── tb_softmax_tier1.sv            # Tier 1 unit testbench
│   └── tb_restoring_divider.v         # 24-bit restoring divider unit testbench
├── mem/                               # Quantized model weights in Verilog Hex format
├── python/                            # PyTorch model training, PTQ, and numerical validation
│   ├── softmax_sim.py                 # Multi-tier Softmax mathematical simulation & error metrics
│   ├── fsc_model.py                   # PyTorch reference Transformer model & quantization
│   └── export_hex.py                  # Weight export script to Verilog hex files
├── benchmark/                         # Hardware roofline model & throughput benchmarks
│   └── roofline_model.py              # Operational intensity, GOPS, and efficiency calculations
├── docs/                              # Implementation notes, pinout reference, test plans
└── scripts/                           # Automated PowerShell execution scripts
    ├── run_sim_modelsim.ps1           # ModelSim compile & regression runner (0 errors, 0 warnings)
    └── run_quartus_compile.ps1        # Automated Quartus map, fit, asm, and sta runner
```

---

## 🚀 Reproduction Instructions

### 1. Run Complete ModelSim Simulation Regression
Requires ModelSim Intel FPGA Edition installed:
```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_sim_modelsim.ps1
```
Expected output:
- Restoring Divider unit test: **PASS**
- Softmax Tier 0 unit test: **PASS**
- Softmax Tier 1 unit test: **PASS**
- Attention Engine integration: **PASS**
- Full Transformer 18-test regression: **18/18 PASS**
- Top-level compilation check: **0 errors, 0 warnings**

### 2. Run Quartus Prime Synthesis for DE2-115
To synthesize and fit the design to the **Cyclone IV EP4CE115**:
- **Option A (GUI)**: Open Quartus Prime $\to$ `File -> Open Project` $\to$ select `quartus/int8_transformer_de2_115.qpf` $\to$ Press <kbd>Ctrl</kbd> + <kbd>L</kbd> to compile.
- **Option B (Command Line)**:
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts/run_quartus_compile.ps1
  ```

### 3. Board Deployment on DE2-115
1. Program `output_files/int8_transformer_de2_115.sof` onto the board via Quartus Programmer.
2. Select Softmax mode via switches:
   - `SW[1:0] = 00`: Tier 0 (Shift-only base-2)
   - `SW[1:0] = 01`: Tier 1 (Base-2 + 16-LUT refinement)
   - `SW[1:0] = 10`: Version A (Conventional fixed-point detour)
3. Select test sentence via `SW[4:2]` (0 to 5).
4. Press `KEY[1]` to trigger inference.
5. Read outputs:
   - `HEX0`: Winning intent ID (0 to 5)
   - `HEX1`: Active Softmax mode
   - `HEX7`-`HEX2`: Hardware latency clock cycles (latched)
   - `UART_TXD`: Telemetry string (`I:<intent> C:<cycles>\r\n`)

---

## 📌 Scientific & Claim Integrity

To maintain absolute academic and engineering honesty during review:
- **Latency**: All numbers reported here represent **RTL-simulated latency at 50 MHz** ($5,560$ cycles = $111.20\ \mu\text{s}$ for Tier 0/1; $5,688$ cycles = $113.76\ \mu\text{s}$ for Version A), not post-fit board measurements.
- **Accuracy**: Demonstrates **6/6 selected test vectors passed across all 3 Softmax variants (18/18 test cases)**, not the complete Fluent Speech Commands dataset.
- **Division**: Verified 24-bit multi-cycle restoring divider (24 cycles/element, 192 divider cycles/row). Zero combinational division in RTL.
