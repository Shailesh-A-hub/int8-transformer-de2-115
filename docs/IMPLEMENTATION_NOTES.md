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

## Do not claim

- ModelSim PASS until the Windows script has actually been run.
- Quartus Fmax until TimeQuest reports it.
- FPGA power until a real measurement is made.
- FSC accuracy until real FSC examples are supplied and evaluated.
- `<0.5%` Tier-1 error until the numerical suite demonstrates it.

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
