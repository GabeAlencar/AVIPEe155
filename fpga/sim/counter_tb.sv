`timescale 1 ns/1 ns

/*
 * Testbench: counter_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: counter.sv is the Lab 3 counter (active-low asynchronous reset).
 *   Checks reset, counting only while enabled, the wrap at MAX, and an
 *   asynchronous reset in the middle of a clock cycle.
 */

module counter_tb();
  logic       clk;
  logic       reset_b;
  logic       enable;
  logic [3:0] count;
  int         errors = 0;

  localparam int MAX = 9;

  counter #(.WIDTH(4), .MAX(MAX)) dut (.clk(clk), .reset_b(reset_b), .enable(enable), .count(count));

  // generate clock
  always begin
      clk = 0; #5;
      clk = 1; #5;
  end

  task automatic check(input logic [3:0] want, input string what);
    if (count == want)
      $display("PASSED! %s: count = %0d at time: %0t.", what, count, $time);
    else begin
      errors++;
      $error("FAILED! %s: count = %0d, expected %0d at time: %0t.", what, count, want, $time);
    end
  endtask

  // apply stimuli and check outputs
  initial begin
    // test 1: reset drives count to 0
    reset_b = 0; enable = 1;
    #22;
    check(0, "Reset holds count at 0");

    // test 2: count holds while enable is low
    @(negedge clk);
    reset_b = 1; enable = 0;
    repeat (3) @(posedge clk);
    #1;
    check(0, "Count holds while disabled");

    // test 3: count steps by one on each enabled edge
    @(negedge clk);
    enable = 1;
    for (int i = 1; i <= MAX; i++) begin
      @(posedge clk); #1;
      check(i[3:0], "Count steps by one");
    end

    // test 4: count wraps from MAX back to 0
    @(posedge clk); #1;
    check(0, "Count wraps after MAX");

    // test 5: disabling mid-count holds the value
    repeat (3) @(posedge clk);
    @(negedge clk);
    enable = 0;
    repeat (4) @(posedge clk);
    #1;
    check(3, "Count holds mid-count");

    // test 6: asynchronous reset clears count between clock edges
    @(negedge clk);
    #2 reset_b = 0;
    #1;
    check(0, "Asynchronous reset clears count");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
