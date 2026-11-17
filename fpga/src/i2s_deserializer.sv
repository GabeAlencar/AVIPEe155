/*
 * Module: i2s_deserializer
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   DATA_WIDTH - number of bits kept from each word, starting at the MSB.
 *   CHANNEL    - 0 for the left channel (ws low), 1 for the right (ws high).
 *
 * Shifts in one channel of I2S data, MSB first. In each 32 bit half
 * frame, slot 0 is the one bclk delay after ws changes, and the MSB is in
 * slot 1. The SPH0645 sends a 24 bit word with 18 bits of precision, so
 * DATA_WIDTH = 18 keeps every bit that carries data.
 *
 * sample is a two's complement word that updates once per frame, and
 * sample_valid pulses for one clk when it does.
 */

module i2s_deserializer #(
    parameter int DATA_WIDTH = 18,
    parameter bit CHANNEL    = 1'b0
) (
    input  logic              clk,
    input  logic              reset_b,
    input  logic              sample_en,
    input  logic [5:0]        slot,
    input  logic              sd,
    output logic [DATA_WIDTH-1:0] sample,
    output logic              sample_valid
);

    logic [DATA_WIDTH-1:0] shift;
    logic              in_channel, shift_en, last_bit;

    // slot is in this channel's half of the frame
    assign in_channel = (slot[5] == CHANNEL);

    // shift slots 1 to DATA_WIDTH, the last one completes the word
    assign shift_en = sample_en & in_channel & (slot[4:0] >= 5'd1) & (slot[4:0] <= DATA_WIDTH[4:0]);
    assign last_bit = shift_en & (slot[4:0] == DATA_WIDTH[4:0]);

    // ---- shift register ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b) shift <= '0;
        else if (shift_en) shift <= {shift[DATA_WIDTH-2:0], sd};

    // ---- output register ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            sample       <= '0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= last_bit;
            if (last_bit) sample <= {shift[DATA_WIDTH-2:0], sd};
        end

endmodule
