`timescale 1 ns/1 ps

/*
 * Testbench: i2s_receiver_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: Runs the full receiver at the real 12 MHz clock against a model
 *   of the SPH0645 microphone with SEL tied to GND. Like the datasheet
 *   timing (Figure 2), the model samples ws on each bclk rising edge, holds
 *   the old SD bit for tHTR = 7 ns, drives X until tdc, then drives the
 *   new bit. It sends a 24 bit word (18 data bits, then 6 zeros) MSB first,
 *   starting at the first rising edge after ws falls, and tri-states SD
 *   otherwise. Every word the model sends must come out of the receiver
 *   once, in order.
 */

module i2s_receiver_tb();
  logic        clk;
  logic        reset_b;
  tri0         sd;           // pulled low while the mic tri-states
  logic        bclk;
  logic        ws;
  logic [17:0] sample;
  logic        sample_valid;
  int          errors = 0;

  localparam real CLK_HALF = 41.667;   // 12 MHz

  i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) dut (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

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

  // ---- SPH0645 model ----
  localparam real THTR = 7.0;     // datasheet: data held at least 7 ns after bclk rises
  real         tdc;          // delay from bclk rising to new SD data, ns (max 65.92)
  logic        noise_right;  // drive random bits in the right channel
  logic        sd_drv, sd_oe;
  logic [17:0] to_send[$];   // words the test wants sent next
  logic [17:0] sent[$];      // words sent but not yet received
  logic [17:0] word;
  int          bitn;
  logic        ws_d;

  assign sd = sd_oe ? sd_drv : 1'bz;

  initial begin
    sd_oe = 0; sd_drv = 0; bitn = 0; ws_d = 0;
    tdc = 40.0; noise_right = 0;
  end

  // after reset the receiver starts a new frame in slot 0
  always @(negedge reset_b) begin
    bitn = 0;
    ws_d = 0;
    sd_oe = 0;
    sent.delete();
  end

  // ignore the X to 0 edge at time 0 and anything during reset
  always @(posedge bclk) if (reset_b === 1'b1) begin
    // the first rising edge that sees a new ws sends bit 1 (the MSB)
    if (ws != ws_d) bitn = 1;
    else            bitn++;
    ws_d = ws;

    // pick the word for this left channel half frame
    if (ws == 0 && bitn == 1) begin
      word = (to_send.size() > 0) ? to_send.pop_front() : 18'($urandom);
      sent.push_back(word);
    end

    // hold the old bit, then SD is unknown until the new bit is ready
    #(THTR);
    if (sd_oe) sd_drv = 1'bx;
    #(tdc - THTR);

    if (ws == 0 && bitn >= 1 && bitn <= 18) begin
      sd_oe = 1; sd_drv = word[18 - bitn];
    end else if (ws == 0 && bitn >= 19 && bitn <= 24) begin
      sd_oe = 1; sd_drv = 1'b0;
    end else if (ws == 1 && noise_right) begin
      sd_oe = 1; sd_drv = $urandom_range(0, 1);
    end else begin
      sd_oe = 0;
    end
  end

  // ---- check every received word against the model ----
  int received, mismatches, missing;
  int valid_gap, bad_gap;
  realtime last_valid;

  initial begin
    received = 0; mismatches = 0; missing = 0; bad_gap = 0; last_valid = 0;
  end

  always @(posedge clk)
    if (reset_b && sample_valid) begin
      if (sent.size() == 0) begin
        missing++;
        $error("Received %h with no word sent at time: %0t.", sample, $time);
      end else begin
        logic [17:0] want;
        want = sent.pop_front();
        if (sample !== want) begin
          mismatches++;
          $error("Received %h, expected %h at time: %0t.", sample, want, $time);
        end
      end
      // one sample per 256 clk frame
      if (last_valid != 0 && ($realtime - last_valid) > 256 * 2 * CLK_HALF + 1.0) bad_gap++;
      if (last_valid != 0 && ($realtime - last_valid) < 256 * 2 * CLK_HALF - 1.0) bad_gap++;
      last_valid = $realtime;
      received++;
    end

  // send words and wait until they all come back
  task automatic run_words(input int n);
    repeat (n) @(posedge sample_valid);
  endtask

  // measure the time between two edges of a signal
  realtime t0, bclk_period, ws_period, ws_low;

  // ws changes only when bclk falls
  int bad_ws_edge = 0;
  always @(ws) if (reset_b) begin
    #1;
    if (bclk !== 1'b0) bad_ws_edge++;
  end

  // apply stimuli and check outputs
  initial begin
    // test 1: reset holds the outputs low
    reset_b = 0;
    #200;
    check(bclk == 0 && ws == 0 && sample == 0 && !sample_valid, "Reset holds bclk, ws, and sample low");
    @(negedge clk);
    reset_b = 1;

    // test 2: bclk is 3 MHz
    @(posedge bclk); t0 = $realtime;
    @(posedge bclk); bclk_period = $realtime - t0;
    check(bclk_period > 333.0 && bclk_period < 333.7, $sformatf("bclk period is %0.1f ns (3 MHz)", bclk_period));

    // test 3: ws is 46.875 kHz with a 50% duty cycle
    @(negedge ws); t0 = $realtime;
    @(posedge ws); ws_low = $realtime - t0;
    @(negedge ws); ws_period = $realtime - t0;
    check(ws_period > 21332.0 && ws_period < 21335.0 && ws_low * 2 > ws_period - 1.0 && ws_low * 2 < ws_period + 1.0,
          $sformatf("ws period is %0.1f ns (46.875 kHz), low for %0.1f ns", ws_period, ws_low));

    // test 4: corner values, then random words, with typical data delay
    to_send.push_back(18'h1FFFF);   // largest positive
    to_send.push_back(18'h20000);   // most negative
    to_send.push_back(18'h3FFFF);   // -1
    to_send.push_back(18'h00000);   // 0
    to_send.push_back(18'h2AAAA);   // alternating bits
    to_send.push_back(18'h15555);
    to_send.push_back(18'h00001);   // only the LSB
    to_send.push_back(18'h20001);   // MSB and LSB
    run_words(50);
    check(mismatches == 0 && missing == 0, $sformatf("%0d words received correctly, %0d ns data delay", received, int'(tdc)));

    // test 5: fastest data, 7 ns after bclk rises (datasheet tHTR)
    tdc = 7.0;
    received = 0; mismatches = 0; missing = 0;
    run_words(50);
    check(mismatches == 0 && missing == 0, $sformatf("%0d words received correctly, %0d ns data delay", received, int'(tdc)));

    // test 6: slowest data, 66 ns after bclk rises (datasheet tDC max)
    tdc = 66.0;
    received = 0; mismatches = 0; missing = 0;
    run_words(50);
    check(mismatches == 0 && missing == 0, $sformatf("%0d words received correctly, %0d ns data delay", received, int'(tdc)));

    // test 7: another device driving the right channel is ignored
    tdc = 40.0;
    noise_right = 1;
    received = 0; mismatches = 0; missing = 0;
    run_words(50);
    check(mismatches == 0 && missing == 0, "Right channel data is ignored");
    noise_right = 0;

    // test 8: one sample_valid per frame, and ws only changes when bclk falls
    check(bad_gap == 0, "sample_valid pulses once every 256 clk (46.875 kHz)");
    check(bad_ws_edge == 0, "ws changes only when bclk falls");

    // test 9: reset in the middle of a word, then the receiver starts over
    wait (ws == 0);
    repeat (40) @(posedge clk);
    #10 reset_b = 0;
    #1;
    check(bclk == 0 && ws == 0 && sample == 0 && !sample_valid, "Asynchronous reset in the middle of a word clears the outputs");
    #500;
    @(negedge clk);
    reset_b = 1;
    received = 0; mismatches = 0; missing = 0;
    to_send.push_back(18'h12345);
    run_words(10);
    check(mismatches == 0 && missing == 0 && sent.size() <= 1, "Words received correctly after reset");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
