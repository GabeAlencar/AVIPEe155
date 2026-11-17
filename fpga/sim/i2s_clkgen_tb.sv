`timescale 1 ns/1 ns

/*
 * Testbench: i2s_clkgen_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: Checks reset, the bclk period and duty cycle, that ws changes only
 *   when bclk falls and holds for 32 bclk periods, that sample_en pulses
 *   once per bclk period in the cycle after bclk falls (so SD is read
 *   250 ns after the bclk rise where the mic changes it), and that slot
 *   steps by one with the right value at each ws edge.
 */

module i2s_clkgen_tb();
  logic       clk;
  logic       reset_b;
  logic       bclk;
  logic       ws;
  logic       sample_en;
  logic [5:0] slot;
  int         errors = 0;

  localparam int FRAMES = 4;   // ws frames to watch

  i2s_clkgen dut (.clk(clk), .reset_b(reset_b), .bclk(bclk), .ws(ws), .sample_en(sample_en), .slot(slot));

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

  // ---- monitor, sampled on the falling clk edge when outputs are stable ----
  logic       prev_bclk, prev_ws, watching;
  logic [5:0] prev_slot;
  int         high_len, low_len, bclk_len;
  int         falls_since_ws;
  int         bad_high, bad_low, bad_en, bad_ws_edge, bad_ws_len, bad_slot, bad_ws_slot;
  int         bclk_falls, ws_edges, enables;

  initial begin
    watching = 0;
    {bad_high, bad_low, bad_en, bad_ws_edge, bad_ws_len, bad_slot, bad_ws_slot} = '0;
    {bclk_falls, ws_edges, enables} = '0;
  end

  always @(negedge clk)
    if (!reset_b) begin
      prev_bclk      <= 1'b0;
      prev_ws        <= 1'b0;
      prev_slot      <= slot;   // the slot 0 sample_en happens during reset release
      bclk_len       <= 1;
      falls_since_ws <= 1;   // the slot 0 period starts at reset, not at a fall
    end else if (watching) begin
      logic fell, rose;
      fell = prev_bclk & ~bclk;
      rose = ~prev_bclk & bclk;

      // bclk is high for 2 clk and low for 2 clk
      if (fell || rose) begin
        if (fell && bclk_len != 2) bad_high++;
        if (rose && bclk_len != 2) bad_low++;
        bclk_len <= 1;
      end else begin
        bclk_len <= bclk_len + 1;
      end

      // sample_en is high exactly in the cycle after bclk falls
      if (sample_en != fell) bad_en++;
      if (sample_en) begin
        enables++;
        if (slot != prev_slot + 6'd1) bad_slot++;
        prev_slot <= slot;
      end

      // ws changes only when bclk falls, every 32 bclk periods
      if (fell) begin
        bclk_falls++;
        falls_since_ws <= falls_since_ws + 1;
      end
      if (ws != prev_ws) begin
        ws_edges++;
        if (!fell)                   bad_ws_edge++;
        if (falls_since_ws != 32)    bad_ws_len++;
        // slot 0 of each channel starts when ws changes
        if (slot != (ws ? 6'd32 : 6'd0)) bad_ws_slot++;
        falls_since_ws <= 1;
      end

      prev_bclk <= bclk;
      prev_ws   <= ws;
    end

  // apply stimuli and check outputs
  initial begin
    // test 1: reset holds the clocks low
    reset_b = 0;
    #22;
    check(bclk == 0 && ws == 0, "Reset holds bclk and ws low");
    check(slot == 6'd0, "Reset starts in slot 0");

    // test 2: the first bclk rise comes 2 clk after reset is released.
    // Release just after a falling edge so the monitor sees reset on it.
    @(negedge clk);
    #1 reset_b = 1;
    watching = 1;
    @(posedge clk); #1;
    check(bclk == 0, "bclk still low 1 clk after reset");
    @(posedge clk); #1;
    check(bclk == 1, "bclk rises 2 clk after reset");

    // run several full ws frames, the monitor checks every cycle
    repeat (FRAMES * 64 * 4) @(posedge clk);
    @(negedge clk);

    // test 3: bclk is clk / 4 with a 50% duty cycle
    check(bad_high == 0 && bad_low == 0, $sformatf("bclk high and low for 2 clk each (%0d falls)", bclk_falls));

    // test 4: sample_en pulses once per bclk period, just after the fall
    check(bad_en == 0 && enables == bclk_falls,
          $sformatf("sample_en pulses once after each bclk fall (%0d pulses)", enables));

    // test 5: slot steps by one each bclk period
    check(bad_slot == 0, "slot steps by one each bclk period");

    // test 6: ws only changes as bclk falls
    check(bad_ws_edge == 0, $sformatf("ws changes only when bclk falls (%0d edges)", ws_edges));

    // test 7: ws holds for 32 bclk periods, giving a 64 bclk frame
    check(bad_ws_len == 0 && ws_edges == 2 * FRAMES, "ws holds for 32 bclk periods");

    // test 8: slot lines up with ws
    check(bad_ws_slot == 0, "slot is 0 when ws falls and 32 when ws rises");

    // test 9: asynchronous reset clears the clocks between clk edges
    wait (bclk == 1 && ws == 1);
    @(posedge clk);
    #2 reset_b = 0;
    #1;
    check(bclk == 0 && ws == 0, "Asynchronous reset clears bclk and ws");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
