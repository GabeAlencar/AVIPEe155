`timescale 1 ns/1 ns

/*
 * Testbench: sum_of_3_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: The testbench stands in for i2s_receiver, sending samples with a
 *   one clk sample_valid pulse. Between pulses, sample changes to random
 *   values so only samples read on a valid clk can reach the sum. A model
 *   in the testbench keeps its own sum of each group of 3, and a monitor
 *   checks every sum_valid pulse against it.
 */

module sum_of_3_tb();
  logic        clk;
  logic        reset_b;
  logic [17:0] sample;
  logic        sample_valid;
  logic [19:0] sum;
  logic        sum_valid;
  int          errors = 0;

  localparam int DATA_WIDTH = 18;

  sum_of_3 #(.DATA_WIDTH(DATA_WIDTH)) dut (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

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

  // ---- model: the expected sum of each group of 3 ----
  int          model_count;   // samples sent so far in this group
  int          model_sum;
  int          expected[$];   // sums that have not come out yet

  // counted by the monitor below
  int          sum_pulses, wrong_sums, long_pulses;
  logic        prev_sum_valid;

  // send one sample with a one clk valid pulse, then wait gap clk.
  // Inputs change on the falling clk edge so they are stable at each rise.
  task automatic send_sample(input int value, input int gap);
    @(negedge clk);
    sample       = value[17:0];
    sample_valid = 1;
    model_sum   += value;
    model_count++;
    if (model_count == 3) begin
      expected.push_back(model_sum);
      model_sum   = 0;
      model_count = 0;
    end
    @(negedge clk);
    sample_valid = 0;
    sample       = $urandom;
    repeat (gap) begin
      @(negedge clk);
      sample = $urandom;
    end
  endtask

  // send 3 samples and check the sum that comes out
  task automatic group_check(input int a, input int b, input int c, input int gap, input string what);
    int pulses_before;
    pulses_before = sum_pulses;
    send_sample(a, gap);
    send_sample(b, gap);
    send_sample(c, gap);
    @(posedge clk); #1;
    check(sum_pulses == pulses_before + 1 && $signed(sum) == a + b + c,
          $sformatf("%s: %0d + %0d + %0d = %0d", what, a, b, c, $signed(sum)));
  endtask

  // ---- monitor: compare every sum with the model ----
  always @(posedge clk) begin
    prev_sum_valid <= sum_valid;
    if (sum_valid && prev_sum_valid) long_pulses++;
    if (sum_valid && !prev_sum_valid) begin
      sum_pulses++;
      if (expected.size() == 0) wrong_sums++;
      else if ($signed(sum) != expected.pop_front()) wrong_sums++;
    end
  end

  // a random sample anywhere in the 18 bit range
  function automatic int random_sample();
    return $signed(18'($urandom));
  endfunction

  localparam int MAX_SAMPLE = 131071;   //  2^17 - 1
  localparam int MIN_SAMPLE = -131072;  // -2^17

  // apply stimuli and check outputs
  initial begin
    sum_pulses = 0; wrong_sums = 0; long_pulses = 0;
    model_count = 0; model_sum = 0;
    sample = 0; sample_valid = 0;

    // test 1: reset clears the outputs
    reset_b = 0;
    #22;
    check(sum == 0 && !sum_valid, "Reset clears sum and sum_valid");
    @(negedge clk);
    reset_b = 1;

    // test 2: small positive and mixed-sign groups
    group_check(1, 2, 3, 4, "Small positive samples");
    group_check(5, -7, 1, 4, "Mixed signs give -1");
    group_check(-100, -200, -300, 4, "All negative");

    // test 3: the extremes, which need the 2 extra bits
    group_check(MAX_SAMPLE, MAX_SAMPLE, MAX_SAMPLE, 4, "3 x largest positive");
    group_check(MIN_SAMPLE, MIN_SAMPLE, MIN_SAMPLE, 4, "3 x most negative");
    group_check(MAX_SAMPLE, MIN_SAMPLE, 0, 4, "Largest and most negative cancel to -1");

    // test 4: sum_valid only after every third sample
    send_sample(10, 4);
    send_sample(20, 4);
    @(posedge clk); #1;
    check(!sum_valid && $signed(sum) == 30, "No sum_valid after only 2 of a group; sum shows the running total");
    send_sample(30, 4);
    @(posedge clk); #1;
    check($signed(sum) == 60, "Third sample finishes the group");

    // test 5: back-to-back samples with no gap
    group_check(1000, -2000, 3000, 0, "Samples on 3 clk in a row");

    // test 6: random samples at the real rate, one every 256 clk
    repeat (30) send_sample(random_sample(), 255);

    // test 7: random samples with random gaps
    repeat (300) send_sample(random_sample(), $urandom_range(0, 12));
    @(posedge clk); @(posedge clk);
    check(wrong_sums == 0 && expected.size() == 0 && sum_pulses == 118,
          $sformatf("Every sum matches the model (%0d sums)", sum_pulses));

    // test 8: sum_valid is one clk wide
    check(long_pulses == 0, "sum_valid lasts exactly one clk");

    // test 9: asynchronous reset in the middle of a group starts a new group
    send_sample(7, 4);
    send_sample(8, 4);
    @(posedge clk);
    #2 reset_b = 0;
    #1;
    check(sum == 0 && !sum_valid, "Asynchronous reset clears sum");
    model_count = 0; model_sum = 0;
    @(negedge clk);
    reset_b = 1;
    group_check(-1, -2, -3, 4, "Group after reset ignores samples before it");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
