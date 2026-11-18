// adapted from HDL example 5.6 in 
// Harris, Digital Design and Computer Architecture
module singleport_RAM
  #(parameter width=16, M=5)
   (input logic                clk,
    input logic                we,
    input logic [M-1:0]      adr,
    input logic [2*width-1:0]  wd,
    output logic [2*width-1:0] rd);

   reg [2*width-1:0]           mem [2**M-1:0];      // memory thats double the width wide and 2^M tall to form 32x512
   logic [2*width-1:0] rd_temp;     // temp register bc we need to wait an extra cycle? 

     // simulation-only: clear memory so unwritten locations read as 0, not X
   //integer k;
   //initial begin
   //  for (k = 0; k < 2**M; k = k + 1)
   //    mem[k] = '0;
   //end
   
   always @(posedge clk)                            // dependent on we1 or we0 which allows writing to 
     if (we)
       begin
          mem[adr] <= wd;         // wd goes into the mem @ adr to write the new value 
          //mem[adrb] <= wdb;
       end

  always @(posedge clk) begin 
    rd <= mem[adr];          // when we want to read mem, we want to output rd from mem @ adr 
    // rd <= mem[adr]; //rd_temp;
    //rdb <= mem[adrb];
  end 

endmodule // singleport_RAM


// The output is registered (one clk after twiddleadr). The AGU holds
// twiddleadr for both clks of a butterfly, so the twiddle is ready on the
// second clk when the butterfly result is written, and the long path from
// fftLevel through the ROM and the multipliers is cut in two.
module fft_twiddleROM
  #(parameter width=16, M=5)
   (input logic          clk,
    input logic  [M-2:0] twiddleadr, // 0 - 1023 = 10 bits    // takes in the address determined by the fft_control; specifically fft_agu_adrcalc 
    output logic [2*width-1:0] twiddle); // twiddle factor out which is pulled from the python code here?

   // twiddle table pseudocode: w[k] = w[k-1] * w,
   // where w[0] = 1 and w = exp(-j 2pi/N)
   // for k=0... N/2-1

   logic [2*width-1:0]         vectors [0:2**(M-1)-1];  // 2*width in width, 2^(M-1) tall (half of 2^M)
   initial $readmemb("twiddle.tv", vectors);
   always_ff @(posedge clk) twiddle <= vectors[twiddleadr];    // pull twiddle from mem @ twiddleadr -- Need to change this to an EBR storage? 

endmodule // fft_twiddleROM
