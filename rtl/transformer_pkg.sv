`ifndef TRANSFORMER_PKG_SV
`define TRANSFORMER_PKG_SV

// Architectural parameters for INT8 Transformer Accelerator on DE2-115
package transformer_pkg;
    localparam SEQ_LEN      = 8;   // Number of tokens in sequence (L)
    localparam EMBED_DIM    = 32;  // Hidden dimension (d_model)
    localparam MAC_LANES    = 8;   // Number of parallel INT8 MAC units
    localparam NUM_CLASSES  = 6;   // Number of FSC target intents
    localparam VOCAB_SIZE   = 32;  // Vocabulary capacity

    // Softmax selection
    localparam MODE_TIER0   = 2'b00; // Barrel shift only
    localparam MODE_TIER1   = 2'b01; // Barrel shift + 16-entry fractional LUT
    localparam MODE_DETOUR  = 2'b10; // Version A conventional fixed-point detour
endpackage

`endif
