`timescale 1ns/1ps

module tb_softmax_tier1;
    reg clk;
    reg rst_n;
    reg start;
    reg signed [15:0] scores [0:7];
    wire [7:0] probs [0:7];
    wire done;
    wire busy;
    wire [15:0] cycle_cnt;
    integer i;

    wire [8*16-1:0] scores_flat;
    wire [8*8-1:0]  probs_flat;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_tb_scores
            assign scores_flat[gi*16 +: 16] = scores[gi];
            assign probs[gi] = probs_flat[gi*8 +: 8];
        end
    endgenerate

    softmax_tier1 #(.L(8)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .scores(scores_flat),
        .probs(probs_flat),
        .done(done),
        .busy(busy),
        .cycle_cnt(cycle_cnt)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        for (i = 0; i < 8; i = i + 1) scores[i] = 0;
        #20 rst_n = 1;
        @(negedge clk);
        scores[0] = 32;  scores[1] = 16;  scores[2] = 0;   scores[3] = -8;
        scores[4] = -16; scores[5] = -24; scores[6] = -32; scores[7] = -40;
        start = 1;
        @(negedge clk); start = 0;
        wait(done);
        if (probs[0] < probs[1] || probs[1] < probs[2]) begin
            $display("ERROR: Tier1 ordering failure");
            $finish(1);
        end
        $display("TIER1 PASS");
        $finish;
    end
endmodule
