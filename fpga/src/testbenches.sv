// Top level 16-bit 512-point FFT test.
// loads input from          test_in.mem,
// compares output to        gt_test_out.mem,
// writes computed output to test_out.mem.
`timescale 1ns/1ps
module fft_testbench
  #(parameter width=16, M=9)();
   
   logic clk;
   logic start, load, done, reset;
   logic signed [width-1:0] expected_re, expected_im, wd_re, wd_im;
   logic [2*width-1:0]        rd, wd;
   logic [2*width-1:0]        idx, out_idx, expected;

   logic [M-1:0]            rd_adr;
   assign rd_adr = idx[M-1:0];
   
   logic [2*width-1:0]          input_data [0:2**M-1];
   logic [2*width-1:0]        expected_out [0:2**M-1];

  localparam RAM_LAT = 1;    // same value as in fft mod
   integer             f; // file pointer

   fft #(width, M) dut(clk, reset, start, load, rd_adr, rd, wd, done);

   // ---- per-level memory dump (new) ----
   integer fd, a;
   logic [2*width-1:0] word;

   always @(dut.agu.fftLevel) begin
      #1;                                       // let the last write of the level land
      if (dut.agu.fftLevel != 0) begin
         for (a = 0; a < 2**M; a = a + 1) begin
            word = (^a[M-1:0]) ? dut.bank1.mem[a[M-2:0]] : dut.bank0.mem[a[M-2:0]];
            $display("STAGE %0d %0d %h", dut.agu.fftLevel - 1, a, word);
         end
      end
   end
   
   // clk
   always
     begin
	clk = 1; #5; clk=0; #5;
     end
   
   // start of test: load `input_data`, `expected_out`, open output file, reset fft module.
   initial
     begin
	$readmemh("...\AVIPEe155\fpga\sim\test_in.memh", input_data);     // CHANGE FILEPATH IF NEED
	$readmemh("...\AVIPEe155\fpga\sim\gt_test_out.memh", expected_out);  //CHANGE FILEPATH IF NEED
        f = $fopen("...\AVIPEe155\fpga\sim\test_out.txt", "w"); // write computed values.
        fd = $fopen("...\AVIPEe155\fpga\sim\stages.txt", "w");         
	idx=0; reset=1; #40; reset=0;
     end	

   // increment testbench counter and derive load/start signals
   always @(posedge clk)
     if (~reset) idx <= idx + 1;
     else idx <= idx;
   assign load =  idx < 2**M;
   assign start = idx === 2**M;

   // increment output address if done, reset if restarting FFT
   always @(posedge clk)
     if (load) out_idx <= 0;
     else if (done) out_idx <= out_idx + 1;
   
   // load/start logic
   assign rd = load ? input_data[idx[M-1:0]] : 0;  // read in test data by addressing `input_data` with `idx`
   assign expected = expected_out[(out_idx - RAM_LAT) & (2**M-1)];
   //assign expected = expected_out[out_idx[M-1:0]]; // get test output by addressing `expected_out` with `idx`.
   assign expected_re = expected[2*width-1:width];   // get real      part of `expected` (gt output)
   assign expected_im = expected[width-1:0];         // get imaginary part of `expected` (gt output)
   assign wd_re = wd[2*width-1:width];               // get real      part of `wd` (computed output)
   assign wd_im = wd[width-1:0];                     // get imaginary part of `wd` (computed output)

   // if FFT is done, compare gt to computed output, and write computed output to file.
   always @(posedge clk)
     if (done) begin
	if (out_idx < 2**M + RAM_LAT) begin
	   if (out_idx >= RAM_LAT) begin             // first RAM_LAT words are not valid yet
              $fwrite(f, "%h\n", wd);
              $display("OUT %0d %h", out_idx - RAM_LAT, wd);
	      if (wd !== expected) begin
	         $display("Error @ out_idx %d: expected %b (got %b)    expected: %d+j%d, got %d+j%d",
                          out_idx - RAM_LAT, expected, wd, expected_re, expected_im, wd_re, wd_im);
	      end
	   end
	end else begin
	   $display("FFT test complete.");
           $fclose(f);
           $fclose(fd);
           $stop;
	end
     end
endmodule // fft_testbench
