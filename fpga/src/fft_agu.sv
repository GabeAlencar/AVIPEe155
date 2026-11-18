// address generation unit (AGU).
// counts the fft level and butterfly index within each level
// and generates ram addresses for each butterfly operation.
// also handles ping-pong control based on fft level.
module fft_agu
  #(parameter width=16, M=5)
   (input logic            clk,
    input logic            enable,
    input logic            reset,
    input logic            load,
    output logic           done,
    output logic           bfly_we,
    output logic [M-1:0] adrA,
    output logic [M-1:0] adrB,
    output logic [M-2:0] twiddleadr);

   // latency of the datapath; set these to match your hardware
   localparam RAM_LAT  = 1;   // read latency measured in the RAM testbench (1)

   logic [M-1:0]         fftLevel = 0;
   logic [M-1:0]         flyInd = 0;
   logic [3:0]           cnt = 0;           // cycles spent on the current butterfly

   assign bfly_we = ((enable === 1) & ~done) & (cnt == RAM_LAT);  // last cycle of a butterfly: write results back

   // count cnt, fftLevel and flyInd
   always_ff @(posedge clk) begin
      if (reset) begin
         fftLevel <= 0;
         flyInd   <= 0;
         cnt      <= 0;
      end
      else if (((enable === 1) & ~done)) begin
         if (cnt == RAM_LAT) begin                 // butterfly finished and written: advance
            cnt <= 0;
            if (flyInd < 2**(M - 1) - 1) begin   // more butterflies left in this level
               flyInd <= flyInd + 1'd1;
            end else begin                       // level finished
               flyInd   <= 0;
               fftLevel <= fftLevel + 1'd1;
            end
         end else begin
            cnt <= cnt + 1'd1;                   // hold address while data moves through RAM and butterfly
         end
      end
   end

   // sets done when we are finished with the FFT
   assign done = (fftLevel == (M));
   fft_agu_adrcalc #(width, M) adrcalc(fftLevel, flyInd, adrA, adrB, twiddleadr);

endmodule // fft_agu


// AGU address calculation unit.
// given FFT level and butterfly index, performs the proper
// rotations to generate the BFU input A and B addresses,
// and the masking to generate the twiddle addresses.
module fft_agu_adrcalc
  #(parameter width=16, M=5)
   (input logic  [M-1:0] fftLevel,
    input logic  [M-1:0] flyInd,
    output logic [M-1:0] adrA,
    output logic [M-1:0] adrB,
    output logic [M-2:0] twiddleadr);

   logic [M-1:0]         tempA, tempB;
   logic signed [M-1:0]  mask, smask; // signed for sign extension
   
   always_comb begin
      // implement the rotations with shifting: -- semi-confusing eqs from Brake FFT Paper
      //     adrA = ROTATE_{M}(2*flyInd,     fftLevel)
      //     adrB = ROTATE_{M}(2*flyInd + 1, fftLevel) 
      tempA = flyInd << 1'd1;         
      tempB = tempA  +  1'd1;            
      adrA  = ((tempA << fftLevel) | (tempA >> (M - fftLevel))); 
      adrB  = ((tempB << fftLevel) | (tempB >> (M - fftLevel)));  

      // replication operator to create the mask that gets shifted 
      // (mask out the last n-1-i least significant bits of flyInd)
      mask       = {1'b1, {M-1{1'b0}} };      // 
      smask      = mask >>> fftLevel;         // >>> makes the sign bit stay and copies it down once for each fftLevel > 0 
      twiddleadr = smask & flyInd;            // 
   end
   
endmodule // fft_agu_adrcalc
