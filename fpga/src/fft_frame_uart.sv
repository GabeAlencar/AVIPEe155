/*
 * Module: fft_frame_uart
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/15/26
 * Parameters:
 *   STAGE_SHIFT  - passed to fft. 1 halves every stage so 16-bit pcm never
 *                  overflows (output = FFT / 512).
 *   CLKS_PER_BIT - clk cycles per UART bit (16 gives 750 kbaud).
 *
 * Hardware test. Connects the ring buffer to Katie's fft and sends each
 * result, with the frame that went in, to the PC over the UPduino's USB
 * serial port:
 *
 *   1. on frame_ready, reset the fft and copy the 512 samples from the ring
 *      buffer into it, oldest first, as {pcm, 16'h0000} (real, imaginary).
 *      The same samples go into in_buf so the PC can check the fft.
 *   2. start the fft and wait for done (4,607 clk).
 *   3. copy the 512 outputs X[0..511] into out_buf.
 *   4. send one packet (3,080 bytes, MSB first):
 *        A5 5A F0 0F           sync
 *        frame number          8 bits, counts packets sent
 *        STAGE_SHIFT           8 bits
 *        512 x 2 bytes         the input samples
 *        512 x 4 bytes         X[k] as {re, im}
 *        2 bytes               16-bit sum of every byte after the sync,
 *                              up to the checksum
 *
 * A packet takes about 41 ms at 750 kbaud and a new frame comes every 20 ms,
 * so frames that arrive while a packet is going out are skipped; about one
 * frame in three is sent. Steps 1 to 3 take under 6,000 clk (0.5 ms), well
 * inside the 767 clk the ring buffer gives before step 1 must finish.
 */

module fft_frame_uart #(
    parameter int STAGE_SHIFT  = 1,
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        frame_ready,
    output logic [8:0]  read_index,
    input  logic [15:0] read_data,
    output logic        tx,
    output logic        sending,
    output logic [7:0]  status       // {state, fft_done, load_v, 2'b0}, for debugging
);

    localparam int N         = 512;
    localparam int IN_START  = 6;                    // first input byte
    localparam int OUT_START = IN_START + 2 * N;     // 1030, first output byte
    localparam int CSUM_AT   = OUT_START + 4 * N;    // 3078, checksum high byte
    localparam int TOTAL     = CSUM_AT + 2;          // 3080 bytes per packet

    typedef enum logic [3:0] {IDLE, FFT_RESET, LOAD, START, RUN, READ, BYTE_ADDR, BYTE_FIRE, BYTE_WAIT} state_t;
    state_t state;   // needs FSM Encoding Style = Binary in the Radiant strategy: LSE's Auto (one-hot) version never left IDLE on hardware

    logic [9:0]  cnt;               // sample counter while loading and reading
    logic [11:0] byte_idx;          // byte of the packet being sent
    logic [7:0]  frame_num;
    logic [15:0] csum;

    // load pipeline: the ring buffer answers one clk after read_index
    logic        load_v;
    logic [8:0]  load_adr;

    // fft
    logic        fft_reset, fft_start, fft_done;
    logic [31:0] fft_wd;

    // packet buffers
    logic [8:0]  in_raddr, out_raddr;
    logic [15:0] in_rdata;
    logic [31:0] out_rdata;
    logic [7:0]  tx_byte;
    logic        tx_start, tx_busy;
    logic [11:0] in_off, out_off;

    fft #(.width(16), .M(9), .STAGE_SHIFT(STAGE_SHIFT)) u_fft (.clk(clk), .reset(fft_reset), .start(fft_start), .load(load_v), .rd_adr(load_adr), .rd({read_data, 16'h0000}), .wd(fft_wd), .done(fft_done));

    dual_port_ram #(.ADDR_WIDTH(9), .DATA_WIDTH(16)) u_in_buf (.clk(clk), .write_en(load_v), .write_addr(load_adr), .write_data(read_data), .read_addr(in_raddr), .read_data(in_rdata));

    dual_port_ram #(.ADDR_WIDTH(9), .DATA_WIDTH(32)) u_out_buf (.clk(clk), .write_en(state == READ), .write_addr(cnt[8:0]), .write_data(fft_wd), .read_addr(out_raddr), .read_data(out_rdata));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(tx_byte), .busy(tx_busy), .tx(tx));

    assign read_index = cnt[8:0];
    assign fft_reset  = (state == FFT_RESET) | ~reset_b;
    assign fft_start  = (state == START);
    assign tx_start   = (state == BYTE_FIRE) & ~tx_busy;
    assign sending    = (state != IDLE);
    assign status     = {state, fft_done, load_v, 2'b00};

    // ---- which buffer word the current byte comes from ----
    assign in_off    = byte_idx - 12'(IN_START);
    assign out_off   = byte_idx - 12'(OUT_START);
    assign in_raddr  = in_off[9:1];
    assign out_raddr = out_off[10:2];

    always_comb
        if      (byte_idx == 12'd0)            tx_byte = 8'hA5;
        else if (byte_idx == 12'd1)            tx_byte = 8'h5A;
        else if (byte_idx == 12'd2)            tx_byte = 8'hF0;
        else if (byte_idx == 12'd3)            tx_byte = 8'h0F;
        else if (byte_idx == 12'd4)            tx_byte = frame_num;
        else if (byte_idx == 12'd5)            tx_byte = 8'(STAGE_SHIFT);
        else if (byte_idx < 12'(OUT_START))    tx_byte = in_off[0] ? in_rdata[7:0] : in_rdata[15:8];
        else if (byte_idx < 12'(CSUM_AT))
            case (out_off[1:0])
                2'd0:    tx_byte = out_rdata[31:24];
                2'd1:    tx_byte = out_rdata[23:16];
                2'd2:    tx_byte = out_rdata[15:8];
                default: tx_byte = out_rdata[7:0];
            endcase
        else if (byte_idx == 12'(CSUM_AT))     tx_byte = csum[15:8];
        else                                   tx_byte = csum[7:0];

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
            byte_idx  <= '0;
            frame_num <= '0;
            csum      <= '0;
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
                READ:      if (cnt == 10'(N - 1)) begin
                               byte_idx <= '0;
                               csum     <= '0;
                               state    <= BYTE_ADDR;
                           end else cnt <= cnt + 1'b1;
                BYTE_ADDR: state <= BYTE_FIRE;                    // buffer read takes one clk
                BYTE_FIRE: if (!tx_busy) begin
                               if (byte_idx >= 12'd4 && byte_idx < 12'(CSUM_AT)) csum <= csum + 16'(tx_byte);
                               state <= BYTE_WAIT;
                           end
                BYTE_WAIT: if (!tx_busy) begin
                               if (byte_idx == 12'(TOTAL - 1)) begin
                                   frame_num <= frame_num + 1'b1;
                                   state     <= IDLE;
                               end else begin
                                   byte_idx <= byte_idx + 1'b1;
                                   state    <= BYTE_ADDR;
                               end
                           end
                default:   state <= IDLE;
            endcase

endmodule
