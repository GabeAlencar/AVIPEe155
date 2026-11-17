/*
 * Module: fpga_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 *
 * Top level of the FPGA. Holds only module instances:
 *   i2s_receiver - reads 18-bit samples from the SPH0645 mic (46.875 kHz)
 *   sum_of_3     - adds each group of 3 samples (15.625 kHz, 20 bits)
 *   dc_removal   - subtracts a running average and saturates to 16 bits
 *   ring_buffer  - keeps the last 512 samples in block RAM and pulses
 *                  frame_ready every 312 samples (20 ms)
 *
 * After frame_ready, read_index 0 to 511 reads the latest 512 samples,
 * oldest first, on read_data one clk later. These ports stand in for the
 * FFT frame copy until it is written. The FFT and SPI will be added here.
 */

module fpga_top (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        sd,
    output logic        bclk,
    output logic        ws,
    input  logic [8:0]  read_index,
    output logic [15:0] read_data,
    output logic        frame_ready
);

    logic [17:0] sample;
    logic        sample_valid;
    logic [19:0] sum;
    logic        sum_valid;
    logic [15:0] pcm;
    logic        pcm_valid;

    // mic samples over I2S, left channel (SEL tied to GND)
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    // 46.875 kHz to 15.625 kHz
    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    // remove the DC offset, 16-bit output
    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    // last 512 samples, a new frame every 312 samples
    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

endmodule
