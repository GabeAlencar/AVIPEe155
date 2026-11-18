/*
 * Module: spi_frame_tx
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT - sent in the frame header, see fft_controller.
 *   HALF_PERIOD - clk cycles per half sck period. 2 gives 12 MHz / 4 = 3 MHz.
 *
 * SPI driver for the fft output. Keeps its own copy of X[0..255] and sends
 * each frame as an SPI master in mode 0 (sck idles low, the receiver reads
 * mosi on the rising edge of sck), 16-bit words, MSB first, with cs_b low
 * for the whole frame:
 */

module spi_frame_tx #(
    parameter int STAGE_SHIFT = 1,
    parameter int HALF_PERIOD = 2
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        we,
    input  logic [7:0]  waddr,
    input  logic [31:0] wdata,
    input  logic        send,
    input  logic [7:0]  frame_num,
    output logic        sck,
    output logic        mosi,
    output logic        cs_b
);

    localparam int WORDS = 514;

    typedef enum logic {IDLE = 1'b0, SEND = 1'b1} statetype;
    statetype state, nextstate;

    logic        taking;            // this frame is being written into the buffer
    logic [9:0]  word_idx;          // next word to send
    logic [9:0]  bin_off;
    logic [7:0]  num;
    logic [15:0] word;
    logic [31:0] rdata;
    logic        tx_start, tx_busy;

    // X[0..255]; written only while idle, read one clk after the address
    dual_port_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_buf (.clk(clk), .write_en(we & (waddr == 8'd0 ? state == IDLE : taking)), .write_addr(waddr), .write_data(wdata), .read_addr(bin_off[8:1]), .read_data(rdata));

    spi_word_tx #(.WIDTH(16), .HALF_PERIOD(HALF_PERIOD)) u_spi_word_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(word), .busy(tx_busy), .sck(sck), .sdo(mosi));

    // ---- word to send ----
    assign bin_off = word_idx - 10'd2;                   // bin_off[9:1] is k, bin_off[0] picks re/im

    always_comb
        if      (word_idx == 10'd0) word = 16'hA55A;
        else if (word_idx == 10'd1) word = {num, 8'(STAGE_SHIFT)};
        else if (bin_off[0])        word = rdata[15:0];      // im
        else                        word = rdata[31:16];     // re

    // ---- state register ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) state <= IDLE;
        else          state <= nextstate;

    // ---- next state logic ----
    always_comb
        case (state)
            IDLE:    nextstate = (send && taking) ? SEND : IDLE;
            SEND:    nextstate = (!tx_busy && word_idx == 10'(WORDS)) ? IDLE : SEND;
            default: nextstate = IDLE;
        endcase

    // start the next word as soon as the last one is out. The buffer read for
    // it finishes long before, since a word takes 4 * HALF_PERIOD * 16 clk.
    assign tx_start = (state == SEND) & ~tx_busy & (word_idx != 10'(WORDS));

    // ---- take a frame only if idle when X[0] arrives ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)            taking <= 1'b0;
        else if (we && waddr == 8'd0) taking <= (state == IDLE);
        else if (send)                taking <= 1'b0;

    // ---- word counter and frame number ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            word_idx <= '0;
            num      <= '0;
        end else if (state == IDLE) begin
            word_idx <= '0;
            num      <= frame_num;
        end else if (tx_start)
            word_idx <= word_idx + 1'b1;

    // ---- output logic: cs_b from a flop so the pin never glitches ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) cs_b <= 1'b1;
        else          cs_b <= (nextstate == IDLE);

endmodule
