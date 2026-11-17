`timescale 1 ns/1 ns

/*
 * Testbench: dual_port_ram_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: Tests the 512 x 16 RAM used by ring_buffer. A copy of the memory
 *   in the testbench is checked against every read. Writes and reads run
 *   at the same time on different addresses, and read_data must show up
 *   exactly one clk after read_addr.
 */

module dual_port_ram_tb();
  logic        clk;
  logic        write_en;
  logic [8:0]  write_addr, read_addr;
  logic [15:0] write_data, read_data;
  int          errors = 0;

  localparam int ADDR_WIDTH = 9;
  localparam int DATA_WIDTH = 16;
  localparam int DEPTH      = 2**ADDR_WIDTH;

  dual_port_ram #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (.clk(clk), .write_en(write_en), .write_addr(write_addr), .write_data(write_data), .read_addr(read_addr), .read_data(read_data));

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

  logic [15:0] model [0:DEPTH-1];   // what the RAM should hold
  int          wrong_reads;

  // write one word. Inputs change on the falling clk edge.
  task automatic write_word(input int addr, input logic [15:0] data);
    @(negedge clk);
    write_en   = 1;
    write_addr = addr[8:0];
    write_data = data;
    model[addr] = data;
    @(negedge clk);
    write_en   = 0;
    write_data = $urandom;
  endtask

  // read one word and compare it with the model
  task automatic read_check(input int addr);
    @(negedge clk);
    read_addr = addr[8:0];
    @(posedge clk); #1;
    if (read_data !== model[addr]) begin
      wrong_reads++;
      $error("Read %h at %0d, expected %h at time: %0t.", read_data, addr, model[addr], $time);
    end
  endtask

  // apply stimuli and check outputs
  initial begin
    wrong_reads = 0;
    write_en = 0; write_addr = 0; write_data = 0; read_addr = 0;

    // test 1: fill every address, then read every address back
    for (int a = 0; a < DEPTH; a++) write_word(a, $urandom);
    for (int a = 0; a < DEPTH; a++) read_check(a);
    check(wrong_reads == 0, $sformatf("All %0d addresses read back what was written", DEPTH));

    // test 2: read_data changes one clk after read_addr, not before
    write_word(10, 16'h1234);
    write_word(11, 16'hABCD);
    @(negedge clk); read_addr = 10;
    @(posedge clk); #1;
    check(read_data == 16'h1234, "Word at address 10 one clk after read_addr");
    @(negedge clk); read_addr = 11;
    #1;
    check(read_data == 16'h1234, "read_data holds until the next clk edge");
    @(posedge clk); #1;
    check(read_data == 16'hABCD, "Word at address 11 one clk later");

    // test 3: write_en low does not write
    @(negedge clk);
    write_en = 0; write_addr = 10; write_data = 16'hFFFF;
    @(negedge clk);
    read_check(10);
    check(wrong_reads == 0 && read_data == 16'h1234, "write_en low leaves the word alone");

    // test 4: write and read different addresses on the same edges
    for (int i = 0; i < 200; i++) begin
      int wa, ra;
      logic [15:0] wd;
      wa = $urandom_range(0, DEPTH - 1);
      ra = (wa + $urandom_range(1, DEPTH - 1)) % DEPTH;
      wd = $urandom;
      @(negedge clk);
      write_en = 1; write_addr = wa; write_data = wd;
      read_addr = ra;
      @(posedge clk); #1;
      if (read_data !== model[ra]) wrong_reads++;
      model[wa] = wd;
    end
    @(negedge clk); write_en = 0;
    check(wrong_reads == 0, "Writes and reads on different addresses at the same time");

    // test 5: the corner addresses
    write_word(0, 16'h8000);
    write_word(DEPTH - 1, 16'h7FFF);
    read_check(0);
    read_check(DEPTH - 1);
    check(wrong_reads == 0, "First and last addresses hold their own words");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
