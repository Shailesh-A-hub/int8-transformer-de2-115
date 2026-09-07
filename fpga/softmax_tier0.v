`timescale 1ns/1ps

module softmax_tier0 #(
    parameter L = 8,
    parameter SCORE_W = 16,
    parameter OUT_W = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [L*SCORE_W-1:0] scores,
    output wire [L*OUT_W-1:0]   probs,
    output reg  done,
    output reg  busy,
    output reg  [15:0] cycle_cnt
);
    // Unpack flattened input vector into internal array
    wire signed [SCORE_W-1:0] score_array [0:L-1];
    genvar gi;
    generate
        for (gi = 0; gi < L; gi = gi + 1) begin : gen_unpack_scores
            assign score_array[gi] = scores[gi*SCORE_W +: SCORE_W];
        end
    endgenerate

    // Internal output register array packed into output wire vector
    reg [OUT_W-1:0] prob_mem [0:L-1];
    genvar gp;
    generate
        for (gp = 0; gp < L; gp = gp + 1) begin : gen_pack_probs
            assign probs[gp*OUT_W +: OUT_W] = prob_mem[gp];
        end
    endgenerate

    // -------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------
    localparam ST_IDLE       = 3'd0;
    localparam ST_FIND_MAX   = 3'd1;
    localparam ST_EXP_SHIFT  = 3'd2;
    localparam ST_DIV_START  = 3'd3;
    localparam ST_DIV_WAIT   = 3'd4;
    localparam ST_DONE       = 3'd5;

    reg [2:0] state;
    reg [3:0] idx;

    reg signed [SCORE_W-1:0] maxv;
    reg signed [SCORE_W:0]   z;
    reg [15:0] t_q4;
    reg [4:0]  shift_amt;
    reg [15:0] w [0:L-1];
    reg [23:0] sumw;

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
                w[i]        <= 16'd0;
                prob_mem[i] <= {OUT_W{1'b0}};
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
                        maxv      <= score_array[0];
                        idx       <= 4'd1;
                        state     <= ST_FIND_MAX;
                    end
                end

                // ---------------------------------------------------------
                // Stage 1: Sequential Find Max (8 cycles)
                // ---------------------------------------------------------
                ST_FIND_MAX: begin
                    if (score_array[idx] > maxv)
                        maxv <= score_array[idx];

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        sumw  <= 24'd0;
                        state <= ST_EXP_SHIFT;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 2: Base-2 Shift Exponential & Accumulation (8 cycles)
                // ---------------------------------------------------------
                ST_EXP_SHIFT: begin
                    z = score_array[idx] - maxv;
                    t_q4 = ((-z) * 23);
                    shift_amt = t_q4[7:4];
                    if (t_q4[15:8] != 8'd0 || shift_amt > 15)
                        shift_amt = 15;

                    w[idx] <= 16'h8000 >> shift_amt;
                    if ((16'h8000 >> shift_amt) == 0)
                        w[idx] <= 16'd1;

                    sumw <= sumw + ((16'h8000 >> shift_amt) == 0 ? 16'd1 : (16'h8000 >> shift_amt));

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
                        prob_mem[idx] <= div_quotient[OUT_W-1:0];
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
