/*
 * Module: dc_removal
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   IN_WIDTH      - width of each two's complement input sum.
 *   OUT_WIDTH     - width of each two's complement output PCM sample.
 *   AVERAGE_SHIFT - the running average moves 1/2^AVERAGE_SHIFT of the way
 *                   to each new sample. 10 gives a time constant of 1024
 *                   samples (65.5 ms at 15.625 kHz), a 2.4 Hz cutoff.
 *
 * Removes the microphone's DC offset by subtracting a slow running
 * average, then saturates the result to OUT_WIDTH bits. Keeping the low
 * OUT_WIDTH bits instead of the top ones gives the samples more gain.
 *
 * The running average is kept with AVERAGE_SHIFT extra fraction bits:
 *   average_acc = average * 2^AVERAGE_SHIFT
 *   average_acc <= average_acc + sum - average
 * Each sum is read in the clk cycle that sum_valid is high. pcm updates
 * one clk later, and pcm_valid pulses for one clk when it does.
 */

module dc_removal #(
    parameter int IN_WIDTH      = 20,
    parameter int OUT_WIDTH     = 16,
    parameter int AVERAGE_SHIFT = 10
) (
    input  logic                 clk,
    input  logic                 reset_b,
    input  logic [IN_WIDTH-1:0]  sum,
    input  logic                 sum_valid,
    output logic [OUT_WIDTH-1:0] pcm,
    output logic                 pcm_valid
);

    localparam int ACC_WIDTH  = IN_WIDTH + AVERAGE_SHIFT + 1;
    localparam int DIFF_WIDTH = IN_WIDTH + 1;
    localparam int PCM_MAX    = 2**(OUT_WIDTH-1) - 1;
    localparam int PCM_MIN    = -(2**(OUT_WIDTH-1));

    logic signed [IN_WIDTH-1:0]   sample;       // signed view of sum
    logic signed [ACC_WIDTH-1:0]  average_acc;  // running average with fraction bits
    logic signed [DIFF_WIDTH-1:0] average;      // running average, whole part
    logic signed [DIFF_WIDTH-1:0] difference;   // sample with the DC removed
    logic        [OUT_WIDTH-1:0]  saturated;

    assign sample     = sum;
    assign average    = average_acc >>> AVERAGE_SHIFT;
    assign difference = sample - average;

    // clamp to the largest and most negative OUT_WIDTH bit values
    assign saturated  = (difference > PCM_MAX) ? PCM_MAX[OUT_WIDTH-1:0] :
                        (difference < PCM_MIN) ? PCM_MIN[OUT_WIDTH-1:0] :
                                                 difference[OUT_WIDTH-1:0];

    // ---- running average ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)  average_acc <= '0;
        else if (sum_valid) average_acc <= average_acc + sample - average;

    // ---- output register ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            pcm       <= '0;
            pcm_valid <= 1'b0;
        end else begin
            pcm_valid <= sum_valid;
            if (sum_valid) pcm <= saturated;
        end

endmodule
