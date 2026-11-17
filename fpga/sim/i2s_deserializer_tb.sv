`timescale 1 ns/1 ns

/*
 * Testbench: i2s_deserializer_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: The testbench stands in for i2s_clkgen, driving slot and a
 *   sample_en pulse every 4 clk. Two DUTs share the inputs, one for each
 *   channel, so every frame checks that each one keeps only its own half.
 *   sd toggles randomly whenever sample_en is low and in the slots that
 *   carry no data, so only bits sampled at the right time can pass.
 */

module i2s_deserializer_tb();
  logic        clk;
  logic        reset_b;
  logic        sample_en;
  logic [5:0]  slot;
  logic        sd;
  logic [17:0] left_sample, right_sample;
  logic        left_valid, right_valid;
  int          errors = 0;

  localparam int DATA_WIDTH = 18;

  i2s_deserializer #(.DATA_WIDTH(DATA_WIDTH), .CHANNEL(1'b0)) dut_left (.clk(clk), .reset_b(reset_b), .sample_en(sample_en), .slot(slot), .sd(sd), .sample(left_sample), .sample_valid(left_valid));

  i2s_deserializer #(.DATA_WIDTH(DATA_WIDTH), .CHANNEL(1'b1)) dut_right (.clk(clk), .reset_b(reset_b), .sample_en(sample_en), .slot(slot), .sd(sd), .sample(right_sample), .sample_valid(right_valid));

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

  // count valid pulses and how many cycles each one lasts
  int left_pulses, right_pulses, long_pulses;
  logic prev_left_valid, prev_right_valid;
  always @(posedge clk) begin
    prev_left_valid  <= left_valid;
    prev_right_valid <= right_valid;
    if (left_valid  && !prev_left_valid)  left_pulses++;
    if (right_valid && !prev_right_valid) right_pulses++;
    if ((left_valid && prev_left_valid) || (right_valid && prev_right_valid)) long_pulses++;
  end

  // the bit of a 24 bit word sent in slot s of its half frame, MSB in slot 1
  function automatic logic word_bit(input logic [23:0] word, input int s);
    return word[24 - s];
  endfunction

  // send one 64 slot frame, 4 clk per slot with sample_en in the first.
  // Inputs change on the falling clk edge so they are stable at each rise.
  task automatic send_frame(input logic [23:0] left_word, input logic [23:0] right_word);
    for (int s = 0; s < 64; s++) begin
      for (int p = 0; p < 4; p++) begin
        @(negedge clk);
        slot      = s[5:0];
        sample_en = (p == 0);
        if (p != 0)              sd = $urandom_range(0, 1);
        else if (s >= 1  && s <= 24) sd = word_bit(left_word, s);
        else if (s >= 33 && s <= 56) sd = word_bit(right_word, s - 32);
        else                     sd = $urandom_range(0, 1);
      end
    end
  endtask

  // send one frame and check both channels
  task automatic frame_check(input logic [23:0] left_word, input logic [23:0] right_word, input string what);
    int lp, rp;
    lp = left_pulses; rp = right_pulses;
    send_frame(left_word, right_word);
    @(posedge clk); #1;
    check(left_sample  == left_word[23:6]  && right_sample == right_word[23:6] &&
          left_pulses  == lp + 1           && right_pulses == rp + 1,
          $sformatf("%s: left %h right %h", what, left_sample, right_sample));
  endtask

  // apply stimuli and check outputs
  initial begin
    left_pulses = 0; right_pulses = 0; long_pulses = 0;
    sample_en = 0; slot = 6'd63; sd = 0;

    // test 1: reset clears the outputs
    reset_b = 0;
    #22;
    check(left_sample == 0 && right_sample == 0 && !left_valid && !right_valid, "Reset clears sample and sample_valid");
    @(negedge clk);
    reset_b = 1;

    // test 2: a word on each channel. The low 6 bits are not kept.
    frame_check(24'hABCDEF, 24'h123456, "Different words on each channel");

    // test 3: the largest and smallest values
    frame_check({18'h1FFFF, 6'h3F}, {18'h20000, 6'h00}, "Largest positive and most negative");
    frame_check({18'h20000, 6'h00}, {18'h1FFFF, 6'h3F}, "Most negative and largest positive");

    // test 4: all zeros and all ones (0 and -1)
    frame_check(24'h000000, 24'hFFFFFF, "Zero and -1");

    // test 5: alternating bits, so a one-slot shift would be caught
    frame_check(24'hAAAAAA, 24'h555555, "Alternating bits");

    // test 6: random words
    repeat (20) frame_check($urandom, $urandom, "Random words");

    // test 7: sample_valid is one clk wide
    check(long_pulses == 0, "sample_valid lasts exactly one clk");

    // test 8: sample holds when no sample_en arrives
    frame_check(24'h0F0F0F, 24'hF0F0F0, "Known words before the hold test");
    sample_en = 0;
    repeat (200) begin
      @(negedge clk);
      slot = $urandom;
      sd   = $urandom_range(0, 1);
    end
    @(posedge clk); #1;
    check(!left_valid && !right_valid && left_sample == 18'h03C3C && right_sample == 18'h3C3C3,
          "Sample holds while sample_en is low");

    // test 9: asynchronous reset clears the outputs between clk edges
    send_frame(24'hFFFFFF, 24'hFFFFFF);
    @(posedge clk);
    #2 reset_b = 0;
    #1;
    check(left_sample == 0 && right_sample == 0, "Asynchronous reset clears sample");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
