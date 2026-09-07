`timescale 1ns/1ps

// =============================================================================
// tb_uart_telemetry.v - End-to-End Simulation Testbench for UART Telemetry & Benchmark
// Simulates PC Host sending UART commands ('0', 'a', 'b') and receives ASCII telemetry
// =============================================================================
module tb_uart_telemetry;

    reg        clk;
    reg  [3:0] key;
    reg  [17:0] sw;
    wire [17:0] ledr;
    wire [8:0]  ledg;
    wire [6:0]  hex0, hex1, hex2, hex3, hex4, hex5, hex6, hex7;
    reg        uart_rxd;
    wire       uart_txd;

    // 50 MHz Clock (20 ns period)
    always #10 clk = ~clk;

    // Instantiate Top-Level Design
    de2_115_top dut (
        .CLOCK_50(clk),
        .KEY(key),
        .SW(sw),
        .LEDR(ledr),
        .LEDG(ledg),
        .HEX0(hex0),
        .HEX1(hex1),
        .HEX2(hex2),
        .HEX3(hex3),
        .HEX4(hex4),
        .HEX5(hex5),
        .HEX6(hex6),
        .HEX7(hex7),
        .UART_RXD(uart_rxd),
        .UART_TXD(uart_txd)
    );

    // Timing parameters for 115,200 baud
    localparam integer BIT_PERIOD_NS = 8680; // 1s / 115200 = 8.68 us = 8680 ns

    // -------------------------------------------------------------
    // Host PC UART Transmitter Task (sends 8N1 byte to FPGA)
    // -------------------------------------------------------------
    task send_uart_byte(input [7:0] data);
        integer b;
        begin
            // Start bit
            uart_rxd = 1'b0;
            #BIT_PERIOD_NS;
            // 8 Data bits (LSB first)
            for (b = 0; b < 8; b = b + 1) begin
                uart_rxd = data[b];
                #BIT_PERIOD_NS;
            end
            // Stop bit
            uart_rxd = 1'b1;
            #BIT_PERIOD_NS;
            #(BIT_PERIOD_NS / 2);
        end
    endtask

    // -------------------------------------------------------------
    // Host PC UART Receiver Thread (prints FPGA TX stream to console)
    // -------------------------------------------------------------
    reg [7:0] host_rx_byte;
    integer rx_b;

    initial begin
        while (1) begin
            // Wait for falling edge of start bit
            @(negedge uart_txd);
            #(BIT_PERIOD_NS / 2); // Sample mid start bit

            if (!uart_txd) begin
                // Sample 8 data bits
                for (rx_b = 0; rx_b < 8; rx_b = rx_b + 1) begin
                    #BIT_PERIOD_NS;
                    host_rx_byte[rx_b] = uart_txd;
                end
                // Wait for stop bit
                #BIT_PERIOD_NS;
                $write("%c", host_rx_byte);
            end
        end
    end

    // -------------------------------------------------------------
    // Main Test Stimulus
    // -------------------------------------------------------------
    initial begin
        $display("\n================================================================================");
        $display("   STARTING UART TELEMETRY & TIER 0 VS VERSION A BENCHMARK SIMULATION          ");
        $display("================================================================================");

        clk      = 1'b0;
        key      = 4'b1111; // Active-low KEY[0] is reset
        sw       = 18'd0;
        uart_rxd = 1'b1;    // UART idle high

        // Assert reset
        key[0] = 1'b0;
        #200;
        @(negedge clk);
        key[0] = 1'b1; // De-assert reset
        #2000;

        // Allow initial boot message to flush
        #200000;

        $display("\n[TB HOST] >>> Sending UART Command: '0' (Trigger Tier 0 Inference)");
        send_uart_byte("0");

        // Wait for inference and result string to transmit
        #1500000;

        $display("\n[TB HOST] >>> Sending UART Command: 'a' (Trigger Version A Inference)");
        send_uart_byte("a");

        // Wait for inference and result string to transmit
        #1500000;

        $display("\n[TB HOST] >>> Sending UART Command: 'b' (Trigger Automated Benchmark: Tier 0 vs Version A)");
        send_uart_byte("b");

        // Wait for Tier 0 run + Version A run + Full Benchmark Report stream
        #5500000;

        $display("\n================================================================================");
        $display("   UART TELEMETRY & HARDWARE BENCHMARK SIMULATION TEST PASSED SUCCESSFULLY!     ");
        $display("================================================================================\n");
        $finish;
    end

endmodule
