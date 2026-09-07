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
    output wire [6:0] HEX7
);
    // Active-low push buttons
    wire rst_n = KEY[0];
    wire btn_start_raw = ~KEY[1];

    // Debounce / edge detect for start
    reg btn_d1, btn_d2;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            btn_d1 <= 1'b0;
            btn_d2 <= 1'b0;
        end else begin
            btn_d1 <= btn_start_raw;
            btn_d2 <= btn_d1;
        end
    end
    wire key_start_pulse = btn_d1 & ~btn_d2;

    // Auto-trigger on switch flip
    reg [4:0] sw_prev;
    reg       sw_change_pulse;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            sw_prev         <= 5'd0;
            sw_change_pulse <= 1'b0;
        end else begin
            if (SW[4:0] != sw_prev) begin
                sw_prev         <= SW[4:0];
                sw_change_pulse <= 1'b1;
            end else begin
                sw_change_pulse <= 1'b0;
            end
        end
    end

    // Initial power-up trigger
    reg powerup_done;
    reg powerup_pulse;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            powerup_done  <= 1'b0;
            powerup_pulse <= 1'b0;
        end else if (!powerup_done) begin
            powerup_done  <= 1'b1;
            powerup_pulse <= 1'b1;
        end else begin
            powerup_pulse <= 1'b0;
        end
    end

    wire start_pulse = key_start_pulse | sw_change_pulse | powerup_pulse;

    // Token ID selector based on SW[4:2] (6 sentences)
    reg [63:0] selected_tokens;
    always @* begin
        case (SW[4:2])
            3'd0: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd5, 8'd4, 8'd3, 8'd2};
            3'd1: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd5, 8'd4, 8'd7, 8'd2};
            3'd2: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd9, 8'd4, 8'd8};
            3'd3: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd9, 8'd4, 8'd11};
            3'd4: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd13, 8'd4, 8'd3, 8'd2};
            3'd5: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd13, 8'd4, 8'd7, 8'd2};
            default: selected_tokens = {8'd0, 8'd0, 8'd0, 8'd0, 8'd5, 8'd4, 8'd3, 8'd2};
        endcase
    end

    // Attention Accelerator Core
    wire [2:0] intent_id;
    wire [6*32-1:0] logits_flat;
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
        .logits(logits_flat),
        .softmax_cycles(engine_softmax_cycles),
        .busy(engine_busy),
        .done(engine_done)
    );

    // Cycle Counter
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

    reg [2:0] latched_intent;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            latched_intent <= 3'd0;
        end else if (engine_done) begin
            latched_intent <= intent_id;
        end
    end

    // Heartbeat LED (1.5 Hz on LEDG[2])
    reg [24:0] heartbeat_cnt;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= 25'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 25'd1;
    end
    wire heartbeat_led = heartbeat_cnt[24];

    // Active-low 7-segment decoder
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

    // 7-segment display assignments
    assign HEX0 = seg7({1'b0, latched_intent});
    assign HEX1 = (SW[1:0] == 2'b00) ? seg7(4'h0) :
                  (SW[1:0] == 2'b01) ? seg7(4'h1) : seg7(4'ha);
    assign HEX2 = (SW[4:2] <= 3'd5) ? seg7({1'b0, SW[4:2]}) : 7'b011_1111;
    assign HEX3 = 7'b011_1111;
    assign HEX4 = seg7(latched_cycles[3:0]);
    assign HEX5 = seg7(latched_cycles[7:4]);
    assign HEX6 = seg7(latched_cycles[11:8]);
    assign HEX7 = seg7(latched_cycles[15:12]);

    // Red LEDs: Direct reflection of all 18 switches
    assign LEDR[17:0] = SW[17:0];

    // Green LEDs: Status and Heartbeat
    assign LEDG[0]   = engine_busy;
    assign LEDG[1]   = engine_done;
    assign LEDG[2]   = heartbeat_led;
    assign LEDG[8:3] = 6'd0;

endmodule
