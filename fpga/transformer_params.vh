`ifndef TRANSFORMER_PARAMS_VH
`define TRANSFORMER_PARAMS_VH

// Architectural parameters for INT8 Transformer Accelerator on DE2-115
`define SEQ_LEN      8   // Number of tokens in sequence (L)
`define EMBED_DIM    32  // Hidden dimension (d_model)
`define MAC_LANES    8   // Number of parallel INT8 MAC units
`define NUM_CLASSES  6   // Number of FSC target intents
`define VOCAB_SIZE   32  // Vocabulary capacity

// Softmax selection modes
`define MODE_TIER0   2'b00 // Barrel shift only
`define MODE_TIER1   2'b01 // Barrel shift + 16-entry fractional LUT
`define MODE_DETOUR  2'b10 // Version A conventional fixed-point detour

`endif
