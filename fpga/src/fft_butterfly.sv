// fft butterfly unit (BFU).
// performs the butterfly operator given two samples and a
// twiddle value.
// STAGE_SHIFT = 1 halves both outputs (arithmetic shift right, rounds down),
// so a 512-point FFT with 9 stages grows by at most 2^0 instead of 2^9 and
// full 16-bit inputs never overflow: the result is FFT(x) / 512.
// STAGE_SHIFT = 0 is the original unscaled butterfly (inputs must fit in 7 bits).
module fft_butterfly
  #(parameter width=16, STAGE_SHIFT=0)
   (input logic [2*width-1:0] twiddle,
    input logic [2*width-1:0]  a,
    input logic [2*width-1:0]  b,
    output logic [2*width-1:0] aout,
    output logic [2*width-1:0] bout);

   logic signed [width-1:0]    a_re, a_im, aout_re, aout_im, bout_re, bout_im; // a_re = a_real; a_im = a_imag
   logic signed [width-1:0]    b_re_mult, b_im_mult;    // b-term always gets multiplied by twiddle
   logic [2*width-1:0]         b_mult;

   // expand a to re and im components
   assign a_re = a[2*width-1:width];
   assign a_im = a[width-1:0];
   
   // perform b computation and split into real and imaginary components
   complex_mult #(width) twiddle_mult(b, twiddle, b_mult);
   assign b_re_mult = b_mult[2*width-1:width];
   assign b_im_mult = b_mult[width-1:0];

   // sums in width+1 bits, then shift down by STAGE_SHIFT
   logic signed [width:0]      sum_re, sum_im, dif_re, dif_im;
   assign sum_re = a_re + b_re_mult;
   assign sum_im = a_im + b_im_mult;
   assign dif_re = a_re - b_re_mult;
   assign dif_im = a_im - b_im_mult;

   assign aout_re = width'(sum_re >>> STAGE_SHIFT);
   assign aout_im = width'(sum_im >>> STAGE_SHIFT);
   assign bout_re = width'(dif_re >>> STAGE_SHIFT);
   assign bout_im = width'(dif_im >>> STAGE_SHIFT);

   // pack re and im outputs
   assign aout = {aout_re, aout_im};
   assign bout = {bout_re, bout_im};
   
endmodule // fft_butterfly
