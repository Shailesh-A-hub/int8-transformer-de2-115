`timescale 1ns/1ps
// =============================================================================
// uart_rx.v  --  115200-baud UART Receiver for DE2-115 (50 MHz clock)
// Receives one byte at a time; asserts rx_valid for one clock when done.
// =============================================================================
module uart_rx #(
    parameter CLK_HZ = 50000000,   // 50 MHz
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // Serial RX line (idle HIGH)
    output reg  [7:0] rx_data,
    output reg        rx_valid     // Pulses HIGH for 1 clock when byte ready
);
    // Timing
    localparam [15:0] CLKS_PER_BIT = CLK_HZ / BAUD;   // 434
    localparam [15:0] HALF_BIT     = CLKS_PER_BIT / 2; // 217

    // State encoding
    localparam [1:0] IDLE  = 2'd0,
                     START = 2'd1,
                     DATA  = 2'd2,
                     STOP  = 2'd3;

    reg [1:0] state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    // 2-FF metastability synchronizer
    reg rx_s1, rx_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else        begin rx_s1 <= rx;    rx_s2 <= rx_s1; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            clk_cnt   <= 16'd0;
            bit_idx   <= 3'd0;
            shift_reg <= 8'd0;
            rx_data   <= 8'd0;
            rx_valid  <= 1'b0;
        end else begin
            rx_valid <= 1'b0; // default: de-assert each clock
            case (state)
                // ---- IDLE: wait for falling edge (start bit) ----
                IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (!rx_s2)        // Line went LOW -> possible start bit
                        state <= START;
                end

                // ---- START: sample at mid-point of start bit ----
                START: begin
                    if (clk_cnt == HALF_BIT) begin
                        clk_cnt <= 16'd0;
                        if (!rx_s2)    // Still LOW at midpoint -> valid start
                            state <= DATA;
                        else
                            state <= IDLE; // Glitch, ignore
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                // ---- DATA: sample 8 bits, LSB first ----
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 16'd1) begin
                        clk_cnt              <= 16'd0;
                        shift_reg[bit_idx]   <= rx_s2;
                        if (bit_idx == 3'd7) begin
                            state   <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                // ---- STOP: wait one stop bit, then output byte ----
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 16'd1) begin
                        clk_cnt  <= 16'd0;
                        state    <= IDLE;
                        rx_data  <= shift_reg;
                        rx_valid <= 1'b1;  // One-clock pulse
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
