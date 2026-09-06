`timescale 1ns/1ps
module tb_restoring_divider;
    reg clk=0, rst_n=0, start=0;
    reg [15:0] dividend, divisor;
    wire [15:0] quotient, remainder;
    wire done, busy;

    restoring_divider dut(.*);

    always #5 clk = ~clk;

    task check;
        input [15:0] a;
        input [15:0] b;
        reg [15:0] eq, er;
        begin
            @(negedge clk);
            dividend=a; divisor=b; start=1;
            @(negedge clk); start=0;
            wait(done);
            eq=a/b; er=a%b;
            if (quotient !== eq || remainder !== er)
                $fatal(1, "FAIL %0d/%0d got q=%0d r=%0d exp q=%0d r=%0d",
                       a,b,quotient,remainder,eq,er);
            else
                $display("PASS %0d/%0d", a,b);
        end
    endtask

    initial begin
        #20 rst_n=1;
        check(100,1);
        check(1024,2);
        check(65535,255);
        check(12345,37);
        check(32767,127);
        $display("RESTORING DIVIDER PASS");
        $finish;
    end
endmodule
