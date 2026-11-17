`timescale 1 ns/1 ps

/*
 * Testbench: fpga_top_known_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: Runs the whole FPGA at the real 12 MHz clock with the SPH0645
 *   microphone model and sends signals whose output is known ahead of time
 *   from the math, not from a model of the logic:
 *     - silence gives exactly 0
 *     - a DC offset decays as offset x 3 x (1023/1024)^n
 *     - a click lands at a known read_index and moves 312 places per frame
 *     - a tone on bin k of the 512-point frame (k x 30.52 Hz) shows up only
 *       in bin k, with gain sin(3x)/sin(x), x = pi f / 46875, from the sum of 3
 *     - two tones give two peaks with their own gains
 *     - a tone too loud for 16 bits clamps instead of wrapping around
 *   Mic word m (counted from reset) goes into pcm sample m/3, and frame k
 *   holds pcm samples 112 + 312 (k - 1) to 623 + 312 (k - 1).
 */

module fpga_top_known_tb();
  logic        clk;
  logic        reset_b;
  tri0         sd;           // pulled low while the mic tri-states
  logic        bclk;
  logic        ws;
  logic [8:0]  read_index;
  logic [15:0] read_data;
  logic        frame_ready;
  int          errors = 0;

  localparam real CLK_HALF    = 41.667;   // 12 MHz
  localparam real PI          = 3.14159265358979;
  localparam real MIC_RATE    = 46875.0;
  localparam real PCM_RATE    = 15625.0;
  localparam int  DEPTH       = 512;
  localparam int  HOP_SAMPLES = 312;
  localparam real R           = 1023.0 / 1024.0;   // DC removal decay per sample

  fpga_top dut (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

  // generate clock
  always begin
      clk = 0; #(CLK_HALF);
      clk = 1; #(CLK_HALF);
  end

  task automatic check(input logic ok, input string what);
    if (ok)
      $display("PASSED! %s at time: %0t.", what, $time);
    else begin
      errors++;
      $error("FAILED! %s at time: %0t.", what, $time);
    end
  endtask

  // ---- what the microphone sends ----
  typedef enum {SILENCE, DC, CLICK, TONE, TWO_TONES, LOUD} signal_t;
  signal_t signal_type;

  // frequency of FFT bin k at 15.625 kHz with 512 points
  function automatic real bin_freq(input int k);
    return k * PCM_RATE / DEPTH;
  endfunction

  // gain of the sum of 3 at freq Hz
  function automatic real sum3_gain(input real freq);
    real x;
    x = PI * freq / MIC_RATE;
    return $sin(3.0 * x) / $sin(x);
  endfunction

  function automatic int sine(input int m, input int amplitude, input real freq);
    return int'(amplitude * $sin(2.0 * PI * freq * m / MIC_RATE));
  endfunction

  // mic word m after reset
  function automatic logic [17:0] mic_word(input int m);
    case (signal_type)
      SILENCE:   return 18'd0;
      DC:        return 18'd1000;
      CLICK:     return (m >= 1500 && m <= 1502) ? 18'd5000 : 18'd0;   // pcm sample 500
      TONE:      return 18'(-3000 + sine(m, 8000, bin_freq(32)));
      TWO_TONES: return 18'(sine(m, 4000, bin_freq(32)) + sine(m, 2000, bin_freq(128)));
      LOUD:      return 18'(sine(m, 20000, bin_freq(32)));
      default:   return 18'd0;
    endcase
  endfunction

  // ---- SPH0645 model (same as i2s_receiver_tb) ----
  localparam real THTR = 7.0;     // datasheet: data held at least 7 ns after bclk rises
  localparam real TDC  = 40.0;    // delay from bclk rising to new SD data, ns (max 65.92)
  logic        sd_drv, sd_oe;
  logic [17:0] word;
  int          bitn, words_sent;
  logic        ws_d;

  assign sd = sd_oe ? sd_drv : 1'bz;

  initial begin
    sd_oe = 0; sd_drv = 0; bitn = 0; ws_d = 0; words_sent = 0;
  end

  // ---- frame_ready counter ----
  int   frames;
  logic prev_frame_ready;
  initial frames = 0;

  always @(posedge clk) begin
    prev_frame_ready <= frame_ready;
    if (reset_b && frame_ready && !prev_frame_ready) frames++;
  end

  // after reset the receiver starts a new frame in slot 0
  always @(negedge reset_b) begin
    bitn = 0;
    ws_d = 0;
    sd_oe = 0;
    words_sent = 0;
    frames = 0;
  end

  always @(posedge bclk) if (reset_b === 1'b1) begin
    if (ws != ws_d) bitn = 1;
    else            bitn++;
    ws_d = ws;

    // pick the word for this left channel half frame
    if (ws == 0 && bitn == 1) begin
      word = mic_word(words_sent);
      words_sent++;
    end

    // hold the old bit, then SD is unknown until the new bit is ready
    #(THTR);
    if (sd_oe) sd_drv = 1'bx;
    #(TDC - THTR);

    if (ws == 0 && bitn >= 1 && bitn <= 18) begin
      sd_oe = 1; sd_drv = word[18 - bitn];
    end else if (ws == 0 && bitn >= 19 && bitn <= 24) begin
      sd_oe = 1; sd_drv = 1'b0;
    end else begin
      sd_oe = 0;
    end
  end

  // ---- reading frames ----
  int frame[DEPTH];

  // reset the FPGA and start sending a new signal
  task automatic start(input signal_t s);
    @(negedge clk);
    reset_b = 0;
    signal_type = s;
    #200;
    @(negedge clk);
    reset_b = 1;
  endtask

  // wait for frame k and read all of it through read_index
  task automatic read_frame(input int k);
    wait (frames == k);
    for (int i = 0; i < DEPTH; i++) begin
      @(negedge clk);
      read_index = i;
      @(posedge clk); #1;
      frame[i] = $signed(read_data);
    end
  endtask

  function automatic int first_pcm(input int k);
    return 2 * HOP_SAMPLES - DEPTH + HOP_SAMPLES * (k - 1);
  endfunction

  function automatic int frame_min();
    int v = frame[0];
    foreach (frame[i]) if (frame[i] < v) v = frame[i];
    return v;
  endfunction

  function automatic int frame_max();
    int v = frame[0];
    foreach (frame[i]) if (frame[i] > v) v = frame[i];
    return v;
  endfunction

  function automatic real frame_mean();
    real s = 0;
    foreach (frame[i]) s += frame[i];
    return s / DEPTH;
  endfunction

  // amplitude of the sine in bin k: 2 |X[k]| / N
  function automatic real bin_amplitude(input int k);
    real re = 0, im = 0;
    foreach (frame[i]) begin
      re += frame[i] * $cos(2.0 * PI * k * i / DEPTH);
      im -= frame[i] * $sin(2.0 * PI * k * i / DEPTH);
    end
    return 2.0 * $sqrt(re * re + im * im) / DEPTH;
  endfunction

  real amp[DEPTH/2 + 1];
  function automatic void spectrum();
    for (int k = 0; k <= DEPTH/2; k++) amp[k] = bin_amplitude(k);
  endfunction

  // largest bin from lo to DEPTH/2, other than skip1 and skip2
  function automatic int largest_bin(input int lo, input int skip1, input int skip2);
    int best = lo;
    for (int k = lo; k <= DEPTH/2; k++)
      if (k != skip1 && k != skip2 && (best == skip1 || best == skip2 || amp[k] > amp[best])) best = k;
    return best;
  endfunction

  function automatic real dc_mean(input real start_value, input int k);
    real s = 0;
    for (int n = first_pcm(k); n < first_pcm(k) + DEPTH; n++) s += start_value * R ** n;
    return s / DEPTH;
  endfunction

  function automatic real pct_err(input real got, input real want);
    return 100.0 * (got - want) / want;
  endfunction

  // apply stimuli and check outputs
  initial begin
    int  wrong, k, other;
    real want, want2, got, got2, mean_want;

    read_index = 0;
    reset_b = 0;

    // test 1: silence gives exactly 0
    start(SILENCE);
    read_frame(1);
    check(frame_min() == 0 && frame_max() == 0, "Silence: every sample of frame 1 is exactly 0");

    // test 2: a constant word of 1000 sums to 3000 and the DC removal
    // takes it away as 3000 x (1023/1024)^n
    start(DC);
    read_frame(1);
    wrong = 0;
    foreach (frame[i]) begin
      want = 3000.0 * R ** (first_pcm(1) + i);
      if (frame[i] - want > 2.0 || want - frame[i] > 2.0) wrong++;
    end
    check(wrong == 0, $sformatf("DC 1000: frame 1 follows 3000 x (1023/1024)^n within 2, from %0d (want %0.1f) to %0d (want %0.1f)",
          frame[0], 3000.0 * R ** first_pcm(1), frame[DEPTH-1], 3000.0 * R ** (first_pcm(1) + DEPTH - 1)));
    read_frame(20);
    check(frame[0] - 3000.0 * R ** first_pcm(20) <= 2.0 && 3000.0 * R ** first_pcm(20) - frame[0] <= 2.0 &&
          frame[DEPTH-1] - 3000.0 * R ** (first_pcm(20) + DEPTH - 1) <= 2.0 && 3000.0 * R ** (first_pcm(20) + DEPTH - 1) - frame[DEPTH-1] <= 2.0,
          $sformatf("DC 1000: frame 20 (0.4 s) goes from %0d to %0d (want %0.1f to %0.1f)", frame[0], frame[DEPTH-1],
          3000.0 * R ** first_pcm(20), 3000.0 * R ** (first_pcm(20) + DEPTH - 1)));
    read_frame(40);
    check(frame_max() == 0 && frame_min() == 0, $sformatf("DC 1000: by frame 40 (0.8 s) every sample is exactly 0 (%0d to %0d)",
          frame_min(), frame_max()));

    // test 3: a click of 3 words of 5000 at pcm sample 500 is exactly 15000,
    // at read_index 500 - 112 = 388 in frame 1 and 312 earlier in frame 2
    start(CLICK);
    read_frame(1);
    wrong = 0;
    for (int i = 0; i < 388; i++) if (frame[i] != 0) wrong++;
    for (int i = 389; i < DEPTH; i++) if (frame[i] > -12 || frame[i] < -14) wrong++;
    check(frame[388] == 15000 && wrong == 0 && frame[389] == -14,
          $sformatf("Click: frame 1 is 0 until read_index 388 = %0d (want 15000), then %0d (want -14 = -15000/1024)",
          frame[388], frame[389]));
    read_frame(2);
    wrong = 0;
    for (int i = 0; i < 76; i++) if (frame[i] != 0) wrong++;
    check(frame[76] == 15000 && wrong == 0, $sformatf("Click: frame 2 has it at read_index 76 = %0d, 312 earlier", frame[76]));

    // test 4: tone in bin 32 (976.6 Hz), 8000 on a DC offset of -3000
    start(TONE);
    want = 8000.0 * sum3_gain(bin_freq(32));
    read_frame(1);
    spectrum();
    k = largest_bin(1, -1, -1);
    mean_want = dc_mean(-9000.0, 1);
    check(k == 32 && pct_err(amp[32], want) < 0.5 && pct_err(amp[32], want) > -0.5,
          $sformatf("Tone: frame 1 peak is in bin %0d (want 32) with amplitude %0.0f (want 8000 x %0.4f = %0.0f)",
          k, amp[32], sum3_gain(bin_freq(32)), want));
    check(frame_mean() - mean_want < 80.0 && mean_want - frame_mean() < 80.0,
          $sformatf("Tone: frame 1 still has DC of %0.0f (want -9000 x (1023/1024)^n = %0.0f)", frame_mean(), mean_want));
    read_frame(12);
    spectrum();
    k = largest_bin(1, 32, -1);
    mean_want = dc_mean(-9000.0, 12);
    check(frame_mean() - mean_want < 20.0 && mean_want - frame_mean() < 20.0,
          $sformatf("Tone: by frame 12 (0.26 s) the DC is down to %0.0f (want %0.0f)", frame_mean(), mean_want));
    check(pct_err(amp[32], want) < 0.5 && pct_err(amp[32], want) > -0.5 && amp[k] < 0.01 * want,
          $sformatf("Tone: frame 12 bin 32 is %0.0f, the next largest bin (%0d) is %0.1f, under 1%%", amp[32], k, amp[k]));

    // test 5: two tones, bins 32 and 128 (3906 Hz). The sum of 3 passes
    // less of the higher one.
    start(TWO_TONES);
    want  = 4000.0 * sum3_gain(bin_freq(32));
    want2 = 2000.0 * sum3_gain(bin_freq(128));
    read_frame(2);
    spectrum();
    other = largest_bin(1, 32, 128);
    check(pct_err(amp[32], want) < 0.5 && pct_err(amp[32], want) > -0.5 &&
          pct_err(amp[128], want2) < 0.5 && pct_err(amp[128], want2) > -0.5,
          $sformatf("Two tones: bin 32 = %0.0f (want 4000 x %0.3f = %0.0f), bin 128 = %0.0f (want 2000 x %0.3f = %0.0f)",
          amp[32], sum3_gain(bin_freq(32)), want, amp[128], sum3_gain(bin_freq(128)), want2));
    check(amp[other] < 0.01 * want2, $sformatf("Two tones: every other bin is under 1%% (largest is bin %0d at %0.1f)", other, amp[other]));

    // test 6: a tone of 20000 would be about 59660 at the output, so it
    // must clamp at 32767 and -32768 and never wrap to the other sign
    start(LOUD);
    want = 20000.0 * sum3_gain(bin_freq(32));
    read_frame(1);
    wrong = 0;
    other = 0;
    foreach (frame[i]) begin
      if (frame[i] == 32767 || frame[i] == -32768) other++;
      if (i > 0 && (frame[i] - frame[i-1] > 24000 || frame[i-1] - frame[i] > 24000)) wrong++;
    end
    // a sine of peak A spends 1 - (2/pi) asin(32767/A) of its time past the clamp
    want2 = DEPTH * (1.0 - 2.0 / PI * $asin(32767.0 / want));
    check(frame_max() == 32767 && frame_min() == -32768 && wrong == 0,
          "Loud tone: clamps to 32767 and -32768 with no jump big enough to be a wrap");
    check(other > want2 - 10 && other < want2 + 10,
          $sformatf("Loud tone: %0d of 512 samples are clamped (want about %0.0f)", other, want2));

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
