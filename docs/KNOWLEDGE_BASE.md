# Engineering Knowledge Base: INT8 Transformer Attention Accelerator on DE2-115

**Target Hardware**: Terasic DE2-115 Development Board (Intel/Altera Cyclone IV EP4CE115F29C7)  
**Repository**: [https://github.com/Shailesh-A-hub/int8-transformer-de2-115](https://github.com/Shailesh-A-hub/int8-transformer-de2-115)  
**Primary Clock**: 50.0 MHz Nominal Clock (FPGA package pin to be populated from official DE2-115 reference)  
**Current Milestone**: RTL Verified Cycle-Accurate in ModelSim (18/18 Tests Passed) $\to$ Entering Quartus Synthesis Phase  

---

## 1. Project Overview & Research Mission

### 1.1 The Core Problem
Transformers achieve state-of-the-art accuracy across natural language processing and speech intent classification, but standard self-attention relies on floating-point (FP32) arithmetic—most notably inside the **Softmax normalization stage** ($\text{Softmax}(z)_i = \frac{e^{z_i}}{\sum_j e^{z_j}}$).

On resource-constrained edge FPGAs lacking native Floating-Point Units (FPUs) such as the **Cyclone IV EP4CE115**, computing non-linear exponentials and divisions typically forces a **conventional fixed-point detour**:
$$\text{INT8 Attention Scores} \xrightarrow{\text{Descale}} \text{Wider Fixed-Point} \xrightarrow{\text{256-LUT Exp}} \text{Sum} \xrightarrow{\text{Divider}} \text{Requantize} \xrightarrow{\text{INT8 Attention Matrix}}$$

This detour introduces:
1. Significant latency overhead (descaling and requantization pipeline stages).
2. Heavy memory footprint (256-entry exponential tables).
3. DSP/multiplier utilization for scaling operations.

### 1.2 The Research Question
> **Can an integer-native Softmax architecture eliminate the fixed-point detour overhead on a resource-constrained Cyclone IV FPGA, achieving lower latency and hardware resource utilization while preserving classification accuracy?**

### 1.3 Target Application Workload
- **Task**: Edge Spoken Intent Classification (derived from the Fluent Speech Commands dataset).
- **Architecture**: Single-head INT8 Transformer attention datapath.
- **Parameters**:
  - Sequence Length: $L = 8$ tokens.
  - Hidden / Embedding Dimension: $D = 32$.
  - Vocabulary Size: 32 tokens.
  - Target Intent Classes: 6 categories (`turn_on_lights`, `turn_off_lights`, `increase_volume`, `decrease_volume`, `heat_on`, `heat_off`).

---

## 2. Mathematical Framework & The 3 Softmax Architectures

Everything outside Softmax (Embedding lookup, Q/K/V projections, $QK^T$, $A \times V$, Mean Pooling, Classifier, and Argmax) is **strictly identical** across all experiments to guarantee a clean, controlled comparison.

```text
==================================================================================================
                                    SOFTMAX ARCHITECTURE TAXONOMY
==================================================================================================
   Version A (Conventional Detour)       Tier 0 (Integer-Native Shift)    Tier 1 (Integer-Native + 16-LUT)
-------------------------------------   ------------------------------   ---------------------------------
  • Baseline architecture                 • Proposed ultra-lightweight     • Proposed precision-balanced
  • 256-entry Exponential LUT             • Shift-only (No exp-LUT ROM)    • 16-entry Fractional LUT
  • Separate Descaling stage (8 cyc)      • Pure power-of-two shift        • Q4.4 decomposition (q, frac)
  • Separate Requant stage (8 cyc)        • Eliminates descale/requant     • Eliminates descale/requant
  • Multi-cycle Restoring Divider         • Multi-cycle Restoring Divider  • Multi-cycle Restoring Divider
==================================================================================================
*(Note: "Shift-only (No exp-LUT ROM)" refers to the algorithmic exponentiation datapath architecture which requires no lookup ROM tables and no DSP multipliers for exponent calculation. Standard FPGA Logic Elements (LEs) and registers are utilized for FSM control and divider logic; post-fit LE/DSP/BRAM counts are pending Quartus compilation).*
```

### 2.1 Version A: Conventional Fixed-Point Detour (Baseline)
1. **Find Max**: $m = \max_{j}(S_j)$ (8 cycles).
2. **Descale**: $z_j = S_j - m$, bounded to $[-8, 0]$ (8 cycles).
3. **Exp LUT**: Indexes a 256-entry ROM storing $\exp(z)$ in 16-bit precision, accumulating $\sum w_j$ (8 cycles).
4. **Divider**: Sequential division $\frac{w_j \times 127}{\sum w}$ via a 24-bit restoring divider ($8 \times 24 = 192$ cycles).
5. **Requantize**: Clamps raw quotient down to INT8 $[0, 127]$ (8 cycles).
- **Total Softmax Latency**: **2,008 clock cycles** ($251\text{ cycles/row} \times 8\text{ rows}$).

### 2.2 Tier 0 — Integer-Native Base-2 Shift (Proposed)
Exploits the base-2 mathematical property: $e^z = 2^{z \cdot \log_2(e)}$.
1. **Find Max**: $m = \max_{j}(S_j)$ (8 cycles).
2. **Shift Amount**: Linear scale $t = (-z) \times 23$ (where $23/16 \approx 1.4375 \approx \log_2(e)$).
3. **Power-of-Two Barrel Shift**: Computes $w_j = 32768 \gg t[7:4]$, accumulating $\sum w_j$ (8 cycles). **Zero exponential ROM lookup tables required** (an arithmetic barrel shifter replaces the 256-entry table; standard FPGA Logic Elements implement the shifter and FSM control).
4. **Divider**: Feeds $w_j \times 127$ and $\sum w$ into the 24-bit restoring divider ($8 \times 24 = 192$ cycles).
- **Total Softmax Latency**: **1,880 clock cycles** ($235\text{ cycles/row} \times 8\text{ rows}$).
- **Hardware Savings**: Saves **128 cycles** per inference by eliminating the descaling and requantization stages.

### 2.3 Tier 1 — Base-2 Shift + 16-Entry Fractional LUT (Proposed)
Refines Tier 0 by splitting $t$ into integer quotient $q$ and fractional remainder $f$:
$$t = -z \times \log_2(e) \implies 2^{-t} = 2^{-(q + f)} = 2^{-q} \times 2^{-f}$$
1. **Find Max**: $m = \max_{j}(S_j)$ (8 cycles).
2. **Q4.4 Decomposition**: $q = t[7:4]$ (integer shift), $f = t[3:0]$ (4-bit fraction).
3. **16-Entry LUT Refinement**: Reads $2^{-f}$ from a tiny 16-word ROM table:
   ```verilog
   lut[0]=16'hffff; lut[1]=16'hf525; lut[2]=16'heac0; lut[3]=16'he0cc;
   lut[4]=16'hd744; lut[5]=16'hce24; lut[6]=16'hc566; lut[7]=16'hbd08;
   lut[8]=16'hb504; lut[9]=16'had58; lut[10]=16'ha5fe; lut[11]=16'h9ef5;
   lut[12]=16'h9837; lut[13]=16'h91c3; lut[14]=16'h8b95; lut[15]=16'h85aa;
   ```
4. Computes $w_j = \text{lut}[f] \gg q$ and accumulates $\sum w_j$ (8 cycles).
5. **Divider**: Normalizes using the 24-bit restoring divider ($8 \times 24 = 192$ cycles).
- **Total Softmax Latency**: **1,880 clock cycles** ($235\text{ cycles/row} \times 8\text{ rows}$).

---

## 3. Hardware Architecture & RTL Implementation

### 3.1 RTL File Hierarchy

```text
rtl/
├── transformer_pkg.sv      # Architectural parameters (L=8, D=32, LANES=8, CLASSES=6)
├── restoring_divider.v     # Parameterized 24-bit non-restoring/restoring divider FSM
├── softmax_tier0.sv        # Tier 0 sequential FSM (shift-only exponentiation, no exp-LUT ROM, restoring divider)
├── softmax_tier1.sv        # Tier 1 sequential FSM (16-LUT, restoring divider)
├── softmax_detour_vA.sv    # Version A sequential FSM (descale, 256-LUT, requant, divider)
├── int8_mac_array.v        # 8-lane signed INT8 multiplier-accumulator with clear & comb_sum
├── attention_engine.sv     # 11-stage master FSM coordinating full dynamic attention pipeline
├── weight_roms.v           # Parameter storage (pre-loaded from mem/*.hex via $readmemh)
├── cycle_counter.v         # Hardware execution cycle counter with latched output
├── uart_tx.v, uart_rx.v    # 115,200-baud UART transmitter and receiver
└── de2_115_top.sv          # Top-level module with board-facing port bindings & 7-seg decoders
```

### 3.2 Dynamic Runtime Computation vs Static Storage
A common flaw in trivial FPGA AI demos is pre-computing outputs or lookup tables offline. In this accelerator:
- **Offline / Stored in ROMs**: Only pre-trained weight matrices ($W_Q, W_K, W_V, W_{cls}$) and vocabulary embeddings.
- **On-Chip Dynamic Runtime Execution**:
  1. Token ID dispatch $\to$ Embedding vector generation ($8 \times 32$).
  2. Linear projections $Q = EW_Q^T$, $K = EW_K^T$, $V = EW_V^T$ (via 8-lane parallel MAC array).
  3. Attention score computation $S = QK^T \ggg 15$.
  4. Softmax probability matrix $A = \text{Softmax}(S)$ (row-by-row).
  5. Context aggregation $H = AV \ggg 7$.
  6. Mean Pooling over $L=8$ tokens: $P = \frac{1}{8} \sum_{i=0}^7 H_i$.
  7. Classification logits: $\text{Logits} = P W_{cls}^T$.
  8. Argmax detection: winning class ID $\in [0, 5]$.

### 3.3 The Divider Bottleneck Discovery
Initial RTL simulations used Verilog's combinational `/` operator (`w[j] * 127 / sumw`), causing all three architectures to execute in an identical 3,712 cycles. 

**Root Cause**: Simulation evaluated division instantaneously in 1 cycle, hiding hardware latency.  
**Resolution**: Implemented a parameterizable 24-bit sequential restoring divider (`restoring_divider.v`). Each division consumes exactly 24 clock cycles. This exposed the true hardware trade-off: **Version A requires 2,008 Softmax cycles, while Tier 0 and Tier 1 consume 1,880 cycles (saving 128 cycles / 6.8% in Softmax)**.

---

## 4. Current Experimental Results (ModelSim 10.5b)

Simulation executed via `scripts/run_sim_modelsim.ps1` on ModelSim ASE 10.5b.

### 4.1 Cross-Architecture Timing Summary

| Architecture Variant | Softmax FSM Cycles | Total Inference Cycles | Simulated Latency @ 50 MHz | Test Vectors Passed | Cycle Advantage |
|---|---|---|---|---|---|
| **Version A (Detour)** | 2,008 cycles | 5,688 cycles | 113.76 µs | 6/6 selected vectors | Baseline |
| **Tier 0 (Shift-Only)** | **1,880 cycles** | **5,560 cycles** | **111.20 µs** | 6/6 selected vectors | **-128 cycles (-2.25% total, -6.37% Softmax)** |
| **Tier 1 (16-LUT Refinement)** | **1,880 cycles** | **5,560 cycles** | **111.20 µs** | 6/6 selected vectors | **-128 cycles (-2.25% total, -6.37% Softmax)** |

### 4.2 Numerical Error Metrics (Python PTQ Simulation)
Evaluated across 1,000 synthetic attention vectors against 64-bit floating-point baseline:

| Variant | Mean Absolute Error (MAE) | Maximum Error ($\text{MaxErr}$) | KL Divergence | Rank Inversion % |
|---|---|---|---|---|
| **Version A** | 0.100967 | 0.401563 | 0.532291 | 0.00% |
| **Tier 0** | 0.002312 | 0.009236 | 0.016769 | 0.00% |
| **Tier 1** | **0.000246** | **0.000979** | **0.014876** | 0.00% |

*Key Takeaway*: Tier 1 provides nearly **$10\times$ lower numerical error than Tier 0** and over **$400\times$ lower error than Version A**, while requiring only a 16-word ROM and achieving the exact same 1,880-cycle latency as Tier 0.

> [!TIP]
> **Reproduction Command**: Teammates can reproduce these exact MAE/MaxErr/KL figures at any time from the root directory via:
> ```powershell
> python python/softmax_sim.py --vectors 1000 --length 8
> ```
> The reference output is logged in [`python_validation_output.txt`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/python_validation_output.txt). (Full FSC audio tokenization dataset accuracy remains open for future corpus-level benchmark evaluation).

---

## 5. Quartus Prime Synthesis & Physical Verification Plan

### 5.1 Project Setup & QSF Warning
The prepared Quartus project skeleton is located in `quartus/int8_transformer_de2_115.qpf`.
- **Target FPGA**: Cyclone IV E `EP4CE115F29C7`.
- **Settings File**: `quartus/int8_transformer_de2_115.qsf` (**QSF requires verified DE2-115 pin assignments before compilation; see `docs/PINOUT_REQUIRED.md`**).
- **Constraints**: `quartus/int8_transformer_de2_115.sdc` (50 MHz clock constraint on port `CLOCK_50`).

### 5.2 Metrics to Extract from Compilation
To complete the scientific proof, teammates must compile the project in Quartus Prime Lite and record:

1. **Total Logic Elements (LEs)**: Baseline vs Tier 0 vs Tier 1.
2. **Dedicated Logic Registers**.
3. **Embedded multiplier elements / DSP blocks**: Multiplier savings in Tier 0/1.
4. **Total Memory Bits (M9K Blocks)**: BRAM savings from eliminating 256-LUT.
5. **TimeQuest $F_{\max}$**: Theoretical maximum operating frequency across Slow 85°C, Slow 0°C, and Fast 0°C timing corners.
6. **Worst-Case Setup Slack @ 50 MHz**.
7. **True Hardware Latency**: $T_{hw} = \frac{\text{Total Cycles}}{F_{\max}}$.

---

## 6. DE2-115 Board Pinout & Live Demonstration Guide

### 6.1 DE2-115 Pinout Status & Port-to-Function Mapping

> [!IMPORTANT]
> **DE2-115 Pinout Status:** Exact FPGA package pin assignments must be populated from the official Terasic DE2-115 reference/pin-assignment file or an existing verified Quartus template. Do not invent or assume pin numbers (see [PINOUT_REQUIRED.md](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/docs/PINOUT_REQUIRED.md)). The current RTL exposes generic board-facing ports; pin assignment verification is a Quartus integration task.

| RTL Port Name | Target Board Feature | Required Direction | Functional Description |
|---|---|---|---|
| `CLOCK_50` | On-Board Oscillator | Input | 50.0 MHz master clock |
| `KEY[0]` | Pushbutton 0 | Input | Asynchronous active-low reset |
| `KEY[1]` | Pushbutton 1 | Input | Active-low inference trigger (Start pulse) |
| `SW[1:0]` | Slide Switches 1..0 | Input | Softmax Mode selector (`00`: Tier 0, `01`: Tier 1, `10`: Version A) |
| `SW[4:2]` | Slide Switches 4..2 | Input | Demonstration Sentence selector (Sentences 0 to 5) |
| `LEDR[2:0]` | Red LEDs 2..0 | Output | Winning Intent ID binary display (`0` to `5`) |
| `LEDG[0]` | Green LED 0 | Output | Accelerator Busy status indicator |
| `LEDG[1]` | Green LED 1 | Output | Inference Done status pulse |
| `HEX0[6:0]` | 7-Segment Display 0 | Output | Active-low 7-seg display of winning Intent ID digit |
| `HEX1[6:0]` | 7-Segment Display 1 | Output | Active-low 7-seg display of active Softmax Mode (`0`, `1`, `A`) |
| `HEX7-HEX2` | 7-Segment Displays 7..2 | Output | Active-low 7-seg display of latched inference cycle count |
| `UART_TXD` | RS-232 / USB-UART | Output | Serial telemetry output at 115,200 baud (`I:<id> C:<cyc>\r\n`) |
| `UART_RXD` | RS-232 / USB-UART | Input | Serial command input (optional future expansion) |

### 6.2 The 4-Layer Demonstration Strategy
For presentations and judging, avoid relying solely on "turning on an LED":
1. **Layer 1: Application Demo**: Slide switch selects test command $\to$ `KEY[1]` triggers inference $\to$ `HEX0` displays intent ID.
2. **Layer 2: Telemetry Measurement**: Real-time UART packet streamed to PC terminal showing exact cycle counts and latency in microseconds.
3. **Layer 3: Scientific Softmax Comparison**: Toggle `SW[1:0]` between Version A (`10`) and Tier 0 (`00`); show on the 7-segment display that cycle count drops from `5688` (`0x1638`) to `5560` (`0x15B8`), saving 128 cycles.
4. **Layer 4: Hardware Engineering Proof**: Present Quartus post-fit LE, DSP, and BRAM reports proving architectural efficiency.

---

## 7. Strict Academic & Engineering Claim Boundaries

When presenting or writing papers, adhere strictly to these claim boundaries:

| Claim Category | Permitted / Defensible Statement | Prohibited / Invalid Claim |
|---|---|---|
| **Latency** | *"RTL-simulated latency at nominal 50 MHz clock is 5,560 cycles (111.20 µs) for Tier 0/Tier 1 vs 5,688 cycles (113.76 µs) for Version A."* | ❌ *"Measured hardware board latency."* (Requires physical oscilloscope / timer verification). |
| **Accuracy** | *"6/6 selected test vectors passed (18/18 tests passed across the 3 Softmax variants)."* | ❌ *"100% FSC benchmark accuracy."* (Requires full 30,000+ audio/token FSC dataset evaluation). |
| **Speedup** | *"Integer-native Softmax achieves a 1.068x speedup (6.8%) in the Softmax stage and 2.25% end-to-end speedup, saving 128 cycles per inference."* | ❌ *"10x faster Transformer inference."* (Divider dominates execution time). |
| **Division** | *"Normalization executes sequentially on a 24-bit restoring divider (192 divider cycles per attention row) with zero combinational division."* | ❌ *"Zero-overhead Softmax."* |
| **Hardware Resources**| *"Architectural analysis predicts lower LE/memory footprint by removing 256-LUT ROM and scaling multipliers; final numbers pending Quartus post-fit."* | ❌ Claiming specific LE, DSP, or BRAM counts before running Quartus synthesis. |
| **Resource Statement** | *"Tier 0 mathematically eliminates the 256-entry exponential ROM lookup table and multipliers from the exponentiation datapath."* | ❌ Calling '0 LUTs, 0 DSPs' a Quartus resource measurement (the FSM, registers, and sequential divider consume FPGA LEs; post-fit numbers are pending). |

---

## 8. Teammate Handover Package & Immediate Action Items

Recommended reading order for teammates:
1. `docs/KNOWLEDGE_BASE.md` (Main architectural and project specification)
2. `docs/IMPLEMENTATION_NOTES.md` (Engineering rules and scope definitions)
3. `docs/TEST_PLAN.md` (Validation checklist and test vector inventory)
4. `docs/modelsim_transcript.log` (ModelSim 10.5b execution proof)
5. `docs/PINOUT_REQUIRED.md` (DE2-115 pinout requirement warning)

### Immediate Action Checklist:
```text
[ ] Task 1 (Verify Pin Assignments): Import official Terasic DE2-115 pin assignments into quartus/int8_transformer_de2_115.qsf (see docs/PINOUT_REQUIRED.md).
[ ] Task 2 (FPGA Synthesis): Open quartus/int8_transformer_de2_115.qpf in Quartus Prime Lite -> Run Start Compilation (Ctrl+L).
[ ] Task 3 (Timing Analysis): Extract Fmax and Worst-case Setup Slack from TimeQuest report (int8_transformer_de2_115.sta.rpt).
[ ] Task 4 (Resource Utilization): Record LE, Register, DSP, and M9K usage from Fitter report (int8_transformer_de2_115.fit.rpt).
[ ] Task 5 (Board Programming): Connect DE2-115 via USB Blaster -> Program output_files/int8_transformer_de2_115.sof.
[ ] Task 6 (UART Telemetry): Open PuTTY / Serial Monitor at 115,200 baud on COM port -> Capture UART output strings.
```
