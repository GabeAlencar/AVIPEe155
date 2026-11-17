/*
 * Module: dc_removal
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   IN_WIDTH      - width of each two's complement input sum.
 *   OUT_WIDTH     - width of each two's complement output PCM sample.
 *   AVERAGE_SHIFT - the running average moves 1/2^AVERAGE_SHIFT of the way
 *                   to each new sample.
 */

module dc_removal #(
    parameter int IN_WIDTH      = 20,
    parameter int OUT_WIDTH     = 16,
    parameter int AVERAGE_SHIFT = 10
) (
    input  logic                       clk,
    input  logic                       reset_b,
    input  logic signed [IN_WIDTH-1:0] sum,
    input  logic                       sum_valid,
    output logic        [OUT_WIDTH-1:0] pcm,
    output logic                       pcm_valid
);

    localparam int PCM_MAX = 2**(OUT_WIDTH-1) - 1;
    localparam int PCM_MIN = -(2**(OUT_WIDTH-1));

    logic signed [IN_WIDTH+AVERAGE_SHIFT:0] average_acc;  // running average with AVERAGE_SHIFT fraction bits
    logic signed [IN_WIDTH:0]               average;      // running average, whole part
    logic signed [IN_WIDTH:0]               difference;   // sum with the DC removed

    assign average    = average_acc >>> AVERAGE_SHIFT;
    assign difference = sum - average;

    // ---- running average: moves difference / 2^AVERAGE_SHIFT each sample ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)  average_acc <= '0;
        else if (sum_valid) average_acc <= average_acc + difference;

    // ---- output: difference clamped to OUT_WIDTH bits ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            pcm       <= '0;
            pcm_valid <= 1'b0;
        end else begin
            pcm_valid <= sum_valid;
            if (sum_valid)
                pcm <= (difference > PCM_MAX) ? OUT_WIDTH'(PCM_MAX) :
                       (difference < PCM_MIN) ? OUT_WIDTH'(PCM_MIN) :
                                                difference[OUT_WIDTH-1:0];
        end

endmodule