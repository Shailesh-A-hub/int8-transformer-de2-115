`timescale 1ns/1ps

// =============================================================================
// uart_telemetry.v - Interactive UART Control & Hardware Telemetry Reporter
// Supports interactive commands, single-run telemetry, and automated
// side-by-side benchmarking of Tier 0 vs. Version A on DE2-115.
// =============================================================================
module uart_telemetry #(
    parameter CLK_HZ = 50000000,
    parameter BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART Hardware Ports
    input  wire        uart_rxd,
    output wire        uart_txd,

    // Hardware Controls (Switches / Buttons from DE2-115)
    input  wire [1:0]  sw_mode,
    input  wire [2:0]  sw_sentence,
    input  wire        hw_start_pulse,

    // Accelerator Core Interface
    output reg         engine_start,
    output reg  [1:0]  eff_mode,
    output reg  [2:0]  eff_sentence,
    input  wire        engine_busy,
    input  wire        engine_done,
    input  wire [2:0]  intent_id,
    input  wire [31:0] softmax_cycles,
    input  wire [31:0] total_cycles,
    output reg  [63:0] custom_tokens,
    output reg         custom_token_active
);

    // -------------------------------------------------------------
    // 1. UART RX & TX Transceiver Submodules
    // -------------------------------------------------------------
    wire [7:0] rx_byte;
    wire       rx_valid;
    reg        tx_start;
    reg  [7:0] tx_byte;
    wire       tx_busy;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(uart_rxd),
        .rx_data(rx_byte),
        .rx_valid(rx_valid)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .start(tx_start),
        .data(tx_byte),
        .tx(uart_txd),
        .busy(tx_busy)
    );

    // -------------------------------------------------------------
    // 2. Binary to BCD Converters for Decimal ASCII Reporting
    // -------------------------------------------------------------
    reg         bcd_t0_start, bcd_va_start;
    wire        bcd_t0_done, bcd_va_done;
    reg  [15:0] bcd_t0_tot_in, bcd_t0_sm_in;
    reg  [15:0] bcd_va_tot_in, bcd_va_sm_in;

    wire [3:0] d4_t0_tot, d3_t0_tot, d2_t0_tot, d1_t0_tot, d0_t0_tot;
    wire [3:0] d4_t0_sm,  d3_t0_sm,  d2_t0_sm,  d1_t0_sm,  d0_t0_sm;
    wire [3:0] d4_va_tot, d3_va_tot, d2_va_tot, d1_va_tot, d0_va_tot;
    wire [3:0] d4_va_sm,  d3_va_sm,  d2_va_sm,  d1_va_sm,  d0_va_sm;

    bin2bcd16 u_bcd_t0_tot (
        .clk(clk), .rst_n(rst_n), .start(bcd_t0_start), .bin(bcd_t0_tot_in),
        .done(bcd_t0_done), .busy(), .d4(d4_t0_tot), .d3(d3_t0_tot), .d2(d2_t0_tot), .d1(d1_t0_tot), .d0(d0_t0_tot)
    );

    bin2bcd16 u_bcd_t0_sm (
        .clk(clk), .rst_n(rst_n), .start(bcd_t0_start), .bin(bcd_t0_sm_in),
        .done(), .busy(), .d4(d4_t0_sm), .d3(d3_t0_sm), .d2(d2_t0_sm), .d1(d1_t0_sm), .d0(d0_t0_sm)
    );

    bin2bcd16 u_bcd_va_tot (
        .clk(clk), .rst_n(rst_n), .start(bcd_va_start), .bin(bcd_va_tot_in),
        .done(bcd_va_done), .busy(), .d4(d4_va_tot), .d3(d3_va_tot), .d2(d2_va_tot), .d1(d1_va_tot), .d0(d0_va_tot)
    );

    bin2bcd16 u_bcd_va_sm (
        .clk(clk), .rst_n(rst_n), .start(bcd_va_start), .bin(bcd_va_sm_in),
        .done(), .busy(), .d4(d4_va_sm), .d3(d3_va_sm), .d2(d2_va_sm), .d1(d1_va_sm), .d0(d0_va_sm)
    );

    // Delta BCD (Difference between Version A and Tier 0)
    reg         bcd_delta_start;
    reg  [15:0] bcd_delta_in;
    wire [3:0]  d4_del, d3_del, d2_del, d1_del, d0_del;

    bin2bcd16 u_bcd_delta (
        .clk(clk), .rst_n(rst_n), .start(bcd_delta_start), .bin(bcd_delta_in),
        .done(), .busy(), .d4(d4_del), .d3(d3_del), .d2(d2_del), .d1(d1_del), .d0(d0_del)
    );

    // -------------------------------------------------------------
    // 3. Control & Coordination FSM
    // -------------------------------------------------------------
    localparam CTRL_IDLE       = 3'd0;
    localparam CTRL_BENCH_T0   = 3'd1;
    localparam CTRL_BENCH_WAIT = 3'd2;
    localparam CTRL_BENCH_VA   = 3'd3;
    localparam CTRL_CONVERT    = 3'd4;
    localparam CTRL_TRANSMIT   = 3'd5;
    localparam CTRL_RX_PAYLOAD = 3'd6;
    localparam CTRL_BCD_WAIT   = 3'd7;

    reg [2:0] ctrl_state;
    reg [3:0] rx_payload_cnt;
    reg [1:0] rx_custom_mode;
    reg [1:0] msg_type; // 0: Banner/Help, 1: Single Run Result, 2: Benchmark Report
    reg [2:0] latched_intent;
    reg [1:0] latched_mode;
    reg [2:0] latched_sentence;
    reg [7:0] tx_char_rom [0:383];
    reg [8:0] tx_len;
    reg [8:0] tx_idx;
    reg       tx_in_progress;

    // Latched Benchmark cycle measurements
    reg [15:0] bench_t0_tot, bench_t0_sm;
    reg [15:0] bench_va_tot, bench_va_sm;

    // Detect switch changes
    reg [1:0] sw_mode_prev;
    reg [2:0] sw_sent_prev;

    // Power-on banner flag
    reg boot_banner_sent;

    // Helper to format an ASCII digit from 4-bit nibble
    function [7:0] to_ascii(input [3:0] hex);
        to_ascii = 8'h30 + {4'd0, hex};
    endfunction

    integer idx_fill;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_state       <= CTRL_IDLE;
            engine_start     <= 1'b0;
            eff_mode         <= 2'b00;
            eff_sentence     <= 3'd0;
            sw_mode_prev     <= 2'b00;
            sw_sent_prev     <= 3'd0;
            boot_banner_sent <= 1'b0;
            msg_type         <= 2'd0;
            latched_intent   <= 3'd0;
            latched_mode     <= 2'b00;
            latched_sentence <= 3'd0;
            bcd_t0_start     <= 1'b0;
            bcd_va_start     <= 1'b0;
            bcd_delta_start  <= 1'b0;
            bcd_t0_tot_in    <= 16'd0;
            bcd_t0_sm_in     <= 16'd0;
            bcd_va_tot_in    <= 16'd0;
            bcd_va_sm_in     <= 16'd0;
            bcd_delta_in     <= 16'd0;
            bench_t0_tot     <= 16'd0;
            bench_t0_sm      <= 16'd0;
            bench_va_tot        <= 16'd0;
            bench_va_sm         <= 16'd0;
            tx_start            <= 1'b0;
            tx_byte             <= 8'd0;
            tx_idx              <= 9'd0;
            tx_len              <= 9'd0;
            tx_in_progress      <= 1'b0;
            custom_tokens       <= 64'd0;
            custom_token_active <= 1'b0;
            rx_payload_cnt      <= 4'd0;
            rx_custom_mode      <= 2'b00;
        end else begin
            engine_start    <= 1'b0;
            tx_start        <= 1'b0;
            bcd_t0_start    <= 1'b0;
            bcd_va_start    <= 1'b0;
            bcd_delta_start <= 1'b0;

            // Track physical switches when changed by user
            if (sw_mode != sw_mode_prev) begin
                sw_mode_prev <= sw_mode;
                eff_mode     <= sw_mode;
                // Keep custom_token_active so user can toggle tiers for their typed sentence!
            end
            if (sw_sentence != sw_sent_prev) begin
                sw_sent_prev        <= sw_sentence;
                eff_sentence        <= sw_sentence;
                custom_token_active <= 1'b0; // Revert to preloaded sentences
            end

            // Main Telemetry & Control FSM
            case (ctrl_state)
                // -------------------------------------------------------------
                // IDLE: Listen for UART RX commands, hardware triggers, or boot
                // -------------------------------------------------------------
                CTRL_IDLE: begin
                    if (!boot_banner_sent) begin
                        // Transmit boot greeting & help on startup
                        boot_banner_sent <= 1'b1;
                        msg_type         <= 2'd0;
                        ctrl_state       <= CTRL_CONVERT;
                    end else if (rx_valid) begin
                        case (rx_byte)
                            "0", "t", "T": begin
                                // Select Tier 0 and trigger
                                eff_mode     <= 2'b00;
                                engine_start <= 1'b1;
                            end
                            "1": begin
                                // Select Tier 1 and trigger
                                eff_mode     <= 2'b01;
                                engine_start <= 1'b1;
                            end
                            "2", "a", "A": begin
                                // Select Version A and trigger
                                eff_mode     <= 2'b10;
                                engine_start <= 1'b1;
                            end
                            "s", "S": begin
                                // Cycle sentence 0..5
                                if (eff_sentence == 3'd5) eff_sentence <= 3'd0;
                                else eff_sentence <= eff_sentence + 3'd1;
                                engine_start <= 1'b1;
                            end
                            "b", "B": begin
                                // Start automated benchmark comparison (Tier 0 vs Version A)
                                eff_mode     <= 2'b00; // Run Tier 0 first
                                engine_start <= 1'b1;
                                ctrl_state   <= CTRL_BENCH_T0;
                            end
                            "r", "R": begin
                                rx_payload_cnt <= 4'd0;
                                ctrl_state     <= CTRL_RX_PAYLOAD;
                            end
                            "h", "H", "?": begin
                                msg_type   <= 2'd0; // Re-transmit Help Banner
                                ctrl_state <= CTRL_CONVERT;
                            end
                            default: ;
                        endcase
                    end else if (hw_start_pulse) begin
                        // External trigger (pushbutton / switch change / powerup pulse)
                        engine_start <= 1'b1;
                    end

                    // Catch single-run completion (outside of benchmark sequence)
                    if (engine_done && ctrl_state == CTRL_IDLE) begin
                        latched_intent   <= intent_id;
                        latched_mode     <= eff_mode;
                        latched_sentence <= eff_sentence;
                        bcd_t0_tot_in    <= total_cycles[15:0];
                        bcd_t0_sm_in     <= softmax_cycles[15:0];
                        bcd_t0_start     <= 1'b1;
                        msg_type         <= 2'd1; // Single Run Result
                        ctrl_state       <= CTRL_BCD_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // Custom Sentence Payload: Byte 0=Mode, Bytes 1..8=8 Token IDs
                // -------------------------------------------------------------
                CTRL_RX_PAYLOAD: begin
                    if (rx_valid) begin
                        if (rx_payload_cnt == 4'd0) begin
                            rx_custom_mode <= rx_byte[1:0];
                            rx_payload_cnt <= 4'd1;
                        end else begin
                            case (rx_payload_cnt)
                                4'd1: custom_tokens[7:0]   <= rx_byte;
                                4'd2: custom_tokens[15:8]  <= rx_byte;
                                4'd3: custom_tokens[23:16] <= rx_byte;
                                4'd4: custom_tokens[31:24] <= rx_byte;
                                4'd5: custom_tokens[39:32] <= rx_byte;
                                4'd6: custom_tokens[47:40] <= rx_byte;
                                4'd7: custom_tokens[55:48] <= rx_byte;
                                4'd8: custom_tokens[63:56] <= rx_byte;
                            endcase
                            if (rx_payload_cnt == 4'd8) begin
                                eff_mode            <= rx_custom_mode;
                                custom_token_active <= 1'b1;
                                engine_start        <= 1'b1;
                                ctrl_state          <= CTRL_IDLE;
                            end else begin
                                rx_payload_cnt <= rx_payload_cnt + 4'd1;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // Benchmark Sequence: Step 1 - Wait for Tier 0
                // -------------------------------------------------------------
                CTRL_BENCH_T0: begin
                    if (engine_done) begin
                        bench_t0_tot <= total_cycles[15:0];
                        bench_t0_sm  <= softmax_cycles[15:0];
                        ctrl_state   <= CTRL_BENCH_WAIT;
                    end
                end

                CTRL_BENCH_WAIT: begin
                    // Brief spacing, then launch Version A
                    eff_mode     <= 2'b10; // Version A detour
                    engine_start <= 1'b1;
                    ctrl_state   <= CTRL_BENCH_VA;
                end

                // -------------------------------------------------------------
                // Benchmark Sequence: Step 2 - Wait for Version A
                // -------------------------------------------------------------
                CTRL_BENCH_VA: begin
                    if (engine_done) begin
                        bench_va_tot <= total_cycles[15:0];
                        bench_va_sm  <= softmax_cycles[15:0];

                        // Convert all metrics to BCD
                        bcd_t0_tot_in   <= bench_t0_tot;
                        bcd_t0_sm_in    <= bench_t0_sm;
                        bcd_t0_start    <= 1'b1;

                        bcd_va_tot_in   <= total_cycles[15:0];
                        bcd_va_sm_in    <= softmax_cycles[15:0];
                        bcd_va_start    <= 1'b1;

                        bcd_delta_in    <= total_cycles[15:0] - bench_t0_tot;
                        bcd_delta_start <= 1'b1;

                        msg_type   <= 2'd2; // Benchmark Report
                        ctrl_state <= CTRL_BCD_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // BCD Wait: Wait for 16-cycle Double-Dabble converters to complete
                // -------------------------------------------------------------
                CTRL_BCD_WAIT: begin
                    if (msg_type == 2'd2) begin
                        if (bcd_va_done)
                            ctrl_state <= CTRL_CONVERT;
                    end else begin
                        if (bcd_t0_done)
                            ctrl_state <= CTRL_CONVERT;
                    end
                end

                // -------------------------------------------------------------
                // Build formatted message buffer for transmission
                // -------------------------------------------------------------
                CTRL_CONVERT: begin
                    // Build the ASCII character array for transmission
                    tx_idx         <= 9'd0;
                    tx_in_progress <= 1'b1;

                    case (msg_type)
                        // Message 0: Boot & Help Banner
                        2'd0: begin
                            tx_char_rom[0]  <= 8'h0D; tx_char_rom[1]  <= 8'h0A;
                            tx_char_rom[2]  <= "=";  tx_char_rom[3]  <= "=";  tx_char_rom[4]  <= "=";
                            tx_char_rom[5]  <= "=";  tx_char_rom[6]  <= " ";  tx_char_rom[7]  <= "I";
                            tx_char_rom[8]  <= "N";  tx_char_rom[9]  <= "T";  tx_char_rom[10] <= "8";
                            tx_char_rom[11] <= " ";  tx_char_rom[12] <= "T";  tx_char_rom[13] <= "R";
                            tx_char_rom[14] <= "A";  tx_char_rom[15] <= "N";  tx_char_rom[16] <= "S";
                            tx_char_rom[17] <= "F";  tx_char_rom[18] <= "O";  tx_char_rom[19] <= "R";
                            tx_char_rom[20] <= "M";  tx_char_rom[21] <= "E";  tx_char_rom[22] <= "R";
                            tx_char_rom[23] <= " ";  tx_char_rom[24] <= "D";  tx_char_rom[25] <= "E";
                            tx_char_rom[26] <= "2";  tx_char_rom[27] <= "-";  tx_char_rom[28] <= "1";
                            tx_char_rom[29] <= "1";  tx_char_rom[30] <= "5";  tx_char_rom[31] <= " ";
                            tx_char_rom[32] <= "=";  tx_char_rom[33] <= "=";  tx_char_rom[34] <= "=";
                            tx_char_rom[35] <= "=";  tx_char_rom[36] <= 8'h0D; tx_char_rom[37] <= 8'h0A;
                            tx_char_rom[38] <= "C";  tx_char_rom[39] <= "m";  tx_char_rom[40] <= "d";
                            tx_char_rom[41] <= "s";  tx_char_rom[42] <= ":";  tx_char_rom[43] <= " ";
                            tx_char_rom[44] <= "[";  tx_char_rom[45] <= "0";  tx_char_rom[46] <= "]";
                            tx_char_rom[47] <= "T";  tx_char_rom[48] <= "i";  tx_char_rom[49] <= "e";
                            tx_char_rom[50] <= "r";  tx_char_rom[51] <= "0";  tx_char_rom[52] <= " ";
                            tx_char_rom[53] <= "[";  tx_char_rom[54] <= "1";  tx_char_rom[55] <= "]";
                            tx_char_rom[56] <= "T";  tx_char_rom[57] <= "i";  tx_char_rom[58] <= "e";
                            tx_char_rom[59] <= "r";  tx_char_rom[60] <= "1";  tx_char_rom[61] <= " ";
                            tx_char_rom[62] <= "[";  tx_char_rom[63] <= "a";  tx_char_rom[64] <= "]";
                            tx_char_rom[65] <= "V";  tx_char_rom[66] <= "e";  tx_char_rom[67] <= "r";
                            tx_char_rom[68] <= "s";  tx_char_rom[69] <= "i";  tx_char_rom[70] <= "o";
                            tx_char_rom[71] <= "n";  tx_char_rom[72] <= "A";  tx_char_rom[73] <= " ";
                            tx_char_rom[74] <= "[";  tx_char_rom[75] <= "b";  tx_char_rom[76] <= "]";
                            tx_char_rom[77] <= "B";  tx_char_rom[78] <= "e";  tx_char_rom[79] <= "n";
                            tx_char_rom[80] <= "c";  tx_char_rom[81] <= "h";  tx_char_rom[82] <= "m";
                            tx_char_rom[83] <= "a";  tx_char_rom[84] <= "r";  tx_char_rom[85] <= "k";
                            tx_char_rom[86] <= 8'h0D; tx_char_rom[87] <= 8'h0A;
                            tx_len <= 9'd88;
                        end

                        // Message 1: Single Run Result
                        2'd1: begin
                            tx_char_rom[0]  <= 8'h0D; tx_char_rom[1]  <= 8'h0A;
                            tx_char_rom[2]  <= "[";  tx_char_rom[3]  <= "R";  tx_char_rom[4]  <= "E";
                            tx_char_rom[5]  <= "S";  tx_char_rom[6]  <= "U";  tx_char_rom[7]  <= "L";
                            tx_char_rom[8]  <= "T";  tx_char_rom[9]  <= "]";  tx_char_rom[10] <= " ";
                            tx_char_rom[11] <= "M";  tx_char_rom[12] <= "o";  tx_char_rom[13] <= "d";
                            tx_char_rom[14] <= "e";  tx_char_rom[15] <= ":";  tx_char_rom[16] <= " ";

                            // Mode name
                            if (latched_mode == 2'b00) begin
                                tx_char_rom[17] <= "T"; tx_char_rom[18] <= "i"; tx_char_rom[19] <= "e";
                                tx_char_rom[20] <= "r"; tx_char_rom[21] <= "0"; tx_char_rom[22] <= " ";
                                tx_char_rom[23] <= " "; tx_char_rom[24] <= " "; tx_char_rom[25] <= " ";
                            end else if (latched_mode == 2'b01) begin
                                tx_char_rom[17] <= "T"; tx_char_rom[18] <= "i"; tx_char_rom[19] <= "e";
                                tx_char_rom[20] <= "r"; tx_char_rom[21] <= "1"; tx_char_rom[22] <= " ";
                                tx_char_rom[23] <= " "; tx_char_rom[24] <= " "; tx_char_rom[25] <= " ";
                            end else begin
                                tx_char_rom[17] <= "V"; tx_char_rom[18] <= "e"; tx_char_rom[19] <= "r";
                                tx_char_rom[20] <= "s"; tx_char_rom[21] <= "i"; tx_char_rom[22] <= "o";
                                tx_char_rom[23] <= "n"; tx_char_rom[24] <= "A"; tx_char_rom[25] <= " ";
                            end

                            tx_char_rom[26] <= "|"; tx_char_rom[27] <= " ";
                            tx_char_rom[28] <= "S"; tx_char_rom[29] <= "e"; tx_char_rom[30] <= "n";
                            tx_char_rom[31] <= "t"; tx_char_rom[32] <= ":"; tx_char_rom[33] <= " ";
                            tx_char_rom[34] <= custom_token_active ? "C" : to_ascii({1'b0, latched_sentence});
                            tx_char_rom[35] <= " "; tx_char_rom[36] <= "|"; tx_char_rom[37] <= " ";
                            tx_char_rom[38] <= "I"; tx_char_rom[39] <= "n"; tx_char_rom[40] <= "t";
                            tx_char_rom[41] <= "e"; tx_char_rom[42] <= "n"; tx_char_rom[43] <= "t";
                            tx_char_rom[44] <= ":"; tx_char_rom[45] <= " ";
                            tx_char_rom[46] <= to_ascii({1'b0, latched_intent});
                            tx_char_rom[47] <= " "; tx_char_rom[48] <= "|"; tx_char_rom[49] <= " ";
                            tx_char_rom[50] <= "S"; tx_char_rom[51] <= "o"; tx_char_rom[52] <= "f";
                            tx_char_rom[53] <= "t"; tx_char_rom[54] <= "m"; tx_char_rom[55] <= "a";
                            tx_char_rom[56] <= "x"; tx_char_rom[57] <= ":"; tx_char_rom[58] <= " ";
                            tx_char_rom[59] <= to_ascii(d3_t0_sm);
                            tx_char_rom[60] <= to_ascii(d2_t0_sm);
                            tx_char_rom[61] <= to_ascii(d1_t0_sm);
                            tx_char_rom[62] <= to_ascii(d0_t0_sm);
                            tx_char_rom[63] <= " "; tx_char_rom[64] <= "|"; tx_char_rom[65] <= " ";
                            tx_char_rom[66] <= "T"; tx_char_rom[67] <= "o"; tx_char_rom[68] <= "t";
                            tx_char_rom[69] <= "a"; tx_char_rom[70] <= "l"; tx_char_rom[71] <= ":";
                            tx_char_rom[72] <= " ";
                            tx_char_rom[73] <= to_ascii(d3_t0_tot);
                            tx_char_rom[74] <= to_ascii(d2_t0_tot);
                            tx_char_rom[75] <= to_ascii(d1_t0_tot);
                            tx_char_rom[76] <= to_ascii(d0_t0_tot);
                            tx_char_rom[77] <= " "; tx_char_rom[78] <= "c"; tx_char_rom[79] <= "y";
                            tx_char_rom[80] <= "c"; tx_char_rom[81] <= 8'h0D; tx_char_rom[82] <= 8'h0A;
                            tx_len <= 9'd83;
                        end

                        // Message 2: Side-by-Side Benchmark Report (Tier 0 vs. Version A)
                        2'd2: begin
                            tx_char_rom[0]   <= 8'h0D; tx_char_rom[1]   <= 8'h0A;
                            tx_char_rom[2]   <= "=";  tx_char_rom[3]   <= "=";  tx_char_rom[4]   <= "=";
                            tx_char_rom[5]   <= "=";  tx_char_rom[6]   <= "=";  tx_char_rom[7]   <= "=";
                            tx_char_rom[8]   <= "=";  tx_char_rom[9]   <= "=";  tx_char_rom[10]  <= "=";
                            tx_char_rom[11]  <= "=";  tx_char_rom[12]  <= "=";  tx_char_rom[13]  <= "=";
                            tx_char_rom[14]  <= "=";  tx_char_rom[15]  <= "=";  tx_char_rom[16]  <= "=";
                            tx_char_rom[17]  <= "=";  tx_char_rom[18]  <= "=";  tx_char_rom[19]  <= "=";
                            tx_char_rom[20]  <= "=";  tx_char_rom[21]  <= "=";  tx_char_rom[22]  <= "=";
                            tx_char_rom[23]  <= "=";  tx_char_rom[24]  <= "=";  tx_char_rom[25]  <= "=";
                            tx_char_rom[26]  <= "=";  tx_char_rom[27]  <= "=";  tx_char_rom[28]  <= "=";
                            tx_char_rom[29]  <= "=";  tx_char_rom[30]  <= "=";  tx_char_rom[31]  <= "=";
                            tx_char_rom[32]  <= "=";  tx_char_rom[33]  <= "=";  tx_char_rom[34]  <= "=";
                            tx_char_rom[35]  <= "=";  tx_char_rom[36]  <= "=";  tx_char_rom[37]  <= "=";
                            tx_char_rom[38]  <= "=";  tx_char_rom[39]  <= "=";  tx_char_rom[40]  <= "=";
                            tx_char_rom[41]  <= "=";  tx_char_rom[42]  <= "=";  tx_char_rom[43]  <= "=";
                            tx_char_rom[44]  <= "=";  tx_char_rom[45]  <= "=";  tx_char_rom[46]  <= "=";
                            tx_char_rom[47]  <= "=";  tx_char_rom[48]  <= "=";  tx_char_rom[49]  <= 8'h0D;
                            tx_char_rom[50]  <= 8'h0A;
                            tx_char_rom[51]  <= " ";  tx_char_rom[52]  <= " ";  tx_char_rom[53]  <= "I";
                            tx_char_rom[54]  <= "N";  tx_char_rom[55]  <= "T";  tx_char_rom[56]  <= "8";
                            tx_char_rom[57]  <= " ";  tx_char_rom[58]  <= "H";  tx_char_rom[59]  <= "A";
                            tx_char_rom[60]  <= "R";  tx_char_rom[61]  <= "D";  tx_char_rom[62]  <= "W";
                            tx_char_rom[63]  <= "A";  tx_char_rom[64]  <= "R";  tx_char_rom[65]  <= "E";
                            tx_char_rom[66]  <= " ";  tx_char_rom[67]  <= "C";  tx_char_rom[68]  <= "Y";
                            tx_char_rom[69]  <= "C";  tx_char_rom[70]  <= "L";  tx_char_rom[71]  <= "E";
                            tx_char_rom[72]  <= " ";  tx_char_rom[73]  <= "B";  tx_char_rom[74]  <= "E";
                            tx_char_rom[75]  <= "N";  tx_char_rom[76]  <= "C";  tx_char_rom[77]  <= "H";
                            tx_char_rom[78]  <= "M";  tx_char_rom[79]  <= "A";  tx_char_rom[80]  <= "R";
                            tx_char_rom[81]  <= "K";  tx_char_rom[82]  <= 8'h0D; tx_char_rom[83]  <= 8'h0A;
                            tx_char_rom[84]  <= "=";  tx_char_rom[85]  <= "=";  tx_char_rom[86]  <= "=";
                            tx_char_rom[87]  <= "=";  tx_char_rom[88]  <= "=";  tx_char_rom[89]  <= "=";
                            tx_char_rom[90]  <= "=";  tx_char_rom[91]  <= "=";  tx_char_rom[92]  <= "=";
                            tx_char_rom[93]  <= "=";  tx_char_rom[94]  <= "=";  tx_char_rom[95]  <= "=";
                            tx_char_rom[96]  <= "=";  tx_char_rom[97]  <= "=";  tx_char_rom[98]  <= "=";
                            tx_char_rom[99]  <= "=";  tx_char_rom[100] <= "=";  tx_char_rom[101] <= "=";
                            tx_char_rom[102] <= "=";  tx_char_rom[103] <= "=";  tx_char_rom[104] <= "=";
                            tx_char_rom[105] <= "=";  tx_char_rom[106] <= "=";  tx_char_rom[107] <= "=";
                            tx_char_rom[108] <= "=";  tx_char_rom[109] <= "=";  tx_char_rom[110] <= "=";
                            tx_char_rom[111] <= "=";  tx_char_rom[112] <= "=";  tx_char_rom[113] <= "=";
                            tx_char_rom[114] <= "=";  tx_char_rom[115] <= "=";  tx_char_rom[116] <= "=";
                            tx_char_rom[117] <= "=";  tx_char_rom[118] <= "=";  tx_char_rom[119] <= "=";
                            tx_char_rom[120] <= "=";  tx_char_rom[121] <= "=";  tx_char_rom[122] <= "=";
                            tx_char_rom[123] <= "=";  tx_char_rom[124] <= "=";  tx_char_rom[125] <= "=";
                            tx_char_rom[126] <= "=";  tx_char_rom[127] <= "=";  tx_char_rom[128] <= "=";
                            tx_char_rom[129] <= "=";  tx_char_rom[130] <= "=";  tx_char_rom[131] <= 8'h0D;
                            tx_char_rom[132] <= 8'h0A;

                            // Line 1: Tier 0
                            tx_char_rom[133] <= " ";  tx_char_rom[134] <= " ";  tx_char_rom[135] <= "T";
                            tx_char_rom[136] <= "i";  tx_char_rom[137] <= "e";  tx_char_rom[138] <= "r";
                            tx_char_rom[139] <= " ";  tx_char_rom[140] <= "0";  tx_char_rom[141] <= " ";
                            tx_char_rom[142] <= ":";  tx_char_rom[143] <= " ";  tx_char_rom[144] <= "T";
                            tx_char_rom[145] <= "o";  tx_char_rom[146] <= "t";  tx_char_rom[147] <= "a";
                            tx_char_rom[148] <= "l";  tx_char_rom[149] <= "=";  tx_char_rom[150] <= to_ascii(d3_t0_tot);
                            tx_char_rom[151] <= to_ascii(d2_t0_tot); tx_char_rom[152] <= to_ascii(d1_t0_tot);
                            tx_char_rom[153] <= to_ascii(d0_t0_tot); tx_char_rom[154] <= "c";
                            tx_char_rom[155] <= " ";  tx_char_rom[156] <= "|";  tx_char_rom[157] <= " ";
                            tx_char_rom[158] <= "S";  tx_char_rom[159] <= "o";  tx_char_rom[160] <= "f";
                            tx_char_rom[161] <= "t";  tx_char_rom[162] <= "m";  tx_char_rom[163] <= "a";
                            tx_char_rom[164] <= "x";  tx_char_rom[165] <= "=";  tx_char_rom[166] <= to_ascii(d3_t0_sm);
                            tx_char_rom[167] <= to_ascii(d2_t0_sm); tx_char_rom[168] <= to_ascii(d1_t0_sm);
                            tx_char_rom[169] <= to_ascii(d0_t0_sm); tx_char_rom[170] <= "c";
                            tx_char_rom[171] <= 8'h0D; tx_char_rom[172] <= 8'h0A;

                            // Line 2: Version A
                            tx_char_rom[173] <= " ";  tx_char_rom[174] <= " ";  tx_char_rom[175] <= "V";
                            tx_char_rom[176] <= "e";  tx_char_rom[177] <= "r";  tx_char_rom[178] <= "s";
                            tx_char_rom[179] <= "i";  tx_char_rom[180] <= "o";  tx_char_rom[181] <= "n";
                            tx_char_rom[182] <= "A";  tx_char_rom[183] <= ":";  tx_char_rom[184] <= " ";
                            tx_char_rom[185] <= "T";  tx_char_rom[186] <= "o";  tx_char_rom[187] <= "t";
                            tx_char_rom[188] <= "a";  tx_char_rom[189] <= "l";  tx_char_rom[190] <= "=";
                            tx_char_rom[191] <= to_ascii(d3_va_tot); tx_char_rom[192] <= to_ascii(d2_va_tot);
                            tx_char_rom[193] <= to_ascii(d1_va_tot); tx_char_rom[194] <= to_ascii(d0_va_tot);
                            tx_char_rom[195] <= "c";  tx_char_rom[196] <= " ";  tx_char_rom[197] <= "|";
                            tx_char_rom[198] <= " ";  tx_char_rom[199] <= "S";  tx_char_rom[200] <= "o";
                            tx_char_rom[201] <= "f";  tx_char_rom[202] <= "t";  tx_char_rom[203] <= "m";
                            tx_char_rom[204] <= "a";  tx_char_rom[205] <= "x";  tx_char_rom[206] <= "=";
                            tx_char_rom[207] <= to_ascii(d3_va_sm);  tx_char_rom[208] <= to_ascii(d2_va_sm);
                            tx_char_rom[209] <= to_ascii(d1_va_sm);  tx_char_rom[210] <= to_ascii(d0_va_sm);
                            tx_char_rom[211] <= "c";  tx_char_rom[212] <= 8'h0D; tx_char_rom[213] <= 8'h0A;

                            // Line 3: Delta / Difference
                            tx_char_rom[214] <= " ";  tx_char_rom[215] <= " ";  tx_char_rom[216] <= "D";
                            tx_char_rom[217] <= "e";  tx_char_rom[218] <= "l";  tx_char_rom[219] <= "t";
                            tx_char_rom[220] <= "a";  tx_char_rom[221] <= ":";  tx_char_rom[222] <= " ";
                            tx_char_rom[223] <= "T";  tx_char_rom[224] <= "i";  tx_char_rom[225] <= "e";
                            tx_char_rom[226] <= "r";  tx_char_rom[227] <= "0";  tx_char_rom[228] <= " ";
                            tx_char_rom[229] <= "i";  tx_char_rom[230] <= "s";  tx_char_rom[231] <= " ";
                            tx_char_rom[232] <= to_ascii(d2_del);    tx_char_rom[233] <= to_ascii(d1_del);
                            tx_char_rom[234] <= to_ascii(d0_del);    tx_char_rom[235] <= " ";
                            tx_char_rom[236] <= "c";  tx_char_rom[237] <= "y";  tx_char_rom[238] <= "c";
                            tx_char_rom[239] <= "l";  tx_char_rom[240] <= "e";  tx_char_rom[241] <= "s";
                            tx_char_rom[242] <= " ";  tx_char_rom[243] <= "F";  tx_char_rom[244] <= "A";
                            tx_char_rom[245] <= "S";  tx_char_rom[246] <= "T";  tx_char_rom[247] <= "E";
                            tx_char_rom[248] <= "R";  tx_char_rom[249] <= "!";  tx_char_rom[250] <= 8'h0D;
                            tx_char_rom[251] <= 8'h0A;

                            // Closing border
                            tx_char_rom[252] <= "=";  tx_char_rom[253] <= "=";  tx_char_rom[254] <= "=";
                            tx_char_rom[255] <= "=";  tx_char_rom[256] <= "=";  tx_char_rom[257] <= "=";
                            tx_char_rom[258] <= "=";  tx_char_rom[259] <= "=";  tx_char_rom[260] <= "=";
                            tx_char_rom[261] <= "=";  tx_char_rom[262] <= "=";  tx_char_rom[263] <= "=";
                            tx_char_rom[264] <= "=";  tx_char_rom[265] <= "=";  tx_char_rom[266] <= "=";
                            tx_char_rom[267] <= "=";  tx_char_rom[268] <= "=";  tx_char_rom[269] <= "=";
                            tx_char_rom[270] <= "=";  tx_char_rom[271] <= "=";  tx_char_rom[272] <= "=";
                            tx_char_rom[273] <= "=";  tx_char_rom[274] <= "=";  tx_char_rom[275] <= "=";
                            tx_char_rom[276] <= "=";  tx_char_rom[277] <= "=";  tx_char_rom[278] <= "=";
                            tx_char_rom[279] <= "=";  tx_char_rom[280] <= "=";  tx_char_rom[281] <= "=";
                            tx_char_rom[282] <= "=";  tx_char_rom[283] <= "=";  tx_char_rom[284] <= "=";
                            tx_char_rom[285] <= "=";  tx_char_rom[286] <= "=";  tx_char_rom[287] <= "=";
                            tx_char_rom[288] <= "=";  tx_char_rom[289] <= "=";  tx_char_rom[290] <= "=";
                            tx_char_rom[291] <= "=";  tx_char_rom[292] <= "=";  tx_char_rom[293] <= "=";
                            tx_char_rom[294] <= "=";  tx_char_rom[295] <= "=";  tx_char_rom[296] <= "=";
                            tx_char_rom[297] <= "=";  tx_char_rom[298] <= "=";  tx_char_rom[299] <= 8'h0D;
                            tx_char_rom[300] <= 8'h0A;
                            tx_len <= 9'd301;
                        end
                        default: tx_len <= 9'd0;
                    endcase

                    ctrl_state <= CTRL_TRANSMIT;
                end

                // -------------------------------------------------------------
                // Stream characters from buffer out to UART TX
                // -------------------------------------------------------------
                CTRL_TRANSMIT: begin
                    if (!tx_busy && !tx_start) begin
                        if (tx_idx < tx_len) begin
                            tx_byte  <= tx_char_rom[tx_idx];
                            tx_start <= 1'b1;
                            tx_idx   <= tx_idx + 9'd1;
                        end else begin
                            tx_in_progress <= 1'b0;
                            ctrl_state     <= CTRL_IDLE;
                        end
                    end
                end

                default: ctrl_state <= CTRL_IDLE;
            endcase
        end
    end

endmodule
