# Comprehensive Verification & Test Plan

This document outlines the three-tier verification strategy for the INT8 Transformer Attention Accelerator:
1. **Python Numerical & Algorithmic Validation** (Floating-point baseline vs. fixed-point/integer Softmax)
2. **RTL Cycle-Accurate Simulation** (ModelSim 10.5b testbenches & end-to-end regression)
3. **Quartus Physical & Timing Verification** (Synthesis, Place-and-Route, TimeQuest static timing analysis)

---

## 1. Python Numerical Validation (Post-Training Quantization Reference)

### 1.1 Implementation & Reproduction
The numerical reference model is implemented in [`python/softmax_sim.py`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/python/softmax_sim.py). Teammates can reproduce the reported metrics at any time by executing:

```powershell
# Run the 1,000-vector comparative suite (L=8 tokens per vector)
python python/softmax_sim.py --vectors 1000 --length 8
```

The verified baseline output is logged in [`python_validation_output.txt`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/python_validation_output.txt).

### 1.2 Test Specification & Execution Status

| Test Case | Description | Status | Reference Output |
|---|---|---|---|
| **1,000-Vector Comparative PTQ** | Evaluates 1,000 random integer-logit vectors ($L=8$, domain $[-64, +64]$) comparing FP32 reference against Version A, Tier 0, and Tier 1. Reports Mean Absolute Error (MAE), Maximum Error ($\text{MaxErr}$), KL Divergence, and Rank Inversion %. | ✅ **PASSED** | Tier 0: $\text{MAE}=0.00231$, $\text{MaxErr}=0.00924$<br>Tier 1: $\text{MAE}=0.000246$, $\text{MaxErr}=0.000979$<br>Rank Inversions: **0.000%** across all variants |
| **Restoring Divider Self-Check** | Validates bit-exact restoring division algorithmic model against Python native integer division (`//` and `%`) across varied dividends ($[1, 32767]$) and divisor 7. | ✅ **PASSED** | Self-check: PASS (0 mismatches) |
| **Test Vector Export** | Generates deterministic integer vectors and corresponding Tier 0/Tier 1 output targets into `mem/softmax_vectors.txt` via `--export` flag. | ✅ **PASSED** | Exported to `mem/softmax_vectors.txt` |
| **Full FSC Corpus Evaluation** | End-to-end spoken intent accuracy across the complete 30,000+ Fluent Speech Commands dataset. | ⏳ **FUTURE WORK** | Scope bounded to 6/6 selected validation sentences until full audio tokenization pipeline is linked. |

---

## 2. RTL Simulation & Functional Verification (ModelSim 10.5b)

RTL verification is automated via [`scripts/run_sim_modelsim.ps1`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/scripts/run_sim_modelsim.ps1) using Intel FPGA ModelSim Starter Edition 10.5b. All test results are documented in [`docs/modelsim_transcript.log`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/docs/modelsim_transcript.log).

### 2.1 Sequential Restoring Divider (`tb/tb_restoring_divider.v`)
- **Corner Cases Tested**:
  - Divisor = 1
  - Powers-of-two divisors
  - Large divisors ($2^{24}-1$)
  - Dividend < Divisor (quotient = 0, remainder = dividend)
  - Exact division (remainder = 0)
  - Pseudo-random 24-bit dividend/divisor pairs
- **Status**: ✅ **PASS** (100% quotient and remainder match).

### 2.2 Softmax Unit Testbenches (`tb/tb_softmax_tier0.sv`, `tb/tb_softmax_tier1.sv`)
- **Conditions Tested**:
  - Monotonicity: Larger input logits yield larger or equal probability weights.
  - Max element fidelity: $\text{argmax}(\text{logits}) = \text{argmax}(\text{Softmax output})$.
  - All-equal logits: Output probabilities distribute uniformly ($\approx 127/8 = 15$).
  - Large negative dynamic range: Bounded exp saturation without numerical underflow wrap-around.
  - Zero-sum safety: Multi-cycle divider handles degenerate zero-sum scenarios gracefully.
  - Output range bounding: All probability outputs strictly confined to $[0, 127]$.
- **Status**: ✅ **PASS** (Both Tier 0 and Tier 1 pass all functional edge cases).

### 2.3 Attention Engine & System Integration (`tb/tb_attention_engine.sv`, `tb/tb_full_transformer.sv`)
- **Protocols & Pipelines Tested**:
  - Start/Done handshaking across all sub-modules.
  - Dynamic runtime sequence: Embedding Lookup $\to$ Q/K/V MAC Array $\to$ Scaled $QK^T \ggg 15 \to$ Softmax Row Loop $\to A \times V \ggg 7 \to$ Mean Pooling $\to$ Classifier Logits $\to$ Argmax Winning Intent.
  - Softmax Mode Selection (`SW[1:0]`): `00` (Tier 0), `01` (Tier 1), `10` (Version A).
  - Cycle Counter: Latches exact elapsed cycles per run (5,560 cycles for T0/T1 vs. 5,688 cycles for Version A).
  - UART Telemetry: Verifies ASCII packet framing (`I:<intent_id> C:<cycle_count>\r\n`) at 115,200 baud.
  - Full Intent Regression: 6 representative intent sentences tested across all 3 Softmax variants ($6 \times 3 = 18$ test configurations).
- **Status**: ✅ **18/18 PASS (0 errors, 0 warnings)**.

---

## 3. Quartus Synthesis & Physical Verification Plan (DE2-115)

*Notice: Unlike the verified Python numerical metrics and ModelSim cycle counts, Quartus post-fit hardware metrics are pending synthesis and fitting.*

### 3.1 Synthesis Checklist (`quartus/int8_transformer_de2_115.qpf`)
- [ ] **Pin Assignment Verification**: Populate verified physical pin assignments into `quartus/int8_transformer_de2_115.qsf` using the official Terasic DE2-115 reference manual (see [`docs/PINOUT_REQUIRED.md`](file:///c:/Users/shail/OneDrive/Desktop/Docs/projects%20final%20copies/next%20gen/INT8_Transformer_DE2_115_Implementation/int8_transformer_de2_115/docs/PINOUT_REQUIRED.md)).
- [ ] **Full Compilation**: Execute Analysis & Synthesis, Fitter (Place & Route), TimeQuest Timing Analyzer, and Assembler (`scripts/run_quartus_compile.ps1` or <kbd>Ctrl</kbd> + <kbd>L</kbd>).
- [ ] **Extract Logic Utilization (`.fit.rpt`)**:
  - Total Logic Elements (LEs) and Dedicated Logic Registers.
  - Embedded 9-bit multiplier elements / DSP blocks.
  - Total memory bits / M9K BRAM blocks.
  - *Academic rule*: "Zero LUTs, Zero DSPs" is an architectural property describing the elimination of the 256-entry exponential ROM table and multipliers in the exponentiation datapath; real FPGA LEs are required for FSM control and divider logic.
- [ ] **Extract TimeQuest Timing (`.sta.rpt`)**:
  - Worst-case Slack @ 50.0 MHz nominal clock constraint (`CLOCK_50`).
  - Maximum operating frequency ($F_{\max}$) across Slow 85°C, Slow 0°C, and Fast 0°C corners.
  - True hardware execution time: $T_{\text{exec}} = \frac{\text{Cycles}}{F_{\max}}$.

### 3.2 Physical Board Demonstration
- [ ] Program Cyclone IV `EP4CE115F29C7` via USB-Blaster (`output_files/int8_transformer_de2_115.sof`).
- [ ] Select intent sentence via slide switches `SW[4:2]`.
- [ ] Select Softmax variant via `SW[1:0]`.
- [ ] Trigger inference via pushbutton `KEY[1]`.
- [ ] Verify winning Intent ID on `HEX0` and `LEDR[2:0]`.
- [ ] Verify cycle count on `HEX7`–`HEX2` (5,560 for T0/T1 vs 5,688 for Version A).
- [ ] Capture telemetry packet on PC via UART (115,200 baud, 8-N-1).
