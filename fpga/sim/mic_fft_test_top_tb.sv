/*
 * Testbench: mic_fft_test_top_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/15/26
 *
 * Runs mic_fft_test_top with an SPH0645 model (from mic_hw_test_top_tb)
 * playing two tones, and writes:
 *   +UART=file   every byte the design sends over uart_tx, one hex byte a line
 *   +PCM=file    every pcm sample the model of sum_of_3 + dc_removal expects
 * fpga/model/fft_capture.py check then finds the packets and checks the
 * checksums, that each input frame is 512 consecutive pcm samples, and that
 * each fft output equals fft_fixed.py bit for bit. Stops after PACKETS
 * packets.
 */
`timescale 1ns/1ps
module mic_fft_test_top_tb();
  logic       reset_b;
  tri0        sd;
  logic       bclk, ws;
  logic [4:0] bar;
  logic       led_heartbeat, led_clip;
  logic       uart_tx;

  localparam real PI      = 3.14159265358979;
  localparam int  PACKETS = 3;
  localparam int  PACKET_BYTES = 3080;

  mic_fft_test_top dut (.reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .bar(bar), .led_heartbeat(led_heartbeat), .led_clip(led_clip), .uart_tx(uart_tx));

  // ---- model of sum_of_3 and dc_removal (same as fpga_top_tb) ----
  int     group_count, group_sum;
  longint average_acc;
  int     fpcm;

  function automatic int clamp(input longint value);
    if (value > 32767)  return 32767;
    if (value < -32768) return -32768;
    return int'(value);
  endfunction

  task automatic model_word(input logic [17:0] w);
    longint average;
    group_sum += $signed(w);
    group_count++;
    if (group_count == 3) begin
      average = average_acc >>> 10;
      $fwrite(fpcm, "%0d\n", clamp(group_sum - average));
      average_acc = average_acc + group_sum - average;
      group_sum   = 0;
      group_count = 0;
    end
  endtask

  // ---- SPH0645 model (same as mic_hw_test_top_tb) ----
  localparam real THTR = 7.0;
  localparam real TDC  = 40.0;
  logic        sd_drv, sd_oe;
  logic [17:0] word;
  int          bitn, n_word;
  logic        ws_d;

  assign sd = sd_oe ? sd_drv : 1'bz;

  // 1 kHz at 6000 LSB plus 3.1 kHz at 2000 LSB on a -3000 offset (18-bit
  // words at 46,875 Hz); sum_of_3 makes them about 3x bigger in pcm
  function automatic logic [17:0] mic_word(input int n);
    real t;
    t = n / 46875.0;
    return 18'(-3000 + int'(6000 * $sin(2.0 * PI * 1000.0 * t) + 2000 * $sin(2.0 * PI * 3100.0 * t)));
  endfunction

  initial begin
    sd_oe = 0; sd_drv = 0; bitn = 0; ws_d = 0; n_word = 0;
    group_count = 0; group_sum = 0; average_acc = 0;
  end

  always @(posedge bclk) if (reset_b === 1'b1) begin
    if (ws != ws_d) bitn = 1;
    else            bitn++;
    ws_d = ws;

    if (ws == 0 && bitn == 1) begin
      word = mic_word(n_word++);
      model_word(word);
    end

    #(THTR);
    if (sd_oe) sd_drv = 1'bx;
    #(TDC - THTR);

    if (ws == 0 && bitn >= 1 && bitn <= 18) begin
      sd_oe = 1; sd_drv = word[18 - bitn];
    end else if (ws == 0 && bitn >= 19 && bitn <= 24) begin
      sd_oe = 1; sd_drv = 1'b0;
    end else begin
      sd_oe = 0;
    end
  end

  // ---- UART reader: 8N1 at clk / 16 ----
  localparam real BIT_NS = 16 * 4 * 2 * 10.4167;   // 16 clk of 12 MHz from hsosc_sim
  int fuart, n_bytes, bad_stop;
  initial begin n_bytes = 0; bad_stop = 0; end

  always @(negedge uart_tx) if (reset_b === 1'b1) begin : uart_byte
    logic [7:0] b;
    #(BIT_NS * 1.5);
    for (int i = 0; i < 8; i++) begin b[i] = uart_tx; #(BIT_NS); end
    if (uart_tx !== 1'b1) bad_stop++;
    $fwrite(fuart, "%02h\n", b);
    n_bytes++;
  end

  int toggles;
  initial toggles = 0;
  always @(led_heartbeat) if (reset_b === 1'b1) toggles++;

  initial begin
    string uart_file, pcm_file;
    if (!$value$plusargs("UART=%s", uart_file)) uart_file = "uart.hex";
    if (!$value$plusargs("PCM=%s", pcm_file))   pcm_file  = "pcm.txt";
    fuart = $fopen(uart_file, "w");
    fpcm  = $fopen(pcm_file, "w");
    reset_b = 0;
    #500;
    reset_b = 1;
    wait (n_bytes == PACKETS * PACKET_BYTES);
    #(BIT_NS * 20);
    $fclose(fuart); $fclose(fpcm);
    $display("mic_fft_test_top_tb: %0d bytes, %0d bad stop bits, heartbeat toggled %0d times, %0t", n_bytes, bad_stop, toggles, $time);
    $finish;
  end
endmodule
