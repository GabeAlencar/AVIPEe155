/*
 * Module: fft_frame_spi
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT - passed to fft. 1 halves every stage so 16-bit pcm never
 *                 overflows (output = FFT / 512).
 *   HALF_PERIOD  - clk cycles per half sck period. 2 gives 12 MHz / 4 = 3 MHz.
 *   CLKS_PER_BIT - clk cycles per bit on uart_tx (16 gives 750 kbaud).
 *
 * Connects the ring buffer to Katie's fft and sends every result out as an
 * SPI master (mode 0: sck idles low, the receiver reads sdo on the rising
 * edge of sck, MSB first, 16-bit words):
 *
 *   1. on frame_ready, reset the fft and copy the 512 samples from the ring
 *      buffer into it, oldest first, as {pcm, 16'h0000} (real, imaginary).
 *   2. start the fft and wait for done (4,607 clk).
 *   3. copy X[0..255] into out_buf. The input is real, so X[256..511] are
 *      the complex conjugates of these and are not sent.
 *   4. pull cs_b low and send one frame of 514 words:
 *        word 0          16'hA55A             sync
 *        word 1          {frame number, STAGE_SHIFT}   8 bits each
 *        words 2, 3      re X[0], im X[0]
 *        ...
 *        words 512, 513  re X[255], im X[255]
 *      then raise cs_b. sck stays low for a few clk between words, with
 *      cs_b still low.
 *
 * The same frame, plus a checksum word, also goes out on uart_tx (bins_uart)
 * so a PC can read it through the UPduino's USB serial port.
 *
 * fft_busy is high from frame_ready until the outputs are in out_buf, so on
 * a scope it shows how long the fft takes (about 0.5 ms).
 *
 * At 3 MHz a frame is on the wire for about 3 ms and a new frame comes every
 * 20 ms, so every frame is sent. A frame_ready that comes while a frame is
 * still going out is skipped (frame number shows the gap).
 */

module fft_frame_spi #(
    parameter int STAGE_SHIFT = 1,
    parameter int HALF_PERIOD  = 2,
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        frame_ready,
    output logic [8:0]  read_index,
    input  logic [15:0] read_data,
    output logic        sck,
    output logic        sdo,
    output logic        cs_b,
    output logic        fft_busy,
    output logic        uart_tx
);

    localparam int N     = 512;
    localparam int BINS  = N / 2;              // 256 bins sent
    localparam int WORDS = 2 + 2 * BINS;       // 514 words per frame

    typedef enum logic [3:0] {IDLE, FFT_RESET, LOAD, START, RUN, READ, WORD_ADDR, WORD_FIRE, WORD_WAIT} state_t;
    state_t state;   // needs FSM Encoding Style = Binary in the Radiant strategy: LSE's Auto (one-hot) version never left IDLE on hardware

    logic [9:0]  cnt;               // sample counter while loading and reading
    logic [9:0]  word_idx;          // word of the frame being sent
    logic [7:0]  frame_num;

    // load pipeline: the ring buffer answers one clk after read_index
    logic        load_v;
    logic [8:0]  load_adr;

    // fft
    logic        fft_reset, fft_start, fft_done;
    logic [31:0] fft_wd;

    // output buffer and spi
    logic [9:0]  bin_off;
    logic [31:0] out_rdata;
    logic [15:0] tx_word;
    logic        tx_start, tx_busy;

    // uart copy: decided once per frame, when the fft finishes
    logic        u_take, u_frame;

    fft #(.width(16), .M(9), .STAGE_SHIFT(STAGE_SHIFT)) u_fft (.clk(clk), .reset(fft_reset), .start(fft_start), .load(load_v), .rd_adr(load_adr), .rd({read_data, 16'h0000}), .wd(fft_wd), .done(fft_done));

    dual_port_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_out_buf (.clk(clk), .write_en((state == READ) & (cnt < 10'(BINS))), .write_addr(cnt[7:0]), .write_data(fft_wd), .read_addr(bin_off[8:1]), .read_data(out_rdata));

    spi_word_tx #(.WIDTH(16), .HALF_PERIOD(HALF_PERIOD)) u_spi_word_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(tx_word), .busy(tx_busy), .sck(sck), .sdo(sdo));

    bins_uart #(.STAGE_SHIFT(STAGE_SHIFT), .CLKS_PER_BIT(CLKS_PER_BIT)) u_bins_uart (.clk(clk), .reset_b(reset_b), .we((state == READ) & (cnt < 10'(BINS)) & u_frame), .waddr(cnt[7:0]), .wdata(fft_wd),
                                                                                    .send((state == READ) & (cnt == 10'(N - 1)) & u_frame), .frame_num(frame_num), .take(u_take), .tx(uart_tx));

    assign read_index = cnt[8:0];
    assign fft_reset  = (state == FFT_RESET) | ~reset_b;
    assign fft_start  = (state == START);
    assign tx_start   = (state == WORD_FIRE) & ~tx_busy;
    assign fft_busy   = (state != IDLE) & (state < WORD_ADDR);

    // ---- which word goes out ----
    assign bin_off = word_idx - 10'd2;                // bin_off[9:1] is k, bin_off[0] picks re/im

    always_comb
        if      (word_idx == 10'd0) tx_word = 16'hA55A;
        else if (word_idx == 10'd1) tx_word = {frame_num, 8'(STAGE_SHIFT)};
        else if (bin_off[0])        tx_word = out_rdata[15:0];     // im
        else                        tx_word = out_rdata[31:16];    // re

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
            word_idx  <= '0;
            frame_num <= '0;
            cs_b      <= 1'b1;
            u_frame   <= 1'b0;
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
                               cnt     <= '0;
                               u_frame <= u_take;                 // skip the uart copy if it is still sending
                               state <= READ;
                           end
                READ:      if (cnt == 10'(N - 1)) begin
                               word_idx <= '0;
                               cs_b     <= 1'b0;
                               state    <= WORD_ADDR;
                           end else cnt <= cnt + 1'b1;
                WORD_ADDR: state <= WORD_FIRE;                    // buffer read takes one clk
                WORD_FIRE: if (!tx_busy) state <= WORD_WAIT;
                WORD_WAIT: if (!tx_busy) begin
                               if (word_idx == 10'(WORDS - 1)) begin
                                   frame_num <= frame_num + 1'b1;
                                   cs_b      <= 1'b1;
                                   state     <= IDLE;
                               end else begin
                                   word_idx <= word_idx + 1'b1;
                                   state    <= WORD_ADDR;
                               end
                           end
                default:   state <= IDLE;
            endcase

endmodule
