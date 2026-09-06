module uart_rx #(
    parameter CLK_HZ = 50000000,
    parameter BAUD = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] data,
    output reg valid
);
    localparam integer DIV = CLK_HZ / BAUD;
    reg [15:0] cnt;
    reg [3:0] bits;
    reg [7:0] shift;
    reg busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt<=0; bits<=0; shift<=0; data<=0; valid<=0; busy<=0;
        end else begin
            valid <= 0;
            if (!busy) begin
                if (!rx) begin
                    busy<=1; cnt<=DIV/2; bits<=0;
                end
            end else if (cnt != 0) begin
                cnt <= cnt - 1'b1;
            end else begin
                cnt <= DIV-1;
                if (bits < 8) begin
                    shift[bits] <= rx;
                    bits <= bits + 1'b1;
                end else begin
                    data <= shift;
                    valid <= 1;
                    busy <= 0;
                end
            end
        end
    end
endmodule
