`timescale 1 ns/1 ns

/*
 * Testbench: ring_buffer_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Note: The testbench stands in for dc_removal on the write side and for
 *   the FFT frame copy on the read side. It keeps a list of every sample
 *   sent. When frame_ready pulses, it reads read_index 0 to 511 and checks
 *   that they are the last 512 samples sent, oldest first. Between pulses,
 *   pcm changes to random values so only samples written on a valid clk
 *   can reach the buffer.
 */

module ring_buffer_tb();
  logic        clk;
  logic        reset_b;
  logic [15:0] pcm;
  logic        pcm_valid;
  logic [8:0]  read_index;
  logic [15:0] read_data;
  logic        frame_ready;
  int          errors = 0;

  localparam int ADDR_WIDTH  = 9;
  localparam int DATA_WIDTH  = 16;
  localparam int HOP_SAMPLES = 312;
  localparam int DEPTH       = 2**ADDR_WIDTH;

  ring_buffer #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .HOP_SAMPLES(HOP_SAMPLES)) dut (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

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

  // ---- model: every sample sent since reset ----
  logic [15:0] sent[$];

  // ---- monitor: when each frame_ready pulse comes ----
  int   frames, long_pulses, early_frames, bad_spacing;
  int   sent_at_frame;          // samples sent when the last frame_ready came
  logic prev_frame_ready;
  always @(posedge clk) begin
    prev_frame_ready <= frame_ready;
    if (frame_ready && prev_frame_ready) long_pulses++;
    if (frame_ready && !prev_frame_ready) begin
      frames++;
      if (sent.size() < DEPTH) early_frames++;
      if (sent.size() % HOP_SAMPLES != 0) bad_spacing++;
      if (sent_at_frame != 0 && sent.size() - sent_at_frame != HOP_SAMPLES) bad_spacing++;
      sent_at_frame = sent.size();
    end
  end

  // send one sample with a one clk valid pulse, then wait gap clk.
  // Inputs change on the falling clk edge so they are stable at each rise.
  task automatic send_sample(input logic [15:0] value, input int gap);
    @(negedge clk);
    pcm       = value;
    pcm_valid = 1;
    sent.push_back(value);
    @(negedge clk);
    pcm_valid = 0;
    pcm       = $urandom;
    repeat (gap) begin
      @(negedge clk);
      pcm = $urandom;
    end
  endtask

  // send samples until frame_ready, then stop, like the 768 clk between
  // real samples. The clk after each sample lets the monitor see the pulse.
  task automatic send_until_frame(input int min_gap, input int max_gap);
    int start;
    start = frames;
    while (frames == start) begin
      send_sample($urandom, $urandom_range(min_gap, max_gap));
      @(posedge clk); #1;
    end
  endtask

  // read the whole frame oldest first, like the FFT frame copy will, and
  // count the samples that are not the last 512 sent
  task automatic read_frame(output int wrong);
    int first;
    wrong = 0;
    first = sent_at_frame - DEPTH;
    for (int i = 0; i < DEPTH; i++) begin
      @(negedge clk);
      read_index = i;
      @(posedge clk); #1;
      if (read_data !== sent[first + i]) wrong++;
    end
  endtask

  // sample i of a run, made easy to spot: a ramp with a few bits flipped
  function automatic logic [15:0] marker(input int i);
    return 16'(i) ^ 16'hA500;
  endfunction

  // apply stimuli and check outputs
  initial begin
    int   wrong, frames_before, wrong_total, written_before, written_during;
    logic reading;
    frames = 0; long_pulses = 0; early_frames = 0; bad_spacing = 0; sent_at_frame = 0;
    pcm = 0; pcm_valid = 0; read_index = 0;

    // test 1: reset clears frame_ready
    reset_b = 0;
    #22;
    check(!frame_ready, "Reset clears frame_ready");
    @(negedge clk);
    reset_b = 1;

    // test 2: no frame until 512 samples are stored. The first frame
    // boundary after that is at 624 samples (2 hops).
    for (int i = 0; i < 2 * HOP_SAMPLES - 1; i++) send_sample(marker(i), 2);
    check(frames == 0, $sformatf("No frame_ready in the first %0d samples", sent.size()));
    send_sample(marker(2 * HOP_SAMPLES - 1), 2);
    check(frames == 1 && sent_at_frame == 2 * HOP_SAMPLES, $sformatf("First frame_ready after %0d samples", sent_at_frame));

    // test 3: the first frame is the last 512 samples, oldest first
    read_frame(wrong);
    check(wrong == 0, $sformatf("Frame 1 is samples %0d to %0d, oldest first", sent_at_frame - DEPTH, sent_at_frame - 1));

    // test 4: the next frame comes 312 samples later and overlaps by 200
    send_until_frame(2, 2);
    check(sent_at_frame == 3 * HOP_SAMPLES, $sformatf("Frame 2 after %0d samples, 312 after frame 1", sent_at_frame));
    read_frame(wrong);
    check(wrong == 0, "Frame 2 is the latest 512 samples");

    // test 5: new samples keep arriving while the frame is read. With one
    // every 201 clk, two are written during the 512 clk read, over
    // read_index 0 and 1 after they have been read.
    frames_before = frames;
    reading = 1;
    fork
      while (reading) send_sample($urandom, 200);
      begin
        wait (frames != frames_before);
        written_before = sent.size();
        read_frame(wrong);
        written_during = sent.size() - written_before;
        reading = 0;
      end
    join
    check(wrong == 0 && written_during == 2,
          $sformatf("Frame read correctly while %0d new samples were written", written_during));

    // test 6: many frames with random gaps between samples, the write
    // pointer wrapping many times
    wrong_total = 0;
    for (int f = 0; f < 6; f++) begin
      send_until_frame(0, 4);
      read_frame(wrong);
      wrong_total += wrong;
    end
    check(wrong_total == 0, $sformatf("6 more frames read correctly, %0d frames in all", frames));

    // test 7: frame_ready is one clk wide, every 312 samples, never early
    check(long_pulses == 0, "frame_ready lasts exactly one clk");
    check(bad_spacing == 0 && early_frames == 0, "frame_ready every 312 samples once the buffer is full");

    // test 8: asynchronous reset clears frame_ready and the fill count,
    // so the next frame needs 624 new samples again
    send_sample(16'h1111, 2);
    @(posedge clk);
    #2 reset_b = 0;
    #1;
    check(!frame_ready, "Asynchronous reset clears frame_ready");
    @(negedge clk);
    reset_b = 1;
    sent.delete(); sent_at_frame = 0;
    frames_before = frames;
    for (int i = 0; i < 2 * HOP_SAMPLES - 1; i++) send_sample(marker(i), 0);
    check(frames == frames_before, "No frame_ready until the buffer refills");
    send_sample(marker(2 * HOP_SAMPLES - 1), 0);
    wait (frames != frames_before);
    read_frame(wrong);
    check(frames == frames_before + 1 && wrong == 0, "First frame after reset is correct");

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TESTS FAILED", errors);
    $finish;
  end
endmodule
