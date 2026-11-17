/*
 * Module: mic_hw_test_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Parameters:
 *   HEARTBEAT_FRAMES - frames between heartbeat LED toggles. 25 frames at
 *                      50 frames/s blinks it at 1 Hz.
 *   SCK_HALF         - clk cycles per half sck period on both test ports.
 *                      4 gives 1.5 MHz.
 *
 * Hardware test top level for the UPduino with the SPH0645 connected. Uses
 * the same chain as fpga_top with the same parameters (i2s_receiver,
 * sum_of_3, dc_removal, ring_buffer), clocked by the internal oscillator
 * like fpga_board_top. Four tests run at once:
 *
 *   1. heartbeat   led_heartbeat toggles every HEARTBEAT_FRAMES frame_ready
 *                  pulses, so it blinks at 1 Hz if the mic clocks, I2S
 *                  receiver, sum, DC removal, and ring buffer all run.
 *   2. VU meter    bar[4:0] show the level of pcm on 5 LEDs with a
 *                  peak-hold dot, and led_clip lights when pcm saturates.
 *   3. pcm stream  every pcm sample goes out on pcm_sck / pcm_sdo /
 *                  pcm_cs_b as one 16-bit SPI word (mode 0, MSB first),
 *                  15,625 words/s.
 *   4. frame dump  every frame goes out on frm_sck / frm_sdo / frm_cs_b:
 *                  the frame number, then the 512 samples oldest first,
 *                  all in one cs_b low period, 50 frames/s.
 *   5. pcm to PC   every pcm sample also goes to the PC over the UPduino's
 *                  USB serial port (uart_tx on pin 14), see pcm_uart.
 *
 * Capture bclk, ws, sd and the two test ports on a logic analyzer and check
 * them with fpga/model/hw_capture.py, or read test 5 with
 * fpga/model/serial_capture.py and fpga/model/hw_fft.ipynb.
 */

module mic_hw_test_top #(
    parameter int HEARTBEAT_FRAMES = 25,
    parameter int SCK_HALF         = 4
) (
    input  logic       reset_b,
    input  logic       sd,
    output logic       bclk,
    output logic       ws,
    output logic [4:0] bar,
    output logic       led_heartbeat,
    output logic       led_clip,
    output logic       pcm_sck,
    output logic       pcm_sdo,
    output logic       pcm_cs_b,
    output logic       frm_sck,
    output logic       frm_sdo,
    output logic       frm_cs_b,
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
    logic        pcm_busy;
    logic [$clog2(HEARTBEAT_FRAMES)-1:0] frame_count;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    // ---- the chain, same as fpga_top ----
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

    // ---- test 1: heartbeat ----
    counter #(.WIDTH($clog2(HEARTBEAT_FRAMES)), .MAX(HEARTBEAT_FRAMES - 1)) u_frame_counter (.clk(clk), .reset_b(reset_b), .enable(frame_ready), .count(frame_count));

    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)                                                 led_heartbeat <= 1'b0;
        else if (frame_ready && frame_count == HEARTBEAT_FRAMES - 1) led_heartbeat <= ~led_heartbeat;

    // ---- test 2: VU meter ----
    level_meter #(.N(5)) u_level_meter (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .led(bar), .clip(led_clip));

    // ---- test 3: pcm stream, one word per sample (128 clk of the 768 between samples) ----
    spi_word_tx #(.WIDTH(16), .HALF_PERIOD(SCK_HALF)) u_pcm_tx (.clk(clk), .reset_b(reset_b), .start(pcm_valid), .data(pcm), .busy(pcm_busy), .sck(pcm_sck), .sdo(pcm_sdo));
    assign pcm_cs_b = ~pcm_busy;

    // ---- test 4: frame dump ----
    frame_dumper #(.ADDR_WIDTH(9), .HALF_PERIOD(SCK_HALF)) u_frame_dumper (.clk(clk), .reset_b(reset_b), .frame_ready(frame_ready), .read_index(read_index), .read_data(read_data), .sck(frm_sck), .sdo(frm_sdo), .cs_b(frm_cs_b));

    // ---- test 5: every pcm sample to the PC over the FTDI serial port ----
    pcm_uart #(.CLKS_PER_BIT(16)) u_pcm_uart (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .tx(uart_tx));

endmodule
