`timescale 1 ns/1 ps

/*
 * Testbench: fpga_top_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: Runs the whole FPGA at the real 12 MHz clock against the same
 *   SPH0645 microphone model as i2s_receiver_tb (datasheet timing, SEL
 *   tied to GND). Each word the microphone sends also goes into a model of
 *   the sum of 3 and the DC removal, which keeps a list of every pcm value
 *   in order. On each frame_ready the testbench reads the frame through
 *   read_index like the FFT frame copy will, and checks it against the
 *   last 512 values of that list. Nothing inside fpga_top is used for the
 *   checks.
 */

module fpga_top_tb();
  logic        clk;
  logic        reset_b;
  tri0         sd;           // pulled low while the mic tri-states
  logic        bclk;
  logic        ws;
  logic [8:0]  read_index;
  logic [15:0] read_data;
  logic        frame_ready;
  int          errors = 0;

  localparam real CLK_HALF    = 41.667;   // 12 MHz
  localparam real PI          = 3.14159265358979;
  localparam int  DEPTH       = 512;
  localparam int  HOP_SAMPLES = 312;

  fpga_top dut (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

  // generate clock
  always begin
      clk = 0; #(CLK_HALF);
      clk = 1; #(CLK_HALF);
  end

  task automatic check(input logic ok, input string what);
    if (ok)
      $display("PASSED! %s at time: %0t.", what, $time);
    else begin
      errors++;
      $error("FAILED! %s at time: %0t.", what, $time);
    end
  endtask

  // ---- model of sum_of_3 and dc_removal, fed by the mic model ----
  int     group_count, group_sum;
  longint average_acc;
  int     expected_pcm[$];   // every pcm value since reset, in order

  function automatic int clamp(input longint value);
    if (value > 32767)  return 32767;
    if (value < -32768) return -32768;
    return int'(value);
  endfunction

  task automatic model_word(input logic [17:0] word);
    longint average;
    group_sum += $signed(word);
    group_count++;
    if (group_count == 3) begin
      average = average_acc >>> 10;
      expected_pcm.push_back(clamp(group_sum - average));
      average_acc = average_acc + group_sum - average;
      group_sum   = 0;
      group_count = 0;
    end
  endtask

  task automatic model_reset();
    group_count = 0; group_sum = 0; average_acc = 0;
    expected_pcm.delete();
  endtask

  // ---- SPH0645 model (same as i2s_receiver_tb) ----
  localparam real THTR = 7.0;     // datasheet: data held at least 7 ns after bclk rises
  localparam real TDC  = 40.0;    // delay from bclk rising to new SD data, ns (max 65.92)
  logic        sd_drv, sd_oe;
  logic [17:0] to_send[$];   // words the test wants sent next
  logic [17:0] word;
  int          bitn;
  logic        ws_d;

  assign sd = sd_oe ? sd_drv : 1'bz;

  initial begin
    sd_oe = 0; sd_drv = 0; bitn = 0; ws_d = 0;
  end

  // after reset the receiver starts a new frame in slot 0
  always @(negedge reset_b) begin
    bitn = 0;
    ws_d = 0;
    sd_oe = 0;
    model_reset();
  end

  always @(posedge bclk) if (reset_b === 1'b1) begin
    if (ws != ws_d) bitn = 1;
    else            bitn++;
    ws_d = ws;

    // pick the word for this left channel half frame
    if (ws == 0 && bitn == 1) begin
      word = (to_send.size() > 0) ? to_send.pop_front() : 18'($urandom);
      model_word(word);
    end

    // hold the old bit, then SD is unknown until the new bit is ready
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

  // ---- frame_ready monitor ----
  int      frames, long_pulses, bad_gap;
  realtime last_frame;
  logic    prev_frame_ready;
  initial begin
    frames = 0; long_pulses = 0; bad_gap = 0; last_frame = 0;
  end

  always @(posedge clk) begin
    prev_frame_ready <= frame_ready;
    if (frame_ready && prev_frame_ready) long_pulses++;
    if (reset_b && frame_ready && !prev_frame_ready) begin
      // 312 samples of 768 clk each between frames
      if (last_frame != 0 && ($realtime - last_frame) > HOP_SAMPLES * 768 * 2 * CLK_HALF + 1.0) bad_gap++;
      if (last_frame != 0 && ($realtime - last_frame) < HOP_SAMPLES * 768 * 2 * CLK_HALF - 1.0) bad_gap++;
      last_frame = $realtime;
      frames++;
    end
  end

  // read one frame through read_index, oldest first, and compare it with
  // the model. Frame k comes after 624 + 312 (k - 1) pcm values.
  int frame_min, frame_max;
  task automatic read_frame(output int wrong, output int last_pcm);
    int first;
    wrong = 0;
    frame_min = 32767; frame_max = -32768;
    last_pcm = 2 * HOP_SAMPLES + HOP_SAMPLES * (frames - 1);
    first = last_pcm - DEPTH;
    for (int i = 0; i < DEPTH; i++) begin
      @(negedge clk);
      read_index = i;
      @(posedge clk); #1;
      if ($signed(read_data) != expected_pcm[first + i]) wrong++;
      if ($signed(read_data) < frame_min) frame_min = $signed(read_data);
      if ($signed(read_data) > frame_max) frame_max = $signed(read_data);
    end
  endtask

  // 18-bit word for sample n of a tone at freq Hz on a DC offset
  function automatic logic [17:0] tone(input int n, input real freq, input int amplitude, input int offset);
    return 18'(offset + int'(amplitude * $sin(2.0 * PI * freq * n / 46875.0)));
  endfunction

  // apply stimuli and check outputs
  initial begin
    realtime t0, bclk_period, ws_period;
    int      wrong, last_pcm;
    model_reset();
    read_index = 0;

    // test 1: reset holds the outputs low
    reset_b = 0;
    #200;
    check(bclk == 0 && ws == 0 && !frame_ready, "Reset holds bclk, ws, and frame_ready low");

    // the words to send: a 1 kHz tone on a DC offset of -3000 for 700 sums,
    // then 2 groups of the largest word and 2 of the most negative, then
    // random words
    for (int n = 0; n < 3 * 700; n++) to_send.push_back(tone(n, 1000.0, 2000, -3000));
    repeat (6) to_send.push_back(18'h1FFFF);
    repeat (6) to_send.push_back(18'h20000);
    @(negedge clk);
    reset_b = 1;

    // test 2: the microphone pins run at the right rates
    @(posedge bclk); t0 = $realtime;
    @(posedge bclk); bclk_period = $realtime - t0;
    @(negedge ws);   t0 = $realtime;
    @(negedge ws);   ws_period = $realtime - t0;
    check(bclk_period > 333.0 && bclk_period < 333.7 && ws_period > 21332.0 && ws_period < 21335.0,
          $sformatf("bclk is %0.1f ns (3 MHz) and ws is %0.1f ns (46.875 kHz)", bclk_period, ws_period));

    // test 3: the first frame comes once 512 samples are stored, at the
    // second 312-sample boundary
    wait (frames == 1);
    check(expected_pcm.size() >= 2 * HOP_SAMPLES && expected_pcm.size() <= 2 * HOP_SAMPLES + 1,
          $sformatf("First frame_ready after %0d pcm samples (the model is at most 1 ahead)", 2 * HOP_SAMPLES));

    // test 4: frame 1 is the tone with the DC offset being removed
    read_frame(wrong, last_pcm);
    check(wrong == 0, $sformatf("Frame 1 (pcm %0d to %0d) matches the model, from %0d to %0d",
          last_pcm - DEPTH, last_pcm - 1, frame_min, frame_max));

    // test 5: frame 2, 20 ms later, holds the full-scale words, clamped
    wait (frames == 2);
    read_frame(wrong, last_pcm);
    check(wrong == 0 && frame_max == 32767 && frame_min == -32768,
          $sformatf("Frame 2 (pcm %0d to %0d) matches the model and clamps to 32767 and -32768",
          last_pcm - DEPTH, last_pcm - 1));

    // test 6: frame 3 is random words
    wait (frames == 3);
    read_frame(wrong, last_pcm);
    check(wrong == 0, $sformatf("Frame 3 (pcm %0d to %0d) matches the model", last_pcm - DEPTH, last_pcm - 1));

    // test 7: frame_ready is one clk wide, every 312 x 768 clk (20 ms)
    check(long_pulses == 0 && bad_gap == 0, "frame_ready lasts one clk and comes every 239616 clk (19.97 ms)");

    // test 8: asynchronous reset clears the outputs
    repeat (100) @(posedge clk);
    #10 reset_b = 0;
    #1;
    check(bclk == 0 && ws == 0 && !frame_ready, "Asynchronous reset clears bclk, ws, and frame_ready");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
