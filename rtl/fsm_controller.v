module fsm_controller (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire softmax_done,
    output reg active,
    output reg [3:0] state,
    output reg softmax_start,
    output reg done
);
    localparam IDLE=0, LOAD_QKV=1, QK_GEMM=2, SCALE=3,
               SOFTMAX=4, AV_GEMM=5, CLASSIFY=6, FINISH=7;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; active <= 0; softmax_start <= 0; done <= 0;
        end else begin
            softmax_start <= 0;
            done <= 0;
            case(state)
                IDLE: if (start) begin active<=1; state<=LOAD_QKV; end
                LOAD_QKV: state<=QK_GEMM;
                QK_GEMM: state<=SCALE;
                SCALE: begin softmax_start<=1; state<=SOFTMAX; end
                SOFTMAX: if (softmax_done) state<=AV_GEMM;
                AV_GEMM: state<=CLASSIFY;
                CLASSIFY: state<=FINISH;
                FINISH: begin active<=0; done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
