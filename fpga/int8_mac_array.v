`timescale 1ns/1ps

module int8_mac_array #(
    parameter LANES = 8,
    parameter ACC_W = 32
)(
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire clear,
    input  wire [LANES*8-1:0] a,
    input  wire [LANES*8-1:0] b,
    output wire signed [ACC_W-1:0] sum,
    output wire signed [ACC_W-1:0] comb_sum
);
    wire signed [7:0] a_lane [0:LANES-1];
    wire signed [7:0] b_lane [0:LANES-1];
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_lanes
            assign a_lane[gl] = a[gl*8 +: 8];
            assign b_lane[gl] = b[gl*8 +: 8];
        end
    endgenerate

    integer i;
    reg signed [15:0] products [0:LANES-1];
    reg signed [ACC_W-1:0] lane_sum;
    reg signed [ACC_W-1:0] acc;

    always @* begin
        lane_sum = 0;
        for (i = 0; i < LANES; i = i + 1) begin
            products[i] = a_lane[i] * b_lane[i];
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
