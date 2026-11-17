/*
 * Testbench: fpga_top_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 *
 * Runs fpga_top with an SPH0645 model playing two tones and acts as the SPI
 * receiver (mode 0, 16-bit words) and the PC's UART receiver.
 * Checks in this testbench:
 *   - each frame (cs_b low to cs_b high) is 514 words with a whole number
 *     of 16-bit words
 *   - mosi only changes while sck is low (stable at every rising edge)
 *   - sck runs at 3 MHz and stays low while cs_b is high
 *   - fft_busy rises before each frame and is low while it is sent
 *   - the UART sends 1,030 bytes per frame with good stop bits
 * and writes, for fpga/model/fft_spi_check.py:
 *   +SPI=file   each frame's words, one hex word a line, a blank line after each frame
 *   +IN=file    the 512 samples that went into the fft for each frame (read
 *               from inside the design), one frame a line
 *   +UART=file  every byte on uart_tx, one hex byte a line
 *   +PCM=file   every pcm sample the model of sum_of_3 + dc_removal expects
 * Then, from fpga/model:
 *   python fft_spi_check.py spi.hex in.txt pcm.txt    each SPI frame vs fft_fixed.py, bit for bit
 *   python fft_live.py --check uart.hex --spi spi.hex each UART frame equals its SPI frame
 * Stops after FRAMES frames.
 */
`timescale 1ns/1ps
module fpga_top_tb();
  logic       reset_b;
  tri0        sd;
  logic       bclk, ws;
  logic       spi_sck, spi_mosi, spi_cs_b, fft_busy, uart_tx;

  localparam real PI     = 3.14159265358979;
  localparam int  FRAMES = 4;
  localparam int  WORDS  = 514;

  fpga_top dut (.reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_cs_b(spi_cs_b), .fft_busy(fft_busy),
                .uart_tx(uart_tx));

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

  // ---- SPH0645 model ----
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

  // ---- input frames, read from inside the design ----
  int fin, n_loaded;
  initial n_loaded = 0;
  always @(posedge dut.clk) if (dut.u_fft_controller.load_v) begin
    $fwrite(fin, "%0d ", $signed(dut.read_data));
    n_loaded++;
    if (n_loaded % 512 == 0) $fwrite(fin, "\n");
  end

  // ---- SPI receiver, mode 0 ----
  int          fspi, n_frames, n_bits, n_words, errors;
  logic [15:0] shreg;
  realtime     t_rise, period;
  logic        busy_seen;
  initial begin n_frames = 0; n_bits = 0; n_words = 0; errors = 0; t_rise = 0; busy_seen = 0; end

  always @(posedge spi_sck) if (reset_b === 1'b1) begin
    if (spi_cs_b !== 1'b0) begin errors++; $display("ERROR: sck rose with cs_b high at %0t", $time); end
    if (t_rise != 0 && n_bits % 16 != 0) begin
      period = $realtime - t_rise;
      if (period < 330.0 || period > 337.0) begin errors++; $display("ERROR: sck period %0.1f ns at %0t", period, $time); end
    end
    t_rise = $realtime;
    shreg = {shreg[14:0], spi_mosi};
    n_bits++;
    if (n_bits % 16 == 0) begin
      $fwrite(fspi, "%04h\n", shreg);
      n_words++;
    end
  end

  always @(spi_mosi) if (reset_b === 1'b1 && spi_cs_b === 1'b0 && spi_sck === 1'b1) begin
    errors++; $display("ERROR: mosi changed while sck high at %0t", $time);
  end

  always @(posedge fft_busy) busy_seen = 1;

  always @(negedge spi_cs_b) if (reset_b === 1'b1) begin
    n_bits = 0; n_words = 0; t_rise = 0;
    if (!busy_seen) begin errors++; $display("ERROR: frame without fft_busy first"); end
    busy_seen = 0;
  end

  always @(posedge spi_cs_b) if (reset_b === 1'b1) begin
    if (n_words != WORDS || n_bits != 16 * WORDS) begin
      errors++; $display("ERROR: frame %0d had %0d bits (%0d words)", n_frames, n_bits, n_words);
    end
    $fwrite(fspi, "\n");
    n_frames++;
    $display("frame %0d: %0d words, cs_b high at %0t", n_frames, n_words, $time);
  end

  always @(posedge spi_sck) if (fft_busy) begin errors++; $display("ERROR: fft_busy high during a frame"); end

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

  initial begin
    string uart_file;
    if (!$value$plusargs("UART=%s", uart_file)) uart_file = "uart.hex";
    fuart = $fopen(uart_file, "w");
  end

  initial begin
    string spi_file, in_file, pcm_file;
    realtime t_cs;
    if (!$value$plusargs("SPI=%s", spi_file)) spi_file = "spi.hex";
    if (!$value$plusargs("IN=%s", in_file))   in_file  = "in.txt";
    if (!$value$plusargs("PCM=%s", pcm_file)) pcm_file = "pcm.txt";
    fspi = $fopen(spi_file, "w");
    fin  = $fopen(in_file, "w");
    fpcm = $fopen(pcm_file, "w");
    reset_b = 0;
    #500;
    reset_b = 1;
    wait (n_frames == FRAMES);
    wait (n_bytes >= FRAMES * 1030);
    #(BIT_NS * 20);
    if (n_bytes != FRAMES * 1030 || bad_stop != 0) begin errors++; $display("ERROR: %0d uart bytes (expected %0d), %0d bad stop bits", n_bytes, FRAMES * 1030, bad_stop); end
    $fclose(fuart);
    if (spi_sck !== 1'b0 || spi_cs_b !== 1'b1) begin errors++; $display("ERROR: sck/cs_b not idle after frame"); end
    $fclose(fspi); $fclose(fin); $fclose(fpcm);
    $display("fpga_top_tb: %0d frames, %0d errors, %0t", n_frames, errors, $time);
    if (errors == 0) $display("PASSED"); else $display("FAILED");
    $finish;
  end
endmodule
