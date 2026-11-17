/*
 * Module: i2s_deserializer
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   DATA_WIDTH - number of bits kept from each word, starting at the MSB.
 *   CHANNEL    - 0 for the left channel (ws low), 1 for the right (ws high).
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

    // ---- shift register: holds the finished word until the next frame ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b) shift <= '0;
        else if (shift_en) shift <= {shift[DATA_WIDTH-2:0], sd};

    assign sample = shift;

    // sample_valid pulses the clk after the last bit is shifted in
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) sample_valid <= 1'b0;
        else          sample_valid <= last_bit;

endmodule
