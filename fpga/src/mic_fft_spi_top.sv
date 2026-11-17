/*
 * Module: mic_fft_spi_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT - fft scaling, see fft_butterfly. 1 for 16-bit pcm.
 *   SCK_HALF    - clk cycles per half sck period. 2 gives a 3 MHz sck.
 *
 * The mic chain and Katie's FFT with the result going out over SPI:
 *
 *   SPH0645 -> i2s_receiver -> sum_of_3 -> dc_removal -> ring_buffer -> fft -> SPI
 *
 * Every frame the ring buffer finishes (50 a second), fft_frame_spi runs
 * the fft and sends X[0..255] on spi_sck / spi_sdo / spi_cs_b as an SPI
 * master in mode 0 (frame format in fft_frame_spi). fft_busy is high while
 * the fft runs, a good scope trigger. The same frames, with a checksum word,
 * also go to the PC on uart_tx (pin 14, the UPduino's USB serial port at
 * 750 kbaud); read them live with fpga/model/fft_live.py or hw_fft_full.ipynb.
 *
 * LEDs: bar[4:0] and led_clip are the VU meter (level_meter).
 * led_heartbeat (D6) toggles every 25 frames, so it blinks once a second
 * while the mic chain and ring buffer are running.
 */

module mic_fft_spi_top #(
    parameter int STAGE_SHIFT = 1,
    parameter int SCK_HALF    = 2
) (
    input  logic       reset_b,
    input  logic       sd,
    output logic       bclk,
    output logic       ws,
    output logic [4:0] bar,
    output logic       led_heartbeat,
    output logic       led_clip,
    output logic       spi_sck,
    output logic       spi_sdo,
    output logic       spi_cs_b,
    output logic       fft_busy,
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
    logic [4:0]  hb_count;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    // ---- the chain, same as fpga_top ----
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

    // ---- ring buffer -> fft -> SPI ----
    fft_frame_spi #(.STAGE_SHIFT(STAGE_SHIFT), .HALF_PERIOD(SCK_HALF)) u_fft_frame_spi (.clk(clk), .reset_b(reset_b), .frame_ready(frame_ready), .read_index(read_index), .read_data(read_data), .sck(spi_sck), .sdo(spi_sdo), .cs_b(spi_cs_b), .fft_busy(fft_busy), .uart_tx(uart_tx));

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
