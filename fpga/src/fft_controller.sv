/*
 * Module: fft_controller
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT - passed to fft. 1 halves every stage so 16-bit pcm never overflows.
 *
 *   1. on frame_ready, reset the fft and copy the 512 samples from the ring
 *      buffer into it, oldest first, as {pcm, 16'h0000} (real, imaginary).
 *   2. start the fft and wait for done (4,607 clk).
 *   3. read out X[0..255] on bin_we / bin_addr / bin_data, one a clk. The
 *      input is real, so X[256..511] are the complex conjugates of these.
 *   4. pulse bins_done and count the frame.
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

    typedef enum logic [2:0] {IDLE = 3'd0, FFT_RESET = 3'd1, LOAD = 3'd2, START = 3'd3, RUN = 3'd4, READ = 3'd5, DONE = 3'd6} statetype;
    statetype state, nextstate;

    logic [9:0]  cnt;               // sample counter while loading and reading

    // load pipeline: the ring buffer answers one clk after read_index
    logic        load_v;
    logic [8:0]  load_adr;

    logic        fft_reset, fft_start, fft_done;

    fft #(.width(16), .M(9), .STAGE_SHIFT(STAGE_SHIFT)) u_fft (.clk(clk), .reset(fft_reset), .start(fft_start), .load(load_v), .rd_adr(load_adr), .rd({read_data, 16'h0000}), .wd(bin_data), .done(fft_done));

    // ---- state register ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) state <= IDLE;
        else          state <= nextstate;

    // ---- next state logic ----
    always_comb
        case (state)
            IDLE:      nextstate = frame_ready ? FFT_RESET : IDLE;
            FFT_RESET: nextstate = LOAD;
            LOAD:      nextstate = (cnt == 10'(N)) ? START : LOAD;        // the last sample is written this clk
            START:     nextstate = RUN;
            RUN:       nextstate = fft_done ? READ : RUN;                 // X[0] is on wd next clk
            READ:      nextstate = (cnt == 10'(BINS - 1)) ? DONE : READ;
            DONE:      nextstate = IDLE;
            default:   nextstate = IDLE;
        endcase

    // ---- sample counter: 0 to 512 while loading, 0 to 255 while reading ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)                                    cnt <= '0;
        else if (state == FFT_RESET || (state == RUN && fft_done)) cnt <= '0;
        else if ((state == LOAD && cnt != 10'(N)) ||
                 (state == READ && cnt != 10'(BINS - 1)))     cnt <= cnt + 1'b1;

    // ---- frame counter ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)       frame_num <= '0;
        else if (state == DONE)  frame_num <= frame_num + 1'b1;

    // ---- load pipeline ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            load_v   <= 1'b0;
            load_adr <= '0;
        end else begin
            load_v   <= (state == LOAD) & (cnt < 10'(N));
            load_adr <= cnt[8:0];
        end

    // ---- output logic ----
    assign read_index = cnt[8:0];
    assign fft_reset  = (state == FFT_RESET) | ~reset_b;
    assign fft_start  = (state == START);
    assign bin_we     = (state == READ);
    assign bin_addr   = cnt[7:0];
    assign bins_done  = (state == DONE);
    assign fft_busy   = (state != IDLE);

endmodule
