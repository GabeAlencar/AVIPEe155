/*
 * Testbench: level_meter_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 *
 * Feeds level_meter pcm samples from +PCM (one signed integer a line, e.g.
 * real mic recordings from fpga/model/captures) and checks:
 *   - the LEDs always form a solid bar (no LED on above an LED that is off)
 *   - how many LEDs are lit and how often any LED changes, printed so the
 *     levels can be tuned against real sounds
 *   - the clip light for a full-scale sample at the end
 */
`timescale 1ns/1ps
module level_meter_tb;
   logic        clk = 0, reset_b = 0, pcm_valid = 0, clip;
   logic [15:0] pcm = 0;
   logic [4:0]  led, led_d;
   int          f, v, n = 0, changes = 0, gaps = 0, errors = 0;
   int          lit_hist [0:5];
   string       pcm_file;

   level_meter dut (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .led(led), .clip(clip));

   always #5 clk = ~clk;

   function automatic int lit(input logic [4:0] l);
      return l[0] + l[1] + l[2] + l[3] + l[4];
   endfunction

   initial begin
      for (int i = 0; i <= 5; i++) lit_hist[i] = 0;
      if (!$value$plusargs("PCM=%s", pcm_file)) pcm_file = "pcm.txt";
      f = $fopen(pcm_file, "r");
      repeat (2) @(posedge clk);
      reset_b <= 1;
      led_d = 0;
      while ($fscanf(f, "%d", v) == 1) begin
         @(posedge clk); pcm <= 16'(v); pcm_valid <= 1;
         @(posedge clk); pcm_valid <= 0;
         @(posedge clk); #1;
         n++;
         if (led != led_d) changes++;
         if (((led + 5'd1) & led) != 0) gaps++;          // a solid bar is 0, 1, 3, 7, 15, 31
         lit_hist[lit(led)]++;
         led_d = led;
      end
      $display("level_meter_tb: %0d samples (%.1f s), LED changes %0d (%.1f/s), not-a-solid-bar samples %0d",
               n, n / 15670.0, changes, changes / (n / 15670.0), gaps);
      $display("  LEDs lit: 0:%0d%% 1:%0d%% 2:%0d%% 3:%0d%% 4:%0d%% 5:%0d%%",
               lit_hist[0] * 100 / n, lit_hist[1] * 100 / n, lit_hist[2] * 100 / n,
               lit_hist[3] * 100 / n, lit_hist[4] * 100 / n, lit_hist[5] * 100 / n);
      if (gaps != 0) errors++;
      // clip: one full-scale sample lights it
      @(posedge clk); pcm <= 16'h8000; pcm_valid <= 1;
      @(posedge clk); pcm_valid <= 0; pcm <= 0;
      repeat (3) @(posedge clk);
      if (!clip) begin errors++; $display("FAILED: clip light did not come on"); end
      if (errors == 0) $display("PASSED"); else $display("FAILED");
      $finish;
   end
endmodule
