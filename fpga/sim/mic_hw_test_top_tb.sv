`timescale 1 ns/1 ps

/*
 * Testbench: mic_hw_test_top_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Note: Runs the hardware test top level against the same SPH0645 model as
 *   fpga_top_tb, with hsosc_sim.sv standing in for the oscillator. The
 *   testbench reads the two SPI test ports the way the logic analyzer will
 *   and checks them against a model of the sum of 3 and the DC removal:
 *     - every pcm stream word, in order
 *     - every frame dump: frame number, then the right 512 samples
 *     - every UART sample: sync bits, sample counter, and value
 *     - the heartbeat LED toggles every HEARTBEAT_FRAMES frames
 *     - the VU meter bar (solid, smoothed, with hysteresis) and clip light for a tone,
 *       full-scale noise, and silence
 *   HEARTBEAT_FRAMES is 2 here so the test stays short.
 */

module mic_hw_test_top_tb();
  logic       reset_b;
  tri0        sd;
  logic       bclk, ws;
  logic [4:0] bar;
  logic       led_heartbeat, led_clip;
  logic       pcm_sck, pcm_sdo, pcm_cs_b;
  logic       frm_sck, frm_sdo, frm_cs_b;
  logic       uart_tx;
  int         errors = 0;

  localparam real PI         = 3.14159265358979;
  localparam int  DEPTH      = 512;
  localparam int  HOP        = 312;
  localparam int  HB_FRAMES  = 2;

  mic_hw_test_top #(.HEARTBEAT_FRAMES(HB_FRAMES)) dut (.reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .bar(bar), .led_heartbeat(led_heartbeat), .led_clip(led_clip),
      .pcm_sck(pcm_sck), .pcm_sdo(pcm_sdo), .pcm_cs_b(pcm_cs_b), .frm_sck(frm_sck), .frm_sdo(frm_sdo), .frm_cs_b(frm_cs_b), .uart_tx(uart_tx));

  task automatic check(input logic ok, input string what);
    if (ok)
      $display("PASSED! %s at time: %0t.", what, $time);
    else begin
      errors++;
      $error("FAILED! %s at time: %0t.", what, $time);
    end
  endtask

  // ---- model of sum_of_3 and dc_removal (same as fpga_top_tb) ----
  int     group_count, group_sum;
  longint average_acc;
  int     expected_pcm[$];

  function automatic int clamp(input longint value);
    if (value > 32767)  return 32767;
    if (value < -32768) return -32768;
    return int'(value);
  endfunction

  task automatic model_word(input logic [17:0] w);
    longint average;
    group_sum += $signed(w);
    group_count++;
    if (group_count == 3) begin
      average = average_acc >>> 10;
      expected_pcm.push_back(clamp(group_sum - average));
      average_acc = average_acc + group_sum - average;
      group_sum   = 0;
      group_count = 0;
    end
  endtask

  // ---- SPH0645 model (same as fpga_top_tb) ----
  localparam real THTR = 7.0;
  localparam real TDC  = 40.0;
  logic        sd_drv, sd_oe;
  logic [17:0] to_send[$];
  logic [17:0] word;
  int          bitn;
  logic        ws_d;
  logic        noisy;        // send full-scale random words when the list is empty

  assign sd = sd_oe ? sd_drv : 1'bz;

  initial begin
    sd_oe = 0; sd_drv = 0; bitn = 0; ws_d = 0; noisy = 0;
    group_count = 0; group_sum = 0; average_acc = 0;
  end

  always @(posedge bclk) if (reset_b === 1'b1) begin
    if (ws != ws_d) bitn = 1;
    else            bitn++;
    ws_d = ws;

    if (ws == 0 && bitn == 1) begin
      word = (to_send.size() > 0) ? to_send.pop_front() : (noisy ? 18'($urandom) : 18'd0);
      model_word(word);
    end

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

  // ---- pcm stream reader: one 16-bit word per cs_b low period ----
  int          pcm_words, pcm_wrong, pcm_bad_len, pcm_n;
  logic [15:0] pcm_shift;
  logic        pcm_in_word;
  initial begin pcm_words = 0; pcm_wrong = 0; pcm_bad_len = 0; pcm_n = 0; pcm_in_word = 0; end

  always @(negedge pcm_cs_b) begin pcm_n = 0; pcm_in_word = 1; end
  always @(posedge pcm_sck) if (pcm_in_word) begin pcm_shift = {pcm_shift[14:0], pcm_sdo}; pcm_n++; end
  always @(posedge pcm_cs_b) if (pcm_in_word) begin
    pcm_in_word = 0;
    if (pcm_n != 16) pcm_bad_len++;
    else if (pcm_words >= expected_pcm.size() || $signed(pcm_shift) != expected_pcm[pcm_words]) pcm_wrong++;
    pcm_words++;
  end

  // ---- frame dump reader: frame number, then 512 samples ----
  int          frames_seen, frm_bad_num, frm_bad_len, frm_wrong, frm_n;
  logic [15:0] frm_shift;
  logic [15:0] got[$];
  logic        frm_in_frame;
  initial begin frames_seen = 0; frm_bad_num = 0; frm_bad_len = 0; frm_wrong = 0; frm_n = 0; frm_in_frame = 0; end

  always @(negedge frm_cs_b) begin frm_n = 0; got.delete(); frm_in_frame = 1; end
  always @(posedge frm_sck) if (frm_in_frame) begin
    frm_shift = {frm_shift[14:0], frm_sdo};
    frm_n++;
    if (frm_n % 16 == 0) got.push_back(frm_shift);
  end
  always @(posedge frm_cs_b) if (frm_in_frame) begin : frm_check
    int first;
    frm_in_frame = 0;
    if (frm_n != 16 * (DEPTH + 1)) frm_bad_len++;
    else begin
      if (got[0] != 16'(frames_seen)) frm_bad_num++;
      // frame k (from 0) ends after 2 * HOP + HOP * k pcm values
      first = 2 * HOP + HOP * frames_seen - DEPTH;
      for (int i = 0; i < DEPTH; i++)
        if ($signed(got[i + 1]) != expected_pcm[first + i]) frm_wrong++;
    end
    frames_seen++;
  end

  // ---- UART reader: 8N1 at clk / 16, 3 bytes per sample ----
  localparam real BIT_NS = 16 * 4 * 2 * 10.4167;   // 16 clk of 12 MHz from hsosc_sim
  int          uart_samples, uart_wrong, uart_bad_count, uart_bad_frame, ubyte_idx;
  logic [7:0]  ubytes[3];
  initial begin uart_samples = 0; uart_wrong = 0; uart_bad_count = 0; uart_bad_frame = 0; ubyte_idx = 0; end

  always @(negedge uart_tx) if (reset_b === 1'b1) begin : uart_byte
    logic [7:0] b;
    logic [15:0] p;
    #(BIT_NS * 1.5);
    for (int i = 0; i < 8; i++) begin b[i] = uart_tx; #(BIT_NS); end
    if (uart_tx !== 1'b1) uart_bad_frame++;          // stop bit
    if (b[7]) ubyte_idx = 0;
    if (ubyte_idx < 3) ubytes[ubyte_idx] = b;
    ubyte_idx++;
    if (ubyte_idx == 3) begin
      p = {ubytes[0][6:0], ubytes[1][6:0], ubytes[2][1:0]};
      if (!ubytes[0][7] || ubytes[1][7] || ubytes[2][7] || ubytes[2][6:2] != 5'(uart_samples)) uart_bad_count++;
      if (uart_samples >= expected_pcm.size() || $signed(p) != expected_pcm[uart_samples]) uart_wrong++;
      uart_samples++;
    end
  end

  // ---- heartbeat ----
  int hb_toggles;
  initial hb_toggles = 0;
  always @(led_heartbeat) if (reset_b === 1'b1) hb_toggles++;

  function automatic logic [17:0] tone(input int n, input real freq, input int amplitude, input int offset);
    return 18'(offset + int'(amplitude * $sin(2.0 * PI * freq * n / 46875.0)));
  endfunction

  initial begin
    reset_b = 0;
    #500;
    check(bclk == 0 && ws == 0 && pcm_cs_b && frm_cs_b && bar == 0 && !led_heartbeat && !led_clip, "Reset holds the mic clocks, test ports, and LEDs idle");

    // a 1 kHz tone of 1000 LSB on a DC offset of -3000, about 3000 LSB in pcm
    for (int n = 0; n < 3 * 1700; n++) to_send.push_back(tone(n, 1000.0, 1000, -3000));
    reset_b = 1;

    // test 1: 4 frames of the tone
    wait (frames_seen == 4);
    #1000;
    check(frm_bad_len == 0 && frm_bad_num == 0 && frm_wrong == 0,
          $sformatf("Frame dump: %0d frames, %0d bad lengths, %0d bad frame numbers, %0d wrong samples", frames_seen, frm_bad_len, frm_bad_num, frm_wrong));
    check(pcm_words > 2 * HOP + 3 * HOP && pcm_bad_len == 0 && pcm_wrong == 0,
          $sformatf("pcm stream: %0d words, %0d bad lengths, %0d wrong", pcm_words, pcm_bad_len, pcm_wrong));
    check(uart_samples > 2 * HOP + 3 * HOP && uart_wrong == 0 && uart_bad_count == 0 && uart_bad_frame == 0,
          $sformatf("UART: %0d samples, %0d wrong, %0d bad sync/count, %0d bad stop bits", uart_samples, uart_wrong, uart_bad_count, uart_bad_frame));
    check(hb_toggles == 4 / HB_FRAMES,
          $sformatf("Heartbeat toggled %0d times in 4 frames (expected %0d)", hb_toggles, 4 / HB_FRAMES));

    // test 2: level meter on the tone, after the DC removal settles
    check(bar[2:0] == 3'b111 && !led_clip, $sformatf("VU meter lights at least the first 3 LEDs for the 3000 LSB tone, no clip (bar = %b)", bar));

    // test 3: full-scale noise lights the whole bar
    noisy = 1;
    wait (frames_seen == 6);
    #1000;
    check(bar == 5'b11111 && led_clip, $sformatf("VU meter is full and the clip light is on for full-scale noise (bar = %b, clip = %b)", bar, led_clip));
    check(frm_bad_len == 0 && frm_bad_num == 0 && frm_wrong == 0 && pcm_wrong == 0 && pcm_bad_len == 0 && uart_wrong == 0 && uart_bad_count == 0 && uart_bad_frame == 0,
          "Frame dump, pcm stream, and UART still match the model with full-scale noise");

    // test 4: in silence the smoothed level falls with a 2048-sample time
    // constant. From about 30000 it is near 30000 * e^(-3744/2048) = 4800
    // after 12 frames (0.24 s): LEDs 3 and 4 are past their off points or
    // close, so the bar has dropped to 3 or 4 LEDs and is still solid.
    noisy = 0;
    wait (frames_seen == 18);
    check(bar == 5'b00111 || bar == 5'b01111, $sformatf("After 0.24 s of silence the bar has fallen to a solid 3 or 4 LEDs (bar = %b)", bar));

    // test 5: after 1.2 s everything is off: the level is near 0 and the
    // clip light holds only 0.5 s
    wait (frames_seen == 66);
    check(bar == 5'b00000 && !led_clip, $sformatf("After 1.2 s of silence all LEDs are off (bar = %b, clip = %b)", bar, led_clip));

    if (errors == 0) $display("All tests passed.");
    else             $display("%0d tests failed.", errors);
    $stop;
  end

endmodule
