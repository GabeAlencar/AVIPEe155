/*
 * Testbench: fft_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/15/26
 *
 * Runs fft (Katie's 512-point FFT) once in Verilator: loads +IN (one 32-bit
 * hex word {re, im} per line), starts it, and writes the 512 outputs to +OUT
 * in the same format. fpga/model/fft_fixed.py makes the inputs and checks
 * the outputs bit for bit. STAGE_SHIFT is set with -GSTAGE_SHIFT=.
 *
 *   verilator --binary --timing -Wno-fatal -GSTAGE_SHIFT=1 --top-module fft_tb \
 *       fft_tb.sv ../src/fft.sv ../src/fft_agu.sv ../src/fft_butterfly.sv \
 *       ../src/math.sv ../src/memory.sv
 *   obj_dir/Vfft_tb +IN=in.memh +OUT=out.memh      (run from fpga/src for twiddle.tv)
 */
`timescale 1ns/1ps
module fft_tb #(parameter STAGE_SHIFT = 0);
   localparam width = 16, M = 9, N = 1 << M;

   logic             clk = 0, reset = 1, start = 0, load = 0, done;
   logic [M-1:0]     rd_adr = 0;
   logic [2*width-1:0] rd = 0, wd;
   logic [2*width-1:0] mem_in [0:N-1];
   string            in_file, out_file;
   integer           f, cycles;

   fft #(width, M, STAGE_SHIFT) dut(clk, reset, start, load, rd_adr, rd, wd, done);

   always #5 clk = ~clk;

   initial begin
      if (!$value$plusargs("IN=%s", in_file))   in_file  = "in.memh";
      if (!$value$plusargs("OUT=%s", out_file)) out_file = "out.memh";
      $readmemh(in_file, mem_in);
      f = $fopen(out_file, "w");

      repeat (3) @(posedge clk);
      reset <= 0;
      for (int i = 0; i < N; i++) begin              // one sample per clk
         @(posedge clk);
         load <= 1; rd_adr <= M'(i); rd <= mem_in[i];
      end
      @(posedge clk); load <= 0; start <= 1;
      @(posedge clk); start <= 0;
      cycles = 0;
      while (!done) begin @(posedge clk); #1; cycles++; end
      // done: X[k] is on wd one clk after out_idx = k, and out_idx starts at 0
      for (int k = 0; k < N; k++) begin
         @(posedge clk); #1;
         $fwrite(f, "%h\n", wd);
      end
      $fclose(f);
      $display("fft_tb: STAGE_SHIFT=%0d, %0d clk from start to done", STAGE_SHIFT, cycles);
      $finish;
   end
endmodule
