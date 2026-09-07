`timescale 1ns/1ps

// =============================================================================
// bin2bcd16.v - 16-bit Binary to 5-digit BCD Converter (Double-Dabble)
// Converts a 16-bit integer (0..65535) into 5 BCD digits in 16 clock cycles.
// =============================================================================
module bin2bcd16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [15:0] bin,
    output reg         done,
    output reg         busy,
    output reg  [3:0]  d4, // Ten-thousands
    output reg  [3:0]  d3, // Thousands
    output reg  [3:0]  d2, // Hundreds
    output reg  [3:0]  d1, // Tens
    output reg  [3:0]  d0  // Ones
);
    reg [4:0]  step;
    reg [19:0] bcd;
    reg [15:0] bin_reg;

    wire [3:0] c0 = (bcd[3:0]   >= 4'd5) ? (bcd[3:0]   + 4'd3) : bcd[3:0];
    wire [3:0] c1 = (bcd[7:4]   >= 4'd5) ? (bcd[7:4]   + 4'd3) : bcd[7:4];
    wire [3:0] c2 = (bcd[11:8]  >= 4'd5) ? (bcd[11:8]  + 4'd3) : bcd[11:8];
    wire [3:0] c3 = (bcd[15:12] >= 4'd5) ? (bcd[15:12] + 4'd3) : bcd[15:12];
    wire [3:0] c4 = (bcd[19:16] >= 4'd5) ? (bcd[19:16] + 4'd3) : bcd[19:16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done    <= 1'b0;
            busy    <= 1'b0;
            step    <= 5'd0;
            bcd     <= 20'd0;
            bin_reg <= 16'd0;
            d4 <= 4'd0; d3 <= 4'd0; d2 <= 4'd0; d1 <= 4'd0; d0 <= 4'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy    <= 1'b1;
                step    <= 5'd0;
                bcd     <= 20'd0;
                bin_reg <= bin;
            end else if (busy) begin
                if (step == 5'd16) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    d4   <= bcd[19:16];
                    d3   <= bcd[15:12];
                    d2   <= bcd[11:8];
                    d1   <= bcd[7:4];
                    d0   <= bcd[3:0];
                end else begin
                    bcd     <= {c4[2:0], c3, c2, c1, c0, bin_reg[15]};
                    bin_reg <= {bin_reg[14:0], 1'b0};
                    step    <= step + 5'd1;
                end
            end
        end
    end
endmodule
