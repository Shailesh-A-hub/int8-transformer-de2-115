# ==============================================================================
# SDC Timing Constraints for INT8 Transformer Accelerator on DE2-115
# Target FPGA: Cyclone IV E EP4CE115F29C7
# ==============================================================================

# 50 MHz On-Board Oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# Automatically calculate clock uncertainty
derive_clock_uncertainty

# Constrain Inputs (relative to CLOCK_50)
set_input_delay -clock CLOCK_50 -max 3.000 [get_ports {KEY[*] SW[*] UART_RXD}]
set_input_delay -clock CLOCK_50 -min 0.500 [get_ports {KEY[*] SW[*] UART_RXD}]

# Constrain Outputs (relative to CLOCK_50)
set_output_delay -clock CLOCK_50 -max 3.000 [get_ports {LEDR[*] LEDG[*] HEX*[*] UART_TXD}]
set_output_delay -clock CLOCK_50 -min 0.500 [get_ports {LEDR[*] LEDG[*] HEX*[*] UART_TXD}]

# False paths for asynchronous reset push button
set_false_path -from [get_ports {KEY[0]}]
