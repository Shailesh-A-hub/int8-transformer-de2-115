`timescale 1ns/1ps

module tb_attention_engine;
    reg clk;
    reg rst_n;
    reg start;
    reg [1:0] softmax_mode;
    reg [7:0] token_ids [0:7];
    wire [2:0] intent_id;
    wire [6*32-1:0] logits_flat;
    wire busy;
    wire done;
    wire [31:0] softmax_cycles;
    integer i;

    wire [63:0] token_ids_flat;
    genvar gt;
    generate
        for (gt = 0; gt < 8; gt = gt + 1) begin : gen_tb_tokens
            assign token_ids_flat[gt*8 +: 8] = token_ids[gt];
        end
    endgenerate

    wire signed [31:0] logits [0:5];
    genvar gl;
    generate
        for (gl = 0; gl < 6; gl = gl + 1) begin : gen_tb_logits
            assign logits[gl] = logits_flat[gl*32 +: 32];
        end
    endgenerate

    attention_engine #(
        .L(8),
        .D(32),
        .NUM_CLASSES(6)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .softmax_mode(softmax_mode),
        .token_ids(token_ids_flat),
        .intent_id(intent_id),
        .logits(logits_flat),
        .softmax_cycles(softmax_cycles),
        .busy(busy),
        .done(done)
    );

    always #10 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        softmax_mode = 2'b01; // Tier 1

        // "turn on the lights" -> [2, 3, 4, 5, 0, 0, 0, 0]
        token_ids[0] = 8'd2;
        token_ids[1] = 8'd3;
        token_ids[2] = 8'd4;
        token_ids[3] = 8'd5;
        token_ids[4] = 8'd0;
        token_ids[5] = 8'd0;
        token_ids[6] = 8'd0;
        token_ids[7] = 8'd0;

        #40;
        @(negedge clk);
        rst_n = 1;
        #20;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        wait(done);

        if (intent_id !== 3'd0) begin
            $display("ATTENTION ENGINE INTEGRATION FAIL: expected intent 0, got %0d", intent_id);
            $finish(1);
        end else begin
            $display("ATTENTION ENGINE INTEGRATION PASS: intent=%0d (turn_on_lights), logits[0]=%0d", intent_id, logits[0]);
            $finish;
        end
    end
endmodule
