/*
 * Module: fft_controller
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT - passed to fft. 1 halves every stage so 16-bit pcm never
 *                 overflows (output = FFT / 512).
 *
 * Runs Katie's fft on every frame from the ring buffer:
 *
 *   1. on frame_ready, reset the fft and copy the 512 samples from the ring
 *      buffer into it, oldest first, as {pcm, 16'h0000} (real, imaginary).
 *   2. start the fft and wait for done (4,607 clk).
 *   3. read out X[0..255] on bin_we / bin_addr / bin_data, one a clk. The
 *      input is real, so X[256..511] are the complex conjugates of these.
 *   4. pulse bins_done and count the frame.
 *
 * All of this takes about 5,400 clk (0.45 ms) and a frame comes every 20 ms.
 * Step 1 starts the clk after frame_ready, well inside the 767 clk the ring
 * buffer gives before it overwrites the oldest sample.
 *
 * Ports:
 *   bin_we, bin_addr, bin_data - X[bin_addr] as {re, im}, for the output drivers
 *   bins_done  - one clk pulse after X[255]
 *   frame_num  - number of this frame, counts up after bins_done
 *   fft_busy   - high from frame_ready until bins_done (a scope trigger)
 */

module fft_controller #(
    parameter int STAGE_SHIFT = 1
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        frame_ready,
    output logic [8:0]  read_index,
    input  logic [15:0] read_data,
    output logic        bin_we,
    output logic [7:0]  bin_addr,
    output logic [31:0] bin_data,
    output logic        bins_done,
    output logic [7:0]  frame_num,
    output logic        fft_busy
);

    localparam int N    = 512;
    localparam int BINS = N / 2;

    typedef enum logic [2:0] {IDLE, FFT_RESET, LOAD, START, RUN, READ, DONE} state_t;
    state_t state;   // needs FSM Encoding Style = Binary in the Radiant strategy: LSE's Auto (one-hot) version never left IDLE on hardware

    logic [9:0]  cnt;               // sample counter while loading and reading

    // load pipeline: the ring buffer answers one clk after read_index
    logic        load_v;
    logic [8:0]  load_adr;

    logic        fft_reset, fft_start, fft_done;

    fft #(.width(16), .M(9), .STAGE_SHIFT(STAGE_SHIFT)) u_fft (.clk(clk), .reset(fft_reset), .start(fft_start), .load(load_v), .rd_adr(load_adr), .rd({read_data, 16'h0000}), .wd(bin_data), .done(fft_done));

    assign read_index = cnt[8:0];
    assign fft_reset  = (state == FFT_RESET) | ~reset_b;
    assign fft_start  = (state == START);
    assign bin_we     = (state == READ);
    assign bin_addr   = cnt[7:0];
    assign bins_done  = (state == DONE);
    assign fft_busy   = (state != IDLE);

    // ---- load pipeline ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            load_v   <= 1'b0;
            load_adr <= '0;
        end else begin
            load_v   <= (state == LOAD) & (cnt < 10'(N));
            load_adr <= cnt[8:0];
        end

    // ---- control ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            state     <= IDLE;
            cnt       <= '0;
            frame_num <= '0;
        end else
            case (state)
                IDLE:      if (frame_ready) state <= FFT_RESET;
                FFT_RESET: begin
                               cnt   <= '0;
                               state <= LOAD;
                           end
                LOAD:      if (cnt == 10'(N)) state <= START;     // the last sample is written this clk
                           else               cnt   <= cnt + 1'b1;
                START:     state <= RUN;
                RUN:       if (fft_done) begin                    // X[0] is on wd next clk
                               cnt   <= '0;
                               state <= READ;
                           end
                READ:      if (cnt == 10'(BINS - 1)) state <= DONE;
                           else                      cnt   <= cnt + 1'b1;
                DONE:      begin
                               frame_num <= frame_num + 1'b1;
                               state     <= IDLE;
                           end
                default:   state <= IDLE;
            endcase

endmodule
