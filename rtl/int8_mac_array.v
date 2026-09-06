`timescale 1ns/1ps

module int8_mac_array #(
    parameter LANES = 8,
    parameter ACC_W = 32
)(
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire clear,
    input  wire signed [7:0] a [0:LANES-1],
    input  wire signed [7:0] b [0:LANES-1],
    output wire signed [ACC_W-1:0] sum,
    output wire signed [ACC_W-1:0] comb_sum
);
    integer i;
    reg signed [15:0] products [0:LANES-1];
    reg signed [ACC_W-1:0] lane_sum;
    reg signed [ACC_W-1:0] acc;

    always @* begin
        lane_sum = 0;
        for (i = 0; i < LANES; i = i + 1) begin
            products[i] = a[i] * b[i];
            lane_sum = lane_sum + products[i];
        end
    end

    assign comb_sum = clear ? lane_sum : (acc + lane_sum);
    assign sum      = acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_W{1'b0}};
        else if (en)
            acc <= comb_sum;
    end
endmodule
