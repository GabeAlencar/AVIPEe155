`timescale 1 ns/1 ns

/*
 * Testbench: dc_removal_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: The testbench stands in for sum_of_3, sending sums with a one clk
 *   sum_valid pulse. Between pulses, sum changes to random values so only
 *   sums read on a valid clk can reach the output. A model in the
 *   testbench runs the same running average, and a monitor checks every
 *   pcm_valid pulse against it. Other checks measure the output directly:
 *   how fast a DC offset dies away, and that a tone passes through.
 */

module dc_removal_tb();
  logic        clk;
  logic        reset_b;
  logic [19:0] sum;
  logic        sum_valid;
  logic [15:0] pcm;
  logic        pcm_valid;
  int          errors = 0;

  localparam int    IN_WIDTH      = 20;
  localparam int    OUT_WIDTH     = 16;
  localparam int    AVERAGE_SHIFT = 10;
  localparam real   PI            = 3.14159265358979;
  localparam real   SAMPLE_RATE   = 15625.0;

  dc_removal #(.IN_WIDTH(IN_WIDTH), .OUT_WIDTH(OUT_WIDTH), .AVERAGE_SHIFT(AVERAGE_SHIFT)) dut (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

  // generate clock
  always begin
      clk = 0; #5;
      clk = 1; #5;
  end

  task automatic check(input logic ok, input string what);
    if (ok)
      $display("PASSED! %s at time: %0t.", what, $time);
    else begin
      errors++;
      $error("FAILED! %s at time: %0t.", what, $time);
    end
  endtask

  // ---- model: the same running average, in 64 bit integers ----
  longint model_acc;
  int     expected[$];   // outputs that have not come out yet
  int     sums_sent;

  function automatic int clamp(input longint value);
    if (value > 32767)  return 32767;
    if (value < -32768) return -32768;
    return int'(value);
  endfunction

  // ---- monitor: compare every output with the model and track its range ----
  int   pcm_pulses, wrong_outputs, long_pulses;
  int   pcm_min, pcm_max;
  logic prev_pcm_valid;
  always @(posedge clk) begin
    prev_pcm_valid <= pcm_valid;
    if (pcm_valid && prev_pcm_valid) long_pulses++;
    if (pcm_valid && !prev_pcm_valid) begin
      pcm_pulses++;
      if ($signed(pcm) < pcm_min) pcm_min = $signed(pcm);
      if ($signed(pcm) > pcm_max) pcm_max = $signed(pcm);
      if (expected.size() == 0) wrong_outputs++;
      else if ($signed(pcm) != expected.pop_front()) wrong_outputs++;
    end
  end

  task automatic clear_range();
    pcm_min = 32767;
    pcm_max = -32768;
  endtask

  // send one sum with a one clk valid pulse, then wait gap clk.
  // Inputs change on the falling clk edge so they are stable at each rise.
  task automatic send_sum(input int value, input int gap);
    longint average;
    @(negedge clk);
    sum       = value[19:0];
    sum_valid = 1;
    average   = model_acc >>> AVERAGE_SHIFT;
    expected.push_back(clamp(value - average));
    sums_sent++;
    model_acc = model_acc + value - average;
    @(negedge clk);
    sum_valid = 0;
    sum       = $urandom;
    repeat (gap) begin
      @(negedge clk);
      sum = $urandom;
    end
  endtask

  // the output of the last sum sent
  task automatic last_output(output int value);
    @(posedge clk); #1;
    value = $signed(pcm);
  endtask

  // a sample of a tone at freq Hz on top of a DC offset
  function automatic int tone(input int n, input real freq, input int amplitude, input int offset);
    return offset + int'(amplitude * $sin(2.0 * PI * freq * n / SAMPLE_RATE));
  endfunction

  localparam int MAX_SUM = 393213;   // 3 x the largest sample
  localparam int MIN_SUM = -393216;  // 3 x the most negative sample

  // apply stimuli and check outputs
  initial begin
    int out;
    pcm_pulses = 0; wrong_outputs = 0; long_pulses = 0;
    model_acc = 0; sums_sent = 0;
    clear_range();
    sum = 0; sum_valid = 0;

    // test 1: reset clears the outputs
    reset_b = 0;
    #22;
    check(pcm == 0 && !pcm_valid, "Reset clears pcm and pcm_valid");
    @(negedge clk);
    reset_b = 1;

    // test 2: the first sum passes through, since the average starts at 0
    send_sum(1234, 4);
    last_output(out);
    check(out == 1234, $sformatf("First sum passes through: pcm = %0d", out));

    // test 3: a 500 Hz tone on a DC offset of 20000. After 8 time
    // constants only the tone is left, centered on 0.
    for (int n = 0; n < 8192; n++) begin
      if (n == 8192 - 1000) clear_range();
      send_sum(tone(n, 500.0, 8000, 20000), 3);
    end
    @(posedge clk); #1;
    check(pcm_max >= 7900 && pcm_max <= 8100 && pcm_min >= -8100 && pcm_min <= -7900,
          $sformatf("Tone on a DC offset: DC removed, output from %0d to %0d", pcm_min, pcm_max));

    // test 4: with the input at 0, the average returns to exactly 0
    repeat (12000) send_sum(0, 0);
    last_output(out);
    check(out == 0, $sformatf("Input of 0 settles to exactly 0: pcm = %0d", out));

    // test 5: a DC step dies away with a time constant of 1024 samples
    send_sum(5000, 0);
    last_output(out);
    check(out >= 4990 && out <= 5010, $sformatf("Step of +5000 passes at first: pcm = %0d", out));
    repeat (1023) send_sum(5000, 0);
    last_output(out);
    check(out >= 1800 && out <= 1880, $sformatf("After 1024 samples it is near 5000/e = 1839: pcm = %0d", out));
    repeat (11000) send_sum(5000, 0);
    last_output(out);
    check(out == 0, $sformatf("Settles to exactly 0: pcm = %0d", out));

    // test 6: a negative DC offset also settles to 0
    repeat (14000) send_sum(-20000, 0);
    last_output(out);
    check(out == 0, $sformatf("Negative offset settles to 0: pcm = %0d", out));

    // test 7: large values saturate instead of wrapping around
    send_sum(MAX_SUM, 4);
    last_output(out);
    check(out == 32767, $sformatf("Largest sum clamps to 32767: pcm = %0d", out));
    send_sum(MIN_SUM, 4);
    last_output(out);
    check(out == -32768, $sformatf("Most negative sum clamps to -32768: pcm = %0d", out));
    send_sum(32767 - 20000, 4);
    last_output(out);
    check(out > 32000 && out <= 32767, $sformatf("Just under the limit does not clamp: pcm = %0d", out));

    // test 8: random sums with random gaps, small and full range
    repeat (2000) send_sum($signed(16'($urandom)), $urandom_range(0, 6));
    repeat (2000) send_sum($urandom_range(0, MAX_SUM - MIN_SUM) + MIN_SUM, $urandom_range(0, 6));
    // a few at the real rate, one every 768 clk
    repeat (10) send_sum($signed(16'($urandom)), 767);
    @(posedge clk); @(posedge clk);
    check(wrong_outputs == 0 && expected.size() == 0 && pcm_pulses == sums_sent,
          $sformatf("Every output matches the model (%0d outputs)", pcm_pulses));

    // test 9: pcm_valid is one clk wide
    check(long_pulses == 0, "pcm_valid lasts exactly one clk");

    // test 10: asynchronous reset clears the output and the average
    send_sum(1000, 4);
    @(posedge clk);
    #2 reset_b = 0;
    #1;
    check(pcm == 0 && !pcm_valid, "Asynchronous reset clears pcm");
    model_acc = 0;
    @(negedge clk);
    reset_b = 1;
    send_sum(-777, 4);
    last_output(out);
    check(out == -777, $sformatf("Average restarts at 0 after reset: pcm = %0d", out));

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
