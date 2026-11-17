/*
 * Module: i2s_receiver
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   DATA_WIDTH - number of bits kept from each word, starting at the MSB.
 *   CHANNEL    - 0 for the left channel (ws low), 1 for the right (ws high).
 *
 * I2S receiver for the SPH0645 microphone. The FPGA is the I2S master:
 * it drives bclk (3 MHz) and ws (46.875 kHz) from the 12 MHz clock and
 * reads sd. The mic's SEL pin is tied to GND, so it sends on the left
 * channel.
 *
 * Outputs one DATA_WIDTH bit two's complement sample per frame
 * (46.875 kHz), with a one clk sample_valid strobe.
 */

module i2s_receiver #(
    parameter int DATA_WIDTH = 18,
    parameter bit CHANNEL    = 1'b0
) (
    input  logic              clk,
    input  logic              reset_b,
    input  logic              sd,
    output logic              bclk,
    output logic              ws,
    output logic [DATA_WIDTH-1:0] sample,
    output logic              sample_valid
);

    logic       sample_en;
    logic [5:0] slot;

    // bclk, ws, and the bit timing
    i2s_clkgen u_i2s_clkgen (.clk(clk), .reset_b(reset_b), .bclk(bclk), .ws(ws), .sample_en(sample_en), .slot(slot));

    // serial to parallel. sd needs no synchronizer: the FPGA drives bclk,
    // so sd only changes just after bclk rises and is stable when read.
    i2s_deserializer #(.DATA_WIDTH(DATA_WIDTH), .CHANNEL(CHANNEL)) u_i2s_deserializer (.clk(clk), .reset_b(reset_b), .sample_en(sample_en), .slot(slot), .sd(sd), .sample(sample), .sample_valid(sample_valid));

endmodule
