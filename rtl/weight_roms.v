`timescale 1ns/1ps

module weight_roms #(
    parameter MEM_DIR = "mem/"
)(
    input  wire [2:0]  matrix_sel, // 0: W_Q, 1: W_K, 2: W_V, 3: W_cls, 4: Embedding
    input  wire [5:0]  row_idx,    // Row 0..31 (or 0..5 for cls, 0..15 for emb)
    input  wire [1:0]  chunk_idx,  // Chunk 0..3 (8 bytes per chunk = 32 dimensions)
    output wire signed [7:0] data_out [0:7]
);
    // ROM storage
    reg signed [7:0] rom_wq  [0:1023];
    reg signed [7:0] rom_wk  [0:1023];
    reg signed [7:0] rom_wv  [0:1023];
    reg signed [7:0] rom_cls [0:255];
    reg signed [7:0] rom_emb [0:1023];

    initial begin
        $readmemh({MEM_DIR, "W_Q.hex"}, rom_wq);
        $readmemh({MEM_DIR, "W_K.hex"}, rom_wk);
        $readmemh({MEM_DIR, "W_V.hex"}, rom_wv);
        $readmemh({MEM_DIR, "W_cls.hex"}, rom_cls);
        $readmemh({MEM_DIR, "embedding.hex"}, rom_emb);
    end

    wire [9:0] base_addr = {row_idx, chunk_idx, 3'b000};
    genvar l;
    generate
        for (l = 0; l < 8; l = l + 1) begin : GEN_ROMS
            assign data_out[l] = (matrix_sel == 3'd0) ? rom_wq[base_addr + l] :
                                 (matrix_sel == 3'd1) ? rom_wk[base_addr + l] :
                                 (matrix_sel == 3'd2) ? rom_wv[base_addr + l] :
                                 (matrix_sel == 3'd3) ? rom_cls[{row_idx[2:0], chunk_idx, l[2:0]}] :
                                 (matrix_sel == 3'd4) ? rom_emb[base_addr + l] : 8'sd0;
        end
    endgenerate
endmodule
