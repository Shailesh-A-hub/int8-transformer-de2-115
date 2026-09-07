`timescale 1ns/1ps

module cycle_counter (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire done,
    input  wire active,
    output reg  [31:0] cycles,
    output reg  [31:0] latched_cycles
);
    reg counting;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycles         <= 32'd0;
            latched_cycles <= 32'd0;
            counting       <= 1'b0;
        end else begin
            if (start) begin
                cycles   <= 32'd0;
                counting <= 1'b1;
            end else if (counting && active) begin
                cycles <= cycles + 1'b1;
            end

            if (done) begin
                counting       <= 1'b0;
                latched_cycles <= cycles + 1'b1; // Include final cycle
            end
        end
    end
endmodule
