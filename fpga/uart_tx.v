module uart_tx #(
    parameter CLK_HZ = 50000000,
    parameter BAUD = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [7:0] data,
    output reg tx,
    output reg busy
);
    localparam integer DIV = CLK_HZ / BAUD;
    reg [15:0] baud_cnt;
    reg [3:0] bit_cnt;
    reg [9:0] shreg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx<=1; busy<=0; baud_cnt<=0; bit_cnt<=0; shreg<=10'h3ff;
        end else begin
            if (start && !busy) begin
                shreg <= {1'b1, data, 1'b0};
                busy <= 1;
                bit_cnt <= 0;
                baud_cnt <= 0;
            end else if (busy) begin
                if (baud_cnt == DIV-1) begin
                    baud_cnt <= 0;
                    tx <= shreg[0];
                    shreg <= {1'b1, shreg[9:1]};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 9) busy <= 0;
                end else baud_cnt <= baud_cnt + 1'b1;
            end
        end
    end
endmodule
