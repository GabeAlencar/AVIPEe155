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
 *
 *   word 0          16'hA55A                    sync
 *   word 1          {frame number, STAGE_SHIFT}
 *   words 2..513    re X[0], im X[0], ..., re X[255], im X[255]
 *
 * sck stays low for a few clk between words, with cs_b still low. At 3 MHz
 * a frame takes about 2.9 ms (8,224 sck pulses) and a new one comes every
 * 20 ms. A frame that is ready while the last one is still going out is
 * skipped (the frame number shows the gap).
 *
 * Ports (from fft_controller):
 *   we, waddr, wdata - X[waddr] as {re, im}; a frame is taken only if the
 *                      driver is idle when X[0] arrives
 *   send             - one clk pulse after X[255]: send the frame
 *   frame_num        - frame number for word 1, sampled on send
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

    typedef enum logic [1:0] {IDLE, ADDR, FIRE, WAIT} state_t;
    state_t state;

    logic        taking;            // this frame is being written into the buffer
    logic [9:0]  word_idx, bin_off;
    logic [7:0]  num;
    logic [15:0] word;
    logic [31:0] rdata;
    logic        tx_start, tx_busy;

    dual_port_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_buf (.clk(clk), .write_en(we & (waddr == 8'd0 ? state == IDLE : taking)), .write_addr(waddr), .write_data(wdata), .read_addr(bin_off[8:1]), .read_data(rdata));

    spi_word_tx #(.WIDTH(16), .HALF_PERIOD(HALF_PERIOD)) u_spi_word_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(word), .busy(tx_busy), .sck(sck), .sdo(mosi));

    assign bin_off  = word_idx - 10'd2;                  // bin_off[9:1] is k, bin_off[0] picks re/im
    assign tx_start = (state == FIRE) & ~tx_busy;

    always_comb
        if      (word_idx == 10'd0) word = 16'hA55A;
        else if (word_idx == 10'd1) word = {num, 8'(STAGE_SHIFT)};
        else if (bin_off[0])        word = rdata[15:0];      // im
        else                        word = rdata[31:16];     // re

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            state    <= IDLE;
            taking   <= 1'b0;
            word_idx <= '0;
            num      <= '0;
            cs_b     <= 1'b1;
        end else begin
            if (we && waddr == 8'd0) taking <= (state == IDLE);
            case (state)
                IDLE: if (send && taking) begin
                          taking   <= 1'b0;
                          word_idx <= '0;
                          num      <= frame_num;
                          cs_b     <= 1'b0;
                          state    <= ADDR;
                      end
                ADDR: state <= FIRE;                      // buffer read takes one clk
                FIRE: if (!tx_busy) state <= WAIT;
                WAIT: if (!tx_busy) begin
                          if (word_idx == 10'(WORDS - 1)) begin
                              cs_b  <= 1'b1;
                              state <= IDLE;
                          end else begin
                              word_idx <= word_idx + 1'b1;
                              state    <= ADDR;
                          end
                      end
            endcase
        end

endmodule
