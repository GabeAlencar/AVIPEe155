/*
 * Module: fpga_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT  - fft scaling, see fft_butterfly. 1 for 16-bit pcm
 *                  (output = FFT / 512).
 *   SCK_HALF     - clk cycles per half sck period. 2 gives a 3 MHz sck.
 *   CLKS_PER_BIT - clk cycles per UART bit. 16 gives 750 kbaud.
 */

module fpga_top #(
    parameter int STAGE_SHIFT  = 1,
    parameter int SCK_HALF     = 2,
    parameter int CLKS_PER_BIT = 16
) (
    input  logic       reset_b,
    // SPH0645 mic
    input  logic       sd,
    output logic       bclk,
    output logic       ws,
    // fft output, SPI master
    output logic       spi_sck,
    output logic       spi_mosi,
    output logic       spi_cs_b,
    output logic       fft_busy,
    // fft output to the PC
    output logic       uart_tx
);

    logic        clk;
    logic [17:0] sample;
    logic        sample_valid;
    logic [19:0] sum;
    logic        sum_valid;
    logic [15:0] pcm;
    logic        pcm_valid;
    logic [8:0]  read_index;
    logic [15:0] read_data;
    logic        frame_ready;
    logic        bin_we, bins_done;
    logic [7:0]  bin_addr, frame_num;
    logic [31:0] bin_data;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    // ---- mic to frames ----
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    // 46.875 kHz to 15.625 kHz
    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    // remove the DC offset, 16-bit output
    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    // last 512 samples, a new frame every 312 samples
    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

    // ---- fft ----
    fft_controller #(.STAGE_SHIFT(STAGE_SHIFT)) u_fft_controller (.clk(clk), .reset_b(reset_b), .frame_ready(frame_ready), .read_index(read_index), .read_data(read_data), .bin_we(bin_we), .bin_addr(bin_addr), .bin_data(bin_data), .bins_done(bins_done), .frame_num(frame_num), .fft_busy(fft_busy));

    // ---- output drivers ----
    spi_frame_tx #(.STAGE_SHIFT(STAGE_SHIFT), .HALF_PERIOD(SCK_HALF)) u_spi_frame_tx (.clk(clk), .reset_b(reset_b), .we(bin_we), .waddr(bin_addr), .wdata(bin_data), .send(bins_done), .frame_num(frame_num), .sck(spi_sck), .mosi(spi_mosi), .cs_b(spi_cs_b));

    uart_frame_tx #(.STAGE_SHIFT(STAGE_SHIFT), .CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_frame_tx (.clk(clk), .reset_b(reset_b), .we(bin_we), .waddr(bin_addr), .wdata(bin_data), .send(bins_done), .frame_num(frame_num), .tx(uart_tx));
endmodule
