# Test plan

## Python

- 1000 random integer-logit vectors, L=8.
- Compare FP32, Version A, Tier 0 and Tier 1.
- Report MAE, max error, KL divergence and argmax mismatch.
- Validate restoring division against Python integer division.
- Use actual FSC-derived samples before reporting application accuracy.

## RTL

### Divider
Cases:
- divisor = 1
- powers of two
- large divisor
- dividend < divisor
- exact division
- random vectors

### Softmax
- monotonicity
- max element gets largest/equal probability
- all-equal logits
- large negative spread
- zero-sum safety
- bounded output [0,127]

### Integration
- start/done handshake
- mode selection
- cycle counter
- UART packet framing
