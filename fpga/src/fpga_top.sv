/*
 * Module: fpga_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT  - fft scaling, see fft_butterfly. 1 for 16-bit pcm
 *                  (output = FFT / 512).
 *   SCK_HALF     - clk cycles per half sck period. 2 gives a 3 MHz sck.
 *   CLKS_PER_BIT - clk cycles per UART bit. 16 gives 750 kbaud.
 *
 * Top level of the FPGA. Holds the module instances and the heartbeat LED
 * counter:
 *
 *   SPH0645 -> i2s_receiver -> sum_of_3 -> dc_removal -> ring_buffer
 *           -> fft_controller (Katie's fft) -> spi_frame_tx  -> MCU / scope
 *                                           -> uart_frame_tx -> PC (USB)
 *
 *   HSOSC          - 48 MHz internal oscillator / 4 = 12 MHz clk
 *   i2s_receiver   - reads 18-bit samples from the SPH0645 mic (46.875 kHz)
 *   sum_of_3       - adds each group of 3 samples (15.625 kHz, 20 bits)
 *   dc_removal     - subtracts a running average and saturates to 16 bits
 *   ring_buffer    - keeps the last 512 samples in block RAM and pulses
 *                    frame_ready every 312 samples (20 ms)
 *   fft_controller - loads each frame into the fft, runs it, and reads out
 *                    X[0..255]
 *   spi_frame_tx   - sends each frame as an SPI master (mode 0, 16-bit words)
 *   uart_frame_tx  - sends the same frame to the PC over the USB serial port
 *   level_meter    - LED bar and clip light from the pcm level
 *
 * Frame format (both drivers): A55A, {frame number, STAGE_SHIFT}, then
 * re X[k], im X[k] for k = 0..255. The UART adds a 16-bit checksum word.
 * Read it on a PC with fpga/model/fft_live.py.
 *
 * LEDs: led_heartbeat toggles every 25 frames, so it blinks once a second
 * while the mic and ring buffer are running.
 *
 * HSOSC is accurate to about +/-10%, so the sample rate and the FFT bin
 * frequencies can be up to 10% off (this board measured 15,670 Hz).
 * Testbenches compile fpga/sim/hsosc_sim.sv in place of the Lattice HSOSC.
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
    output logic       uart_tx,
    // LEDs
    output logic [4:0] bar,
    output logic       led_heartbeat,
    output logic       led_clip
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
    logic [4:0]  hb_count;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    // ---- mic to frames ----
    // mic samples over I2S, left channel (SEL tied to GND)
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    // 46.875 kHz to 15.625 kHz
    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    // remove the DC offset, 16-bit output
    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    // last 512 samples, a new frame every 312 samples
    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

    // ---- fft ----
    fft_controller #(.STAGE_SHIFT(STAGE_SHIFT)) u_fft_controller (.clk(clk), .reset_b(reset_b), .frame_ready(frame_ready), .read_index(read_index), .read_data(read_data),
                                                                   .bin_we(bin_we), .bin_addr(bin_addr), .bin_data(bin_data), .bins_done(bins_done), .frame_num(frame_num), .fft_busy(fft_busy));

    // ---- output drivers ----
    spi_frame_tx #(.STAGE_SHIFT(STAGE_SHIFT), .HALF_PERIOD(SCK_HALF)) u_spi_frame_tx (.clk(clk), .reset_b(reset_b), .we(bin_we), .waddr(bin_addr), .wdata(bin_data), .send(bins_done), .frame_num(frame_num),
                                                                                       .sck(spi_sck), .mosi(spi_mosi), .cs_b(spi_cs_b));

    uart_frame_tx #(.STAGE_SHIFT(STAGE_SHIFT), .CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_frame_tx (.clk(clk), .reset_b(reset_b), .we(bin_we), .waddr(bin_addr), .wdata(bin_data), .send(bins_done), .frame_num(frame_num),
                                                                                              .tx(uart_tx));

    // ---- LEDs ----
    level_meter #(.N(5)) u_level_meter (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .led(bar), .clip(led_clip));

    // heartbeat: toggles every 25 frames (0.5 s at 50 frames/s)
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            led_heartbeat <= 1'b0;
            hb_count      <= '0;
        end else if (frame_ready)
            if (hb_count == 5'd24) begin
                hb_count      <= '0;
                led_heartbeat <= ~led_heartbeat;
            end else hb_count <= hb_count + 1'b1;

endmodule
