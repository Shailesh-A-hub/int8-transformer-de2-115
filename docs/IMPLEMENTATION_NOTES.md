# Implementation notes

## Scope freeze

The first FPGA milestone is not the full Transformer stack. It is the attention/softmax datapath with deterministic test vectors.

Milestone sequence:

1. Restoring divider
2. Tier 0
3. Tier 1
4. Version A
5. Q/K/V MAC datapath
6. Attention integration
7. Classifier
8. UART telemetry
9. Quartus resource/timing measurement

## Claim boundaries

- ModelSim PASS: Fully verified (18/18 test vectors passed, 0 errors, 0 warnings; see `docs/modelsim_transcript.log`).
- Softmax Numerical Error: Verified via Python PTQ simulation suite (Tier 1 MaxErr < 0.1%, MAE = 0.000246; reproduce via `python python/softmax_sim.py --vectors 1000 --length 8`).
- Do NOT cite "0 LUTs, 0 DSPs" as a Quartus chip resource measurement; that statement refers strictly to the architectural elimination of the 256-entry ROM lookup table and multipliers in the exponentiation datapath. FPGA Logic Elements (LEs) and registers are consumed by the FSM and restoring divider, and post-fit resource counts are pending Quartus compilation.
- Do NOT claim Quartus Fmax until TimeQuest reports it post-fit.
- Do NOT claim FPGA power until a real physical measurement is made.
- Do NOT claim full FSC dataset accuracy (currently 6/6 selected test vectors passed).

## Baseline definition

Version A is deliberately a structural fixed-point model of the conventional dequantize/exp/requantize path. It is not a true FP32 hardware implementation.

This is necessary because the target Cyclone IV does not provide a hard floating-point unit, and the project schedule does not justify building a full FP32 softmax datapath.

## Hardware-first rule

For each runtime input sequence:

- token IDs may arrive from UART;
- embedding lookup occurs on FPGA;
- Q/K/V are generated on FPGA;
- QK^T is generated on FPGA;
- softmax is generated on FPGA;
- attention×V is generated on FPGA;
- classifier and argmax are generated on FPGA.

Only trained model parameters and static lookup tables are prepared offline.
