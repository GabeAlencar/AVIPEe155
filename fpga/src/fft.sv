module fft
  #(parameter width=16, M=5, STAGE_SHIFT=0)
   (input  logic                clk, reset, start, load,
    input  logic [M-1:0]        rd_adr,
    input  logic [2*width-1:0]  rd,
    output logic [2*width-1:0]  wd,
    output logic                done);

   localparam RAM_LAT = 1;   // matches fft_agu's latency from RAM 

   // start pulse -> hold enable
   logic enable = 0;
   always_ff @(posedge clk)
     if      (start)         enable <= 1;
     else if (done || reset) enable <= 0;

   // address generation w/o ping-pong
   logic [M-1:0] adrA, adrB;
   logic [M-2:0] twiddleadr;
   logic         bfly_we;
   fft_agu #(width, M) agu(clk, enable, reset, load, done, bfly_we,
                           adrA, adrB, twiddleadr);

   // load: sample goes to its bit-reversed address
   logic [M-1:0] adr_load;
   bit_reverse #(M) reverseaddr(rd_adr, adr_load);

   // read-out counter
   logic [M-1:0] out_idx = 0;
   always_ff @(posedge clk)
     if      (reset) out_idx <= 0;
     else if (done)  out_idx <= out_idx + 1'b1;

   // ---------- parity steering ----------
   logic [2*width-1:0] rd0, rd1, wd0, wd1, a, b, aout, bout, twiddle;
   logic [M-2:0]       adr0, adr1;
   logic               we0, we1;
   wire                pA = ^adrA;      // if pA = 0: a goes to bank 0, if pA = 1: b goes to bank 1 (keeps and b indices seperate)

   always_comb begin
      // default: butterfly multiply outputs need to go into the RAM
      adr0 = pA ? adrB[M-2:0] : adrA[M-2:0];
      adr1 = pA ? adrA[M-2:0] : adrB[M-2:0];
      wd0  = pA ? bout : aout;
      wd1  = pA ? aout : bout;
      we0  = bfly_we;
      we1  = bfly_we;

      if (done) begin                   // read-out
         adr0 = out_idx[M-2:0];  adr1 = out_idx[M-2:0];
         we0  = 1'b0;            we1  = 1'b0;
      end else if (load) begin          // initial load: one sample per cycle, bank by xor of addresses (0 or 1)
         adr0 = adr_load[M-2:0]; adr1 = adr_load[M-2:0];
         wd0  = rd;              wd1  = rd;
         we0  = load & ~(^adr_load);
         we1  = load &  (^adr_load);
      end
   end

   singleport_RAM #(width, M-1) bank0(clk, we0, adr0, wd0, rd0);
   singleport_RAM #(width, M-1) bank1(clk, we1, adr1, wd1, rd1);

   // butterfly inputs: undo the bank manipulation -- a is in one of the banks; goes where the ^(addr) tells it to
   assign a = pA ? rd1 : rd0;
   assign b = pA ? rd0 : rd1;
   fft_twiddleROM #(width, M) twiddlerom(clk, twiddleadr, twiddle);   // registered: ready on the butterfly's 2nd clk
   fft_butterfly  #(width, STAGE_SHIFT) bgu(twiddle, a, b, aout, bout);

   // read-out: the bank select for the output also needs to be delayed due to the RAM latency  
   logic [1:0] sel_pipe = 0;
   always_ff @(posedge clk) sel_pipe <= {sel_pipe[0], ^out_idx};     // out_idx only changes during the done phase
   assign wd = sel_pipe[RAM_LAT-1] ? rd1 : rd0;

endmodule