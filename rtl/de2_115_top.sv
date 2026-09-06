`timescale 1ns/1ps

module de2_115_top (
    input  wire CLOCK_50,
    input  wire [3:0] KEY,
    input  wire [17:0] SW,
    output wire [17:0] LEDR,
    output wire [8:0] LEDG,
    output wire [6:0] HEX0,
    output wire [6:0] HEX1,
    output wire [6:0] HEX2,
    output wire [6:0] HEX3,
    output wire [6:0] HEX4,
    output wire [6:0] HEX5,
    output wire [6:0] HEX6,
    output wire [6:0] HEX7,
    input  wire UART_RXD,
    output wire UART_TXD
);
    // Active-low push buttons
    wire rst_n = KEY[0];
    wire btn_start = ~KEY[1];

    // Debounce / edge detect for start
    reg btn_d1, btn_d2;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            btn_d1 <= 1'b0;
            btn_d2 <= 1'b0;
        end else begin
            btn_d1 <= btn_start;
            btn_d2 <= btn_d1;
        end
    end
    wire start_pulse = btn_d1 & ~btn_d2;

    // Token ID selector based on SW[4:2] (6 sentences)
    reg [7:0] selected_tokens [0:7];
    always @* begin
        case (SW[4:2])
            // 0: "turn on the lights"
            3'd0: begin
                selected_tokens[0] = 8'd2; selected_tokens[1] = 8'd3;
                selected_tokens[2] = 8'd4; selected_tokens[3] = 8'd5;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
            // 1: "turn off the lights"
            3'd1: begin
                selected_tokens[0] = 8'd2; selected_tokens[1] = 8'd7;
                selected_tokens[2] = 8'd4; selected_tokens[3] = 8'd5;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
            // 2: "increase the volume"
            3'd2: begin
                selected_tokens[0] = 8'd8; selected_tokens[1] = 8'd4;
                selected_tokens[2] = 8'd9; selected_tokens[3] = 8'd0;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
            // 3: "decrease the volume"
            3'd3: begin
                selected_tokens[0] = 8'd11; selected_tokens[1] = 8'd4;
                selected_tokens[2] = 8'd9;  selected_tokens[3] = 8'd0;
                selected_tokens[4] = 8'd0;  selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0;  selected_tokens[7] = 8'd0;
            end
            // 4: "turn on the heat"
            3'd4: begin
                selected_tokens[0] = 8'd2; selected_tokens[1] = 8'd3;
                selected_tokens[2] = 8'd4; selected_tokens[3] = 8'd13;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
            // 5: "turn off the heat"
            3'd5: begin
                selected_tokens[0] = 8'd2; selected_tokens[1] = 8'd7;
                selected_tokens[2] = 8'd4; selected_tokens[3] = 8'd13;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
            default: begin
                selected_tokens[0] = 8'd0; selected_tokens[1] = 8'd0;
                selected_tokens[2] = 8'd0; selected_tokens[3] = 8'd0;
                selected_tokens[4] = 8'd0; selected_tokens[5] = 8'd0;
                selected_tokens[6] = 8'd0; selected_tokens[7] = 8'd0;
            end
        endcase
    end

    // -------------------------------------------------------------
    // Attention Accelerator Core
    // -------------------------------------------------------------
    wire [2:0] intent_id;
    wire signed [31:0] logits [0:5];
    wire [31:0] engine_softmax_cycles;
    wire engine_busy;
    wire engine_done;

    attention_engine #(
        .L(8),
        .D(32),
        .NUM_CLASSES(6)
    ) u_engine (
        .clk(CLOCK_50),
        .rst_n(rst_n),
        .start(start_pulse),
        .softmax_mode(SW[1:0]),
        .token_ids(selected_tokens),
        .intent_id(intent_id),
        .logits(logits),
        .softmax_cycles(engine_softmax_cycles),
        .busy(engine_busy),
        .done(engine_done)
    );

    // -------------------------------------------------------------
    // Cycle Counter
    // -------------------------------------------------------------
    wire [31:0] active_cycles;
    wire [31:0] latched_cycles;

    cycle_counter u_counter (
        .clk(CLOCK_50),
        .rst_n(rst_n),
        .start(start_pulse),
        .done(engine_done),
        .active(engine_busy),
        .cycles(active_cycles),
        .latched_cycles(latched_cycles)
    );

    // -------------------------------------------------------------
    // UART Telemetry Transmitter
    // -------------------------------------------------------------
    reg uart_start;
    reg [7:0] uart_byte;
    wire uart_tx_busy;

    uart_tx #(
        .CLK_HZ(50000000),
        .BAUD(115200)
    ) u_uart_tx (
        .clk(CLOCK_50),
        .rst_n(rst_n),
        .start(uart_start),
        .data(uart_byte),
        .tx(UART_TXD),
        .busy(uart_tx_busy)
    );

    // Simple UART Packet Sender: "I:<id> C:<cycles>\r\n"
    reg [3:0] uart_state;
    reg [31:0] tx_cycles_reg;
    reg [2:0]  tx_intent_reg;

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            uart_state    <= 4'd0;
            uart_start    <= 1'b0;
            uart_byte     <= 8'd0;
            tx_cycles_reg <= 32'd0;
            tx_intent_reg <= 3'd0;
        end else begin
            uart_start <= 1'b0;
            if (engine_done) begin
                tx_cycles_reg <= latched_cycles;
                tx_intent_reg <= intent_id;
                uart_state    <= 4'd1;
            end else if (uart_state != 4'd0 && !uart_tx_busy && !uart_start) begin
                case (uart_state)
                    4'd1: begin uart_byte <= "I"; uart_start <= 1'b1; uart_state <= 4'd2; end
                    4'd2: begin uart_byte <= ":"; uart_start <= 1'b1; uart_state <= 4'd3; end
                    4'd3: begin uart_byte <= "0" + {5'd0, tx_intent_reg}; uart_start <= 1'b1; uart_state <= 4'd4; end
                    4'd4: begin uart_byte <= " "; uart_start <= 1'b1; uart_state <= 4'd5; end
                    4'd5: begin uart_byte <= "C"; uart_start <= 1'b1; uart_state <= 4'd6; end
                    4'd6: begin uart_byte <= ":"; uart_start <= 1'b1; uart_state <= 4'd7; end
                    4'd7: begin uart_byte <= (tx_cycles_reg[15:12] < 10) ? ("0" + tx_cycles_reg[15:12]) : ("A" + tx_cycles_reg[15:12] - 10); uart_start <= 1'b1; uart_state <= 4'd8; end
                    4'd8: begin uart_byte <= (tx_cycles_reg[11:8]  < 10) ? ("0" + tx_cycles_reg[11:8])  : ("A" + tx_cycles_reg[11:8]  - 10); uart_start <= 1'b1; uart_state <= 4'd9; end
                    4'd9: begin uart_byte <= (tx_cycles_reg[7:4]   < 10) ? ("0" + tx_cycles_reg[7:4])   : ("A" + tx_cycles_reg[7:4]   - 10); uart_start <= 1'b1; uart_state <= 4'd10; end
                    4'd10:begin uart_byte <= (tx_cycles_reg[3:0]   < 10) ? ("0" + tx_cycles_reg[3:0])   : ("A" + tx_cycles_reg[3:0]   - 10); uart_start <= 1'b1; uart_state <= 4'd11; end
                    4'd11:begin uart_byte <= 8'h0D; uart_start <= 1'b1; uart_state <= 4'd12; end // '\r'
                    4'd12:begin uart_byte <= 8'h0A; uart_start <= 1'b1; uart_state <= 4'd0; end  // '\n'
                    default: uart_state <= 4'd0;
                endcase
            end
        end
    end

    // -------------------------------------------------------------
    // 7-Segment Decoder
    // -------------------------------------------------------------
    function [6:0] seg7(input [3:0] hex);
        case (hex)
            4'h0: seg7 = 7'b100_0000;
            4'h1: seg7 = 7'b111_1001;
            4'h2: seg7 = 7'b010_0100;
            4'h3: seg7 = 7'b011_0000;
            4'h4: seg7 = 7'b001_1001;
            4'h5: seg7 = 7'b001_0010;
            4'h6: seg7 = 7'b000_0010;
            4'h7: seg7 = 7'b111_1000;
            4'h8: seg7 = 7'b000_0000;
            4'h9: seg7 = 7'b001_0000;
            4'ha: seg7 = 7'b000_1000;
            4'hb: seg7 = 7'b000_0011;
            4'hc: seg7 = 7'b100_0110;
            4'hd: seg7 = 7'b010_0001;
            4'he: seg7 = 7'b000_0110;
            4'hf: seg7 = 7'b000_1110;
            default: seg7 = 7'b111_1111;
        endcase
    endfunction

    // HEX0: Winning Intent ID (0..5)
    assign HEX0 = seg7({1'b0, intent_id});

    // HEX1: Softmax Mode (0: Tier 0, 1: Tier 1, A: Version A detour)
    assign HEX1 = (SW[1:0] == 2'b00) ? seg7(4'h0) :
                  (SW[1:0] == 2'b01) ? seg7(4'h1) : seg7(4'ha);

    // HEX2-HEX7: Latched Cycle Count in Hexadecimal
    assign HEX2 = seg7(latched_cycles[3:0]);
    assign HEX3 = seg7(latched_cycles[7:4]);
    assign HEX4 = seg7(latched_cycles[11:8]);
    assign HEX5 = seg7(latched_cycles[15:12]);
    assign HEX6 = seg7(latched_cycles[19:16]);
    assign HEX7 = seg7(latched_cycles[23:20]);

    // LEDs
    assign LEDR[2:0]   = intent_id;
    assign LEDR[5:3]   = SW[4:2];    // Selected sentence
    assign LEDR[17:16] = SW[1:0];    // Selected softmax mode
    assign LEDR[15:6]  = 10'd0;

    assign LEDG[0] = engine_busy;
    assign LEDG[1] = engine_done;
    assign LEDG[8:2] = 7'd0;

endmodule
