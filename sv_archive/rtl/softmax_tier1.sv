`timescale 1ns/1ps

module softmax_tier1 #(
    parameter L = 8,
    parameter SCORE_W = 16,
    parameter OUT_W = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire signed [SCORE_W-1:0] scores [0:L-1],
    output reg  [OUT_W-1:0] probs [0:L-1],
    output reg  done,
    output reg  busy,
    output reg  [15:0] cycle_cnt
);
    // -------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------
    localparam ST_IDLE       = 3'd0;
    localparam ST_FIND_MAX   = 3'd1;
    localparam ST_EXP_LUT    = 3'd2;
    localparam ST_DIV_START  = 3'd3;
    localparam ST_DIV_WAIT   = 3'd4;
    localparam ST_DONE       = 3'd5;

    reg [2:0] state;
    reg [3:0] idx;

    reg signed [SCORE_W-1:0] maxv;
    reg signed [SCORE_W:0]   z;
    reg [15:0] t_q4;
    reg [3:0]  frac;
    reg [4:0]  q;
    reg [15:0] lut [0:15];
    reg [15:0] w [0:L-1];
    reg [23:0] sumw;

    initial begin
        lut[0]=16'hffff; lut[1]=16'hf525; lut[2]=16'heac0; lut[3]=16'he0cc;
        lut[4]=16'hd744; lut[5]=16'hce24; lut[6]=16'hc566; lut[7]=16'hbd08;
        lut[8]=16'hb504; lut[9]=16'had58; lut[10]=16'ha5fe; lut[11]=16'h9ef5;
        lut[12]=16'h9837; lut[13]=16'h91c3; lut[14]=16'h8b95; lut[15]=16'h85aa;
    end

    // -------------------------------------------------------------
    // Multi-Cycle Restoring Divider (24-bit)
    // -------------------------------------------------------------
    reg         div_start;
    reg  [23:0] div_dividend;
    reg  [23:0] div_divisor;
    wire [23:0] div_quotient;
    wire [23:0] div_remainder;
    wire        div_done;
    wire        div_busy;

    restoring_divider #(.N(24)) u_div (
        .clk(clk),
        .rst_n(rst_n),
        .start(div_start),
        .dividend(div_dividend),
        .divisor(div_divisor),
        .quotient(div_quotient),
        .remainder(div_remainder),
        .done(div_done),
        .busy(div_busy)
    );

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            done         <= 1'b0;
            busy         <= 1'b0;
            cycle_cnt    <= 16'd0;
            idx          <= 4'd0;
            maxv         <= {SCORE_W{1'b0}};
            sumw         <= 24'd0;
            div_start    <= 1'b0;
            div_dividend <= 24'd0;
            div_divisor  <= 24'd1;
            for (i = 0; i < L; i = i + 1) begin
                w[i]     <= 16'd0;
                probs[i] <= {OUT_W{1'b0}};
            end
        end else begin
            done      <= 1'b0;
            div_start <= 1'b0;

            if (busy)
                cycle_cnt <= cycle_cnt + 1'b1;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        cycle_cnt <= 16'd1;
                        maxv      <= scores[0];
                        idx       <= 4'd1;
                        state     <= ST_FIND_MAX;
                    end
                end

                // ---------------------------------------------------------
                // Stage 1: Sequential Find Max (8 cycles)
                // ---------------------------------------------------------
                ST_FIND_MAX: begin
                    if (scores[idx] > maxv)
                        maxv <= scores[idx];

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        sumw  <= 24'd0;
                        state <= ST_EXP_LUT;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 2: Q4.4 16-LUT Refinement & Accumulation (8 cycles)
                // ---------------------------------------------------------
                ST_EXP_LUT: begin
                    z = scores[idx] - maxv;
                    t_q4 = ((-z) * 23);
                    q = t_q4[7:4];
                    frac = t_q4[3:0];

                    if (t_q4[15:8] != 8'd0 || q > 15) begin
                        w[idx] <= 16'd1;
                        sumw   <= sumw + 24'd1;
                    end else begin
                        w[idx] <= (lut[frac] >> q) == 0 ? 16'd1 : (lut[frac] >> q);
                        sumw   <= sumw + ((lut[frac] >> q) == 0 ? 24'd1 : {8'd0, (lut[frac] >> q)});
                    end

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        state <= ST_DIV_START;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 3: Restoring Divider Normalization (8 * 24 cycles)
                // ---------------------------------------------------------
                ST_DIV_START: begin
                    div_dividend <= {8'd0, w[idx]} * 24'd127;
                    div_divisor  <= (sumw != 24'd0) ? sumw : 24'd1;
                    div_start    <= 1'b1;
                    state        <= ST_DIV_WAIT;
                end

                ST_DIV_WAIT: begin
                    if (div_done) begin
                        probs[idx] <= div_quotient[OUT_W-1:0];
                        if (idx == L-1) begin
                            state <= ST_DONE;
                        end else begin
                            idx   <= idx + 1'b1;
                            state <= ST_DIV_START;
                        end
                    end
                end

                // ---------------------------------------------------------
                // Stage 4: Finish & Assert Done
                // ---------------------------------------------------------
                ST_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
