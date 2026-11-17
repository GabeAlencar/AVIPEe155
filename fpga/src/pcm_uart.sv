/*
 * Module: pcm_uart
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Parameters:
 *   CLKS_PER_BIT - clk cycles per UART bit (16 gives 750 kbaud).
 *
 * Hardware test. Sends every pcm sample to the PC over the UPduino's FTDI
 * serial port (FPGA pin 14 drives the FT232H RXD). Each sample is 3 bytes:
 *   byte 0  1 p[15:9]          the top bit marks the first byte of a sample
 *   byte 1  0 p[8:2]
 *   byte 2  0 n[4:0] p[1:0]    n counts samples, so the PC can spot drops
 * 3 bytes take 30 bits * 16 = 480 clk, less than the 768 clk between
 * samples, so no sample is skipped. 15,625 samples/s is 46,875 bytes/s.
 *
 * The internal oscillator can be a few percent off, so the PC finds the
 * real baud rate by trying rates until the stream decodes cleanly. That
 * also gives the real clk, and the sample rate is clk / 768.
 */

module pcm_uart #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic [15:0] pcm,
    input  logic        pcm_valid,
    output logic        tx
);

    logic [23:0] pending;     // bytes still to send, next one on top
    logic [1:0]  left;        // number of bytes in pending
    logic [4:0]  sample_num;
    logic        start, busy;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (.clk(clk), .reset_b(reset_b), .start(start), .data(pending[23:16]), .busy(busy), .tx(tx));

    assign start = (left != 2'd0) & ~busy;

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            pending    <= '0;
            left       <= '0;
            sample_num <= '0;
        end else if (pcm_valid) begin
            pending    <= {1'b1, pcm[15:9], 1'b0, pcm[8:2], 1'b0, sample_num, pcm[1:0]};
            left       <= 2'd3;
            sample_num <= sample_num + 1'b1;
        end else if (start) begin
            pending <= pending << 8;
            left    <= left - 1'b1;
        end

endmodule
