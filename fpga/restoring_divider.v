module restoring_divider #(
    parameter N = 16
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [N-1:0] dividend,
    input  wire [N-1:0] divisor,
    output reg  [N-1:0] quotient,
    output reg  [N-1:0] remainder,
    output reg          done,
    output reg          busy
);
    reg [N-1:0] dividend_r;
    reg [N-1:0] divisor_r;
    reg [N:0]   rem_r;
    reg [N-1:0] quot_r;
    reg [N:0]   trial;
    reg [N:0]   count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dividend_r <= {N{1'b0}};
            divisor_r  <= {N{1'b0}};
            rem_r      <= {(N+1){1'b0}};
            quot_r     <= {N{1'b0}};
            quotient   <= {N{1'b0}};
            remainder  <= {N{1'b0}};
            done       <= 1'b0;
            busy       <= 1'b0;
            count      <= {(N+1){1'b0}};
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                dividend_r <= dividend;
                divisor_r  <= divisor;
                rem_r      <= {(N+1){1'b0}};
                quot_r     <= {N{1'b0}};
                count      <= N;
                busy       <= 1'b1;
            end else if (busy) begin
                trial = {rem_r[N-1:0], dividend_r[N-1]};
                dividend_r <= {dividend_r[N-2:0], 1'b0};

                if (divisor_r != {N{1'b0}} && trial >= {1'b0, divisor_r}) begin
                    rem_r <= trial - {1'b0, divisor_r};
                    quot_r <= {quot_r[N-2:0], 1'b1};
                end else begin
                    rem_r <= trial;
                    quot_r <= {quot_r[N-2:0], 1'b0};
                end

                count <= count - 1'b1;
                if (count == 1) begin
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    quotient  <= (divisor_r != {N{1'b0}} && trial >= {1'b0, divisor_r}) ? {quot_r[N-2:0],1'b1} : {quot_r[N-2:0],1'b0};
                    remainder <= ((divisor_r != {N{1'b0}} && trial >= {1'b0, divisor_r}) ? trial - {1'b0, divisor_r} : trial);
                end
            end
        end
    end
endmodule
