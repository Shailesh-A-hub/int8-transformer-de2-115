module softmax_detour_vA #(
    parameter L = 8,
    parameter SCORE_W = 16
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire signed [SCORE_W-1:0] scores [0:L-1],
    output reg [7:0] probs [0:L-1],
    output reg done,
    output reg busy,
    output reg [15:0] cycle_cnt
);
    localparam ST_IDLE       = 3'd0;
    localparam ST_FIND_MAX   = 3'd1;
    localparam ST_DESCALE    = 3'd2;
    localparam ST_EXP_LUT    = 3'd3;
    localparam ST_DIV_START  = 3'd4;
    localparam ST_DIV_WAIT   = 3'd5;
    localparam ST_REQUANT    = 3'd6;
    localparam ST_DONE       = 3'd7;

    reg [2:0] state;
    reg [3:0] idx;

    reg signed [SCORE_W-1:0] maxv;
    reg signed [SCORE_W:0]   z;
    reg signed [SCORE_W:0]   z_desc [0:L-1];
    reg [7:0]  lut_idx;
    reg [15:0] exp_lut [0:255];
    reg [15:0] w [0:L-1];
    reg [23:0] sumw;
    reg [23:0] raw_prob [0:L-1];

    // 24-bit Restoring Divider
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

    integer k;
    initial begin
        exp_lut[0] = 16'h0016;
        exp_lut[1] = 16'h0017;
        exp_lut[2] = 16'h0017;
        exp_lut[3] = 16'h0018;
        exp_lut[4] = 16'h0019;
        exp_lut[5] = 16'h001a;
        exp_lut[6] = 16'h001b;
        exp_lut[7] = 16'h001b;
        exp_lut[8] = 16'h001c;
        exp_lut[9] = 16'h001d;
        exp_lut[10] = 16'h001e;
        exp_lut[11] = 16'h001f;
        exp_lut[12] = 16'h0020;
        exp_lut[13] = 16'h0021;
        exp_lut[14] = 16'h0022;
        exp_lut[15] = 16'h0023;
        exp_lut[16] = 16'h0024;
        exp_lut[17] = 16'h0025;
        exp_lut[18] = 16'h0027;
        exp_lut[19] = 16'h0028;
        exp_lut[20] = 16'h0029;
        exp_lut[21] = 16'h002a;
        exp_lut[22] = 16'h002c;
        exp_lut[23] = 16'h002d;
        exp_lut[24] = 16'h002f;
        exp_lut[25] = 16'h0030;
        exp_lut[26] = 16'h0032;
        exp_lut[27] = 16'h0033;
        exp_lut[28] = 16'h0035;
        exp_lut[29] = 16'h0037;
        exp_lut[30] = 16'h0038;
        exp_lut[31] = 16'h003a;
        exp_lut[32] = 16'h003c;
        exp_lut[33] = 16'h003e;
        exp_lut[34] = 16'h0040;
        exp_lut[35] = 16'h0042;
        exp_lut[36] = 16'h0044;
        exp_lut[37] = 16'h0046;
        exp_lut[38] = 16'h0048;
        exp_lut[39] = 16'h004b;
        exp_lut[40] = 16'h004d;
        exp_lut[41] = 16'h0050;
        exp_lut[42] = 16'h0052;
        exp_lut[43] = 16'h0055;
        exp_lut[44] = 16'h0057;
        exp_lut[45] = 16'h005a;
        exp_lut[46] = 16'h005d;
        exp_lut[47] = 16'h0060;
        exp_lut[48] = 16'h0063;
        exp_lut[49] = 16'h0066;
        exp_lut[50] = 16'h006a;
        exp_lut[51] = 16'h006d;
        exp_lut[52] = 16'h0070;
        exp_lut[53] = 16'h0074;
        exp_lut[54] = 16'h0078;
        exp_lut[55] = 16'h007b;
        exp_lut[56] = 16'h007f;
        exp_lut[57] = 16'h0083;
        exp_lut[58] = 16'h0088;
        exp_lut[59] = 16'h008c;
        exp_lut[60] = 16'h0090;
        exp_lut[61] = 16'h0095;
        exp_lut[62] = 16'h009a;
        exp_lut[63] = 16'h009f;
        exp_lut[64] = 16'h00a4;
        exp_lut[65] = 16'h00a9;
        exp_lut[66] = 16'h00ae;
        exp_lut[67] = 16'h00b4;
        exp_lut[68] = 16'h00ba;
        exp_lut[69] = 16'h00c0;
        exp_lut[70] = 16'h00c6;
        exp_lut[71] = 16'h00cc;
        exp_lut[72] = 16'h00d2;
        exp_lut[73] = 16'h00d9;
        exp_lut[74] = 16'h00e0;
        exp_lut[75] = 16'h00e7;
        exp_lut[76] = 16'h00ef;
        exp_lut[77] = 16'h00f6;
        exp_lut[78] = 16'h00fe;
        exp_lut[79] = 16'h0106;
        exp_lut[80] = 16'h010e;
        exp_lut[81] = 16'h0117;
        exp_lut[82] = 16'h0120;
        exp_lut[83] = 16'h0129;
        exp_lut[84] = 16'h0133;
        exp_lut[85] = 16'h013c;
        exp_lut[86] = 16'h0146;
        exp_lut[87] = 16'h0151;
        exp_lut[88] = 16'h015c;
        exp_lut[89] = 16'h0167;
        exp_lut[90] = 16'h0172;
        exp_lut[91] = 16'h017e;
        exp_lut[92] = 16'h018a;
        exp_lut[93] = 16'h0197;
        exp_lut[94] = 16'h01a4;
        exp_lut[95] = 16'h01b1;
        exp_lut[96] = 16'h01bf;
        exp_lut[97] = 16'h01cd;
        exp_lut[98] = 16'h01dc;
        exp_lut[99] = 16'h01eb;
        exp_lut[100] = 16'h01fb;
        exp_lut[101] = 16'h020b;
        exp_lut[102] = 16'h021b;
        exp_lut[103] = 16'h022d;
        exp_lut[104] = 16'h023e;
        exp_lut[105] = 16'h0251;
        exp_lut[106] = 16'h0263;
        exp_lut[107] = 16'h0277;
        exp_lut[108] = 16'h028b;
        exp_lut[109] = 16'h02a0;
        exp_lut[110] = 16'h02b5;
        exp_lut[111] = 16'h02cb;
        exp_lut[112] = 16'h02e2;
        exp_lut[113] = 16'h02fa;
        exp_lut[114] = 16'h0312;
        exp_lut[115] = 16'h032b;
        exp_lut[116] = 16'h0345;
        exp_lut[117] = 16'h035f;
        exp_lut[118] = 16'h037b;
        exp_lut[119] = 16'h0397;
        exp_lut[120] = 16'h03b5;
        exp_lut[121] = 16'h03d3;
        exp_lut[122] = 16'h03f2;
        exp_lut[123] = 16'h0412;
        exp_lut[124] = 16'h0433;
        exp_lut[125] = 16'h0456;
        exp_lut[126] = 16'h0479;
        exp_lut[127] = 16'h049e;
        exp_lut[128] = 16'h04c3;
        exp_lut[129] = 16'h04ea;
        exp_lut[130] = 16'h0512;
        exp_lut[131] = 16'h053c;
        exp_lut[132] = 16'h0566;
        exp_lut[133] = 16'h0592;
        exp_lut[134] = 16'h05c0;
        exp_lut[135] = 16'h05ef;
        exp_lut[136] = 16'h061f;
        exp_lut[137] = 16'h0651;
        exp_lut[138] = 16'h0685;
        exp_lut[139] = 16'h06ba;
        exp_lut[140] = 16'h06f1;
        exp_lut[141] = 16'h0729;
        exp_lut[142] = 16'h0764;
        exp_lut[143] = 16'h07a0;
        exp_lut[144] = 16'h07de;
        exp_lut[145] = 16'h081e;
        exp_lut[146] = 16'h0861;
        exp_lut[147] = 16'h08a5;
        exp_lut[148] = 16'h08ec;
        exp_lut[149] = 16'h0934;
        exp_lut[150] = 16'h097f;
        exp_lut[151] = 16'h09cd;
        exp_lut[152] = 16'h0a1d;
        exp_lut[153] = 16'h0a6f;
        exp_lut[154] = 16'h0ac4;
        exp_lut[155] = 16'h0b1c;
        exp_lut[156] = 16'h0b77;
        exp_lut[157] = 16'h0bd5;
        exp_lut[158] = 16'h0c35;
        exp_lut[159] = 16'h0c99;
        exp_lut[160] = 16'h0cff;
        exp_lut[161] = 16'h0d69;
        exp_lut[162] = 16'h0dd7;
        exp_lut[163] = 16'h0e48;
        exp_lut[164] = 16'h0ebc;
        exp_lut[165] = 16'h0f35;
        exp_lut[166] = 16'h0fb1;
        exp_lut[167] = 16'h1031;
        exp_lut[168] = 16'h10b5;
        exp_lut[169] = 16'h113d;
        exp_lut[170] = 16'h11ca;
        exp_lut[171] = 16'h125b;
        exp_lut[172] = 16'h12f0;
        exp_lut[173] = 16'h138b;
        exp_lut[174] = 16'h142a;
        exp_lut[175] = 16'h14cf;
        exp_lut[176] = 16'h1579;
        exp_lut[177] = 16'h1628;
        exp_lut[178] = 16'h16dd;
        exp_lut[179] = 16'h1797;
        exp_lut[180] = 16'h1858;
        exp_lut[181] = 16'h191e;
        exp_lut[182] = 16'h19eb;
        exp_lut[183] = 16'h1abf;
        exp_lut[184] = 16'h1b99;
        exp_lut[185] = 16'h1c7a;
        exp_lut[186] = 16'h1d62;
        exp_lut[187] = 16'h1e52;
        exp_lut[188] = 16'h1f49;
        exp_lut[189] = 16'h2049;
        exp_lut[190] = 16'h2150;
        exp_lut[191] = 16'h2260;
        exp_lut[192] = 16'h2378;
        exp_lut[193] = 16'h249a;
        exp_lut[194] = 16'h25c4;
        exp_lut[195] = 16'h26f8;
        exp_lut[196] = 16'h2836;
        exp_lut[197] = 16'h297f;
        exp_lut[198] = 16'h2ad1;
        exp_lut[199] = 16'h2c2e;
        exp_lut[200] = 16'h2d97;
        exp_lut[201] = 16'h2f0b;
        exp_lut[202] = 16'h308b;
        exp_lut[203] = 16'h3217;
        exp_lut[204] = 16'h33af;
        exp_lut[205] = 16'h3555;
        exp_lut[206] = 16'h3708;
        exp_lut[207] = 16'h38c9;
        exp_lut[208] = 16'h3a98;
        exp_lut[209] = 16'h3c76;
        exp_lut[210] = 16'h3e64;
        exp_lut[211] = 16'h4061;
        exp_lut[212] = 16'h426e;
        exp_lut[213] = 16'h448c;
        exp_lut[214] = 16'h46bb;
        exp_lut[215] = 16'h48fc;
        exp_lut[216] = 16'h4b50;
        exp_lut[217] = 16'h4db6;
        exp_lut[218] = 16'h5030;
        exp_lut[219] = 16'h52be;
        exp_lut[220] = 16'h5562;
        exp_lut[221] = 16'h581a;
        exp_lut[222] = 16'h5ae9;
        exp_lut[223] = 16'h5dcf;
        exp_lut[224] = 16'h60cc;
        exp_lut[225] = 16'h63e2;
        exp_lut[226] = 16'h6711;
        exp_lut[227] = 16'h6a59;
        exp_lut[228] = 16'h6dbd;
        exp_lut[229] = 16'h713c;
        exp_lut[230] = 16'h74d8;
        exp_lut[231] = 16'h7892;
        exp_lut[232] = 16'h7c69;
        exp_lut[233] = 16'h8060;
        exp_lut[234] = 16'h8478;
        exp_lut[235] = 16'h88b0;
        exp_lut[236] = 16'h8d0c;
        exp_lut[237] = 16'h918a;
        exp_lut[238] = 16'h962e;
        exp_lut[239] = 16'h9af7;
        exp_lut[240] = 16'h9fe7;
        exp_lut[241] = 16'ha500;
        exp_lut[242] = 16'haa42;
        exp_lut[243] = 16'hafaf;
        exp_lut[244] = 16'hb549;
        exp_lut[245] = 16'hbb10;
        exp_lut[246] = 16'hc106;
        exp_lut[247] = 16'hc72d;
        exp_lut[248] = 16'hcd86;
        exp_lut[249] = 16'hd412;
        exp_lut[250] = 16'hdad5;
        exp_lut[251] = 16'he1ce;
        exp_lut[252] = 16'he900;
        exp_lut[253] = 16'hf06d;
        exp_lut[254] = 16'hf817;
        exp_lut[255] = 16'hffff;
    end

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
                z_desc[i]   <= {SCORE_W+1{1'b0}};
                raw_prob[i] <= 24'd0;
                probs[i]    <= 8'd0;
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

                // Stage 1: Sequential Find Max (8 cycles)
                ST_FIND_MAX: begin
                    if (scores[idx] > maxv)
                        maxv <= scores[idx];

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        state <= ST_DESCALE;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // Stage 2: Conventional Detour Descaling (8 cycles)
                ST_DESCALE: begin
                    z = scores[idx] - maxv;
                    if (z < -8) z = -8;
                    z_desc[idx] <= z;

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        sumw  <= 24'd0;
                        state <= ST_EXP_LUT;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // Stage 3: 256-entry Exponential LUT Read & Accumulation (8 cycles)
                ST_EXP_LUT: begin
                    lut_idx = ((z_desc[idx] + 8) * 255) >>> 3;
                    w[idx] <= exp_lut[lut_idx];
                    sumw   <= sumw + exp_lut[lut_idx];

                    if (idx == L-1) begin
                        idx   <= 4'd0;
                        state <= ST_DIV_START;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // Stage 4: Multi-cycle Restoring Divider Normalization (8 * 24 cycles)
                ST_DIV_START: begin
                    div_dividend <= {8'd0, w[idx]} * 24'd127;
                    div_divisor  <= (sumw != 24'd0) ? sumw : 24'd1;
                    div_start    <= 1'b1;
                    state        <= ST_DIV_WAIT;
                end

                ST_DIV_WAIT: begin
                    if (div_done) begin
                        raw_prob[idx] <= div_quotient;
                        if (idx == L-1) begin
                            idx   <= 4'd0;
                            state <= ST_REQUANT;
                        end else begin
                            idx   <= idx + 1'b1;
                            state <= ST_DIV_START;
                        end
                    end
                end

                // Stage 5: Conventional Detour Requantization to INT8 (8 cycles)
                ST_REQUANT: begin
                    probs[idx] <= (raw_prob[idx] > 24'd127) ? 8'd127 : raw_prob[idx][7:0];

                    if (idx == L-1) begin
                        state <= ST_DONE;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // Stage 6: Finish & Assert Done
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
