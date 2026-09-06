`timescale 1ns/1ps

module attention_engine #(
    parameter L = 8,
    parameter D = 32,
    parameter NUM_CLASSES = 6
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [1:0] softmax_mode, // 00: Tier 0, 01: Tier 1, 10: Version A detour
    input  wire [7:0] token_ids [0:L-1],
    output reg  [2:0] intent_id,
    output reg  signed [31:0] logits [0:NUM_CLASSES-1],
    output reg  [31:0] softmax_cycles,
    output reg  busy,
    output reg  done
);
    // -------------------------------------------------------------
    // Clamping Helper Function
    // -------------------------------------------------------------
    function signed [7:0] clamp8(input signed [31:0] val);
        if (val > 32'sd127)
            clamp8 = 8'sd127;
        else if (val < -32'sd128)
            clamp8 = -8'sd128;
        else
            clamp8 = val[7:0];
    endfunction

    // -------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------
    localparam S_IDLE       = 4'd0;
    localparam S_LOAD_EMB   = 4'd1;
    localparam S_PROJ_Q     = 4'd2;
    localparam S_PROJ_K     = 4'd3;
    localparam S_PROJ_V     = 4'd4;
    localparam S_SCORE_QK   = 4'd5;
    localparam S_SOFTMAX    = 4'd6;
    localparam S_ATTN_V     = 4'd7;
    localparam S_POOL       = 4'd8;
    localparam S_CLASSIFY   = 4'd9;
    localparam S_ARGMAX     = 4'd10;
    localparam S_DONE       = 4'd11;

    reg [3:0] state;

    // -------------------------------------------------------------
    // Internal Scratchpad Memories
    // -------------------------------------------------------------
    reg signed [7:0]  emb_mat   [0:L-1][0:D-1];
    reg signed [7:0]  q_mat     [0:L-1][0:D-1];
    reg signed [7:0]  k_mat     [0:L-1][0:D-1];
    reg signed [7:0]  v_mat     [0:L-1][0:D-1];
    reg signed [15:0] s_mat     [0:L-1][0:L-1];
    reg [7:0]         a_mat     [0:L-1][0:L-1];
    reg signed [7:0]  h_mat     [0:L-1][0:D-1];
    reg signed [7:0]  pool_vec  [0:D-1];

    // Loop indices and counters
    reg [3:0] tok_idx;   // 0..7
    reg [5:0] dim_idx;   // 0..31
    reg [1:0] chk_idx;   // 0..3 (8 lanes per chunk)
    reg [3:0] row_idx;   // 0..7
    reg [3:0] col_idx;   // 0..7
    reg [2:0] cls_idx;   // 0..5
    reg [2:0] step_cnt;  // Multi-cycle sub-step

    // -------------------------------------------------------------
    // Weight ROM Interface
    // -------------------------------------------------------------
    reg  [2:0] rom_mat_sel;
    reg  [5:0] rom_row_idx;
    reg  [1:0] rom_chk_idx;
    wire signed [7:0] rom_data [0:7];

    weight_roms u_roms (
        .matrix_sel(rom_mat_sel),
        .row_idx(rom_row_idx),
        .chunk_idx(rom_chk_idx),
        .data_out(rom_data)
    );

    // -------------------------------------------------------------
    // Parallel INT8 MAC Array
    // -------------------------------------------------------------
    reg  mac_en;
    reg  mac_clear;
    reg  signed [7:0] mac_a [0:7];
    reg  signed [7:0] mac_b [0:7];
    wire signed [31:0] mac_sum;
    wire signed [31:0] mac_comb_sum;

    int8_mac_array #(.LANES(8), .ACC_W(32)) u_mac (
        .clk(clk),
        .rst_n(rst_n),
        .en(mac_en),
        .clear(mac_clear),
        .a(mac_a),
        .b(mac_b),
        .sum(mac_sum),
        .comb_sum(mac_comb_sum)
    );

    // -------------------------------------------------------------
    // Softmax Units (Tier 0, Tier 1, Version A detour)
    // -------------------------------------------------------------
    reg sm_start;
    reg signed [15:0] sm_scores_in [0:L-1];
    wire [7:0] sm_probs_t0 [0:L-1];
    wire [7:0] sm_probs_t1 [0:L-1];
    wire [7:0] sm_probs_va [0:L-1];
    wire sm_done_t0, sm_done_t1, sm_done_va;
    wire sm_busy_t0, sm_busy_t1, sm_busy_va;
    wire [15:0] sm_cnt_t0, sm_cnt_t1, sm_cnt_va;

    softmax_tier0 #(.L(L)) u_sm_t0 (
        .clk(clk), .rst_n(rst_n), .start(sm_start && (softmax_mode == 2'b00)),
        .scores(sm_scores_in), .probs(sm_probs_t0), .done(sm_done_t0),
        .busy(sm_busy_t0), .cycle_cnt(sm_cnt_t0)
    );

    softmax_tier1 #(.L(L)) u_sm_t1 (
        .clk(clk), .rst_n(rst_n), .start(sm_start && (softmax_mode == 2'b01)),
        .scores(sm_scores_in), .probs(sm_probs_t1), .done(sm_done_t1),
        .busy(sm_busy_t1), .cycle_cnt(sm_cnt_t1)
    );

    softmax_detour_vA #(.L(L)) u_sm_va (
        .clk(clk), .rst_n(rst_n), .start(sm_start && (softmax_mode == 2'b10)),
        .scores(sm_scores_in), .probs(sm_probs_va), .done(sm_done_va),
        .busy(sm_busy_va), .cycle_cnt(sm_cnt_va)
    );

    wire sm_active_done = (softmax_mode == 2'b00) ? sm_done_t0 :
                          (softmax_mode == 2'b01) ? sm_done_t1 : sm_done_va;

    wire [7:0] sm_active_probs [0:L-1];
    genvar gi;
    generate
        for (gi = 0; gi < L; gi = gi + 1) begin : GEN_PROB_SEL
            assign sm_active_probs[gi] = (softmax_mode == 2'b00) ? sm_probs_t0[gi] :
                                         (softmax_mode == 2'b01) ? sm_probs_t1[gi] : sm_probs_va[gi];
        end
    endgenerate

    // -------------------------------------------------------------
    // Combinational Datapath Multiplexers
    // -------------------------------------------------------------
    integer idx_l;
    always @* begin
        // Defaults
        mac_en      = 1'b0;
        mac_clear   = 1'b0;
        rom_mat_sel = 3'd0;
        rom_row_idx = 6'd0;
        rom_chk_idx = 2'd0;
        for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
            mac_a[idx_l] = 8'sd0;
            mac_b[idx_l] = 8'sd0;
        end

        case (state)
            S_LOAD_EMB: begin
                rom_mat_sel = 3'd4; // Embedding ROM
                rom_row_idx = token_ids[tok_idx][5:0];
                rom_chk_idx = chk_idx;
            end

            S_PROJ_Q: begin
                rom_mat_sel = 3'd0; // W_Q ROM
                rom_row_idx = dim_idx;
                rom_chk_idx = chk_idx;
                mac_en      = 1'b1;
                mac_clear   = (chk_idx == 2'd0);
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = emb_mat[tok_idx][{chk_idx, idx_l[2:0]}];
                    mac_b[idx_l] = rom_data[idx_l];
                end
            end

            S_PROJ_K: begin
                rom_mat_sel = 3'd1; // W_K ROM
                rom_row_idx = dim_idx;
                rom_chk_idx = chk_idx;
                mac_en      = 1'b1;
                mac_clear   = (chk_idx == 2'd0);
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = emb_mat[tok_idx][{chk_idx, idx_l[2:0]}];
                    mac_b[idx_l] = rom_data[idx_l];
                end
            end

            S_PROJ_V: begin
                rom_mat_sel = 3'd2; // W_V ROM
                rom_row_idx = dim_idx;
                rom_chk_idx = chk_idx;
                mac_en      = 1'b1;
                mac_clear   = (chk_idx == 2'd0);
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = emb_mat[tok_idx][{chk_idx, idx_l[2:0]}];
                    mac_b[idx_l] = rom_data[idx_l];
                end
            end

            S_SCORE_QK: begin
                mac_en    = 1'b1;
                mac_clear = (chk_idx == 2'd0);
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = q_mat[row_idx][{chk_idx, idx_l[2:0]}];
                    mac_b[idx_l] = k_mat[col_idx][{chk_idx, idx_l[2:0]}];
                end
            end

            S_ATTN_V: begin
                mac_en    = 1'b1;
                mac_clear = 1'b1; // Single-cycle 8-lane dot product
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = $signed({1'b0, a_mat[row_idx][idx_l]});
                    mac_b[idx_l] = v_mat[idx_l][dim_idx];
                end
            end

            S_CLASSIFY: begin
                rom_mat_sel = 3'd3; // W_cls ROM
                rom_row_idx = {3'b000, cls_idx};
                rom_chk_idx = chk_idx;
                mac_en      = 1'b1;
                mac_clear   = (chk_idx == 2'd0);
                for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1) begin
                    mac_a[idx_l] = pool_vec[{chk_idx, idx_l[2:0]}];
                    mac_b[idx_l] = rom_data[idx_l];
                end
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------
    // Main FSM Sequential Logic
    // -------------------------------------------------------------
    integer r_init;
    reg signed [31:0] max_logit;
    reg signed [31:0] pool_sum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            intent_id   <= 3'd0;
            tok_idx     <= 4'd0;
            dim_idx     <= 6'd0;
            chk_idx     <= 2'd0;
            row_idx     <= 4'd0;
            col_idx     <= 4'd0;
            cls_idx     <= 3'd0;
            step_cnt    <= 3'd0;
            sm_start       <= 1'b0;
            softmax_cycles <= 32'd0;
            max_logit      <= -32'sh7fff_ffff;
            for (r_init = 0; r_init < NUM_CLASSES; r_init = r_init + 1)
                logits[r_init] <= 32'sd0;
        end else begin
            done <= 1'b0;
            sm_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy           <= 1'b1;
                        softmax_cycles <= 32'd0;
                        tok_idx        <= 4'd0;
                        chk_idx        <= 2'd0;
                        state          <= S_LOAD_EMB;
                    end
                end

                // ---------------------------------------------------------
                // Stage 1: Load Embeddings from ROM
                // ---------------------------------------------------------
                S_LOAD_EMB: begin
                    for (idx_l = 0; idx_l < 8; idx_l = idx_l + 1)
                        emb_mat[tok_idx][{chk_idx, idx_l[2:0]}] <= rom_data[idx_l];

                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        if (tok_idx == L-1) begin
                            tok_idx <= 4'd0;
                            dim_idx <= 6'd0;
                            state   <= S_PROJ_Q;
                        end else begin
                            tok_idx <= tok_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 2: Q Projection: Q = E * W_Q^T >> 7
                // ---------------------------------------------------------
                S_PROJ_Q: begin
                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        q_mat[tok_idx][dim_idx] <= clamp8(mac_comb_sum >>> 7);
                        if (dim_idx == D-1) begin
                            dim_idx <= 6'd0;
                            if (tok_idx == L-1) begin
                                tok_idx <= 4'd0;
                                state   <= S_PROJ_K;
                            end else begin
                                tok_idx <= tok_idx + 1'b1;
                            end
                        end else begin
                            dim_idx <= dim_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 3: K Projection: K = E * W_K^T >> 7
                // ---------------------------------------------------------
                S_PROJ_K: begin
                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        k_mat[tok_idx][dim_idx] <= clamp8(mac_comb_sum >>> 7);
                        if (dim_idx == D-1) begin
                            dim_idx <= 6'd0;
                            if (tok_idx == L-1) begin
                                tok_idx <= 4'd0;
                                state   <= S_PROJ_V;
                            end else begin
                                tok_idx <= tok_idx + 1'b1;
                            end
                        end else begin
                            dim_idx <= dim_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 4: V Projection: V = E * W_V^T >> 7
                // ---------------------------------------------------------
                S_PROJ_V: begin
                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        v_mat[tok_idx][dim_idx] <= clamp8(mac_comb_sum >>> 7);
                        if (dim_idx == D-1) begin
                            dim_idx <= 6'd0;
                            if (tok_idx == L-1) begin
                                row_idx <= 4'd0;
                                col_idx <= 4'd0;
                                chk_idx <= 2'd0;
                                state   <= S_SCORE_QK;
                            end else begin
                                tok_idx <= tok_idx + 1'b1;
                            end
                        end else begin
                            dim_idx <= dim_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 5: Score Computation: S = Q * K^T >> 4
                // ---------------------------------------------------------
                S_SCORE_QK: begin
                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        s_mat[row_idx][col_idx] <= mac_comb_sum >>> 15;
                        if (col_idx == L-1) begin
                            col_idx <= 4'd0;
                            if (row_idx == L-1) begin
                                row_idx  <= 4'd0;
                                step_cnt <= 3'd0;
                                state    <= S_SOFTMAX;
                            end else begin
                                row_idx <= row_idx + 1'b1;
                            end
                        end else begin
                            col_idx <= col_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 6: Row-wise Softmax: A[r] = Softmax(S[r])
                // ---------------------------------------------------------
                S_SOFTMAX: begin
                    softmax_cycles <= softmax_cycles + 1'b1;
                    if (step_cnt == 3'd0) begin
                        for (idx_l = 0; idx_l < L; idx_l = idx_l + 1)
                            sm_scores_in[idx_l] <= s_mat[row_idx][idx_l];
                        sm_start <= 1'b1;
                        step_cnt <= 3'd1;
                    end else if (step_cnt == 3'd1) begin
                        if (sm_active_done) begin
                            for (idx_l = 0; idx_l < L; idx_l = idx_l + 1)
                                a_mat[row_idx][idx_l] <= sm_active_probs[idx_l];

                            if (row_idx == L-1) begin
                                row_idx  <= 4'd0;
                                dim_idx  <= 6'd0;
                                step_cnt <= 3'd0;
                                state    <= S_ATTN_V;
                            end else begin
                                row_idx  <= row_idx + 1'b1;
                                step_cnt <= 3'd0;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // Stage 7: Context Computation: H = A * V >> 7
                // ---------------------------------------------------------
                S_ATTN_V: begin
                    h_mat[row_idx][dim_idx] <= clamp8(mac_comb_sum >>> 7);

                    if (dim_idx == D-1) begin
                        dim_idx <= 6'd0;
                        if (row_idx == L-1) begin
                            dim_idx <= 6'd0;
                            state   <= S_POOL;
                        end else begin
                            row_idx <= row_idx + 1'b1;
                        end
                    end else begin
                        dim_idx <= dim_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 8: Mean Pooling over Sequence Length L=8
                // ---------------------------------------------------------
                S_POOL: begin
                    pool_sum = $signed(h_mat[0][dim_idx]) + $signed(h_mat[1][dim_idx]) +
                               $signed(h_mat[2][dim_idx]) + $signed(h_mat[3][dim_idx]) +
                               $signed(h_mat[4][dim_idx]) + $signed(h_mat[5][dim_idx]) +
                               $signed(h_mat[6][dim_idx]) + $signed(h_mat[7][dim_idx]);
                    pool_vec[dim_idx] <= clamp8(pool_sum >>> 3); // Divide by 8

                    if (dim_idx == D-1) begin
                        dim_idx <= 6'd0;
                        cls_idx <= 3'd0;
                        chk_idx <= 2'd0;
                        state   <= S_CLASSIFY;
                    end else begin
                        dim_idx <= dim_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 9: Intent Classifier: Logits = W_cls * h
                // ---------------------------------------------------------
                S_CLASSIFY: begin
                    if (chk_idx == 2'd3) begin
                        chk_idx <= 2'd0;
                        logits[cls_idx] <= mac_comb_sum;

                        if (cls_idx == NUM_CLASSES-1) begin
                            cls_idx  <= 3'd0;
                            step_cnt <= 3'd0;
                            state    <= S_ARGMAX;
                        end else begin
                            cls_idx <= cls_idx + 1'b1;
                        end
                    end else begin
                        chk_idx <= chk_idx + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // Stage 10: Argmax over Class Logits
                // ---------------------------------------------------------
                S_ARGMAX: begin
                    if (step_cnt == 3'd0) begin
                        max_logit <= logits[0];
                        intent_id <= 3'd0;
                        cls_idx   <= 3'd1;
                        step_cnt  <= 3'd1;
                    end else if (step_cnt == 3'd1) begin
                        if ($signed(logits[cls_idx]) > $signed(max_logit)) begin
                            max_logit <= logits[cls_idx];
                            intent_id <= cls_idx;
                        end

                        if (cls_idx == NUM_CLASSES-1) begin
                            state <= S_DONE;
                        end else begin
                            cls_idx <= cls_idx + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // Stage 11: Done and Telemetry Latch
                // ---------------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
