`timescale 1ns/1ps
module tb_softmax_tier0;
    reg clk=0, rst_n=0, start=0;
    reg signed [15:0] scores [0:7];
    wire [7:0] probs [0:7];
    wire done;
    wire busy;
    wire [15:0] cycle_cnt;
    integer i;

    softmax_tier0 dut(.*);
    always #5 clk=~clk;

    initial begin
        for(i=0;i<8;i=i+1) scores[i]=0;
        #20 rst_n=1;
        @(negedge clk);
        scores[0]=20; scores[1]=12; scores[2]=8; scores[3]=4;
        scores[4]=0; scores[5]=-4; scores[6]=-8; scores[7]=-12;
        start=1;
        @(negedge clk); start=0;
        wait(done);
        if (probs[0] < probs[1] || probs[1] < probs[2])
            $fatal(1,"Tier0 ordering failure");
        $display("TIER0 PASS");
        $finish;
    end
endmodule
