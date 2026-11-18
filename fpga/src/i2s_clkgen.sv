/*
 * Module: i2s_clkgen
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 *
 * I2S master clock generator. The FPGA drives the microphone clocks.
 *   bclk = clk / 4  (12 MHz -> 3 MHz)
 *   ws   = bclk / 64 (3 MHz -> 46.875 kHz)
 */

module i2s_clkgen (
    input  logic       clk,
    input  logic       reset_b,
    output logic       bclk,
    output logic       ws,
    output logic       sample_en,
    output logic [5:0] slot
);

    logic [1:0] phase;
    logic [5:0] bit_cnt;
    logic       bclk_fall;

    // clk cycles within one bclk period
    counter #(.WIDTH(2), .MAX(3)) u_phase_counter (.clk(clk), .reset_b(reset_b), .enable(1'b1), .count(phase));

    // bclk falls when phase wraps
    assign bclk_fall = (phase == 2'd3);

    // bclk periods within one ws frame
    counter #(.WIDTH(6), .MAX(63)) u_bit_counter (.clk(clk), .reset_b(reset_b), .enable(bclk_fall), .count(bit_cnt));

    // clock outputs
    assign bclk = phase[1];
    assign ws   = bit_cnt[5];

    // read SD one clk after bclk falls, in the middle of the time it is stable
    assign sample_en = (phase == 2'd0);
    assign slot      = bit_cnt;

endmodule
