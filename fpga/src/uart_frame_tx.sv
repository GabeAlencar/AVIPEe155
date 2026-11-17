/*
 * Module: uart_frame_tx
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 * Parameters:
 *   STAGE_SHIFT  - sent in the frame header, see fft_controller.
 *   CLKS_PER_BIT - clk cycles per UART bit (16 gives 750 kbaud).
 *
 * USART driver for the fft output. Sends the same frame as spi_frame_tx over
 * a UART, so a PC can read it through the UPduino's USB serial port. It
 * keeps its own copy of X[0..255], so the SPI and the UART run
 * independently. One frame is 515 16-bit words, each sent high byte first
 * (1,030 bytes, 8N1):
 *
 *   word 0          16'hA55A                    sync
 *   word 1          {frame number, STAGE_SHIFT}
 *   words 2..513    re X[0], im X[0], ..., re X[255], im X[255]
 *   word 514        16-bit sum of words 1 to 513 (the SPI frame has no sum)
 *
 * A frame takes about 13.7 ms at 750 kbaud and a new one comes every 20 ms,
 * so every frame is sent. A frame that is ready while the last one is still
 * going out is skipped (the frame number shows the gap).
 *
 * Ports (from fft_controller):
 *   we, waddr, wdata - X[waddr] as {re, im}; a frame is taken only if the
 *                      driver is idle when X[0] arrives
 *   send             - one clk pulse after X[255]: send the frame
 *   frame_num        - frame number for word 1, sampled on send
 */

module uart_frame_tx #(
    parameter int STAGE_SHIFT  = 1,
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        reset_b,
    input  logic        we,
    input  logic [7:0]  waddr,
    input  logic [31:0] wdata,
    input  logic        send,
    input  logic [7:0]  frame_num,
    output logic        tx
);

    localparam int WORDS = 515;

    typedef enum logic [1:0] {IDLE, ADDR, FIRE, WAIT} state_t;
    state_t state;

    logic        taking;            // this frame is being written into the buffer

    logic [10:0] byte_idx;          // 0..1029
    logic [9:0]  word_idx, bin_off;
    logic [7:0]  num;
    logic [15:0] csum, word;
    logic [31:0] rdata;
    logic [7:0]  tx_byte;
    logic        tx_start, tx_busy;

    dual_port_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_buf (.clk(clk), .write_en(we & (waddr == 8'd0 ? state == IDLE : taking)), .write_addr(waddr), .write_data(wdata), .read_addr(bin_off[8:1]), .read_data(rdata));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(tx_byte), .busy(tx_busy), .tx(tx));

    assign word_idx = byte_idx[10:1];
    assign bin_off  = word_idx - 10'd2;
    assign tx_start = (state == FIRE) & ~tx_busy;
    assign tx_byte  = byte_idx[0] ? word[7:0] : word[15:8];

    always_comb
        if      (word_idx == 10'd0)           word = 16'hA55A;
        else if (word_idx == 10'd1)           word = {num, 8'(STAGE_SHIFT)};
        else if (word_idx == 10'(WORDS - 1))  word = csum;
        else if (bin_off[0])                  word = rdata[15:0];
        else                                  word = rdata[31:16];

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            state    <= IDLE;
            taking   <= 1'b0;
            byte_idx <= '0;
            num      <= '0;
            csum     <= '0;
        end else begin
            if (we && waddr == 8'd0) taking <= (state == IDLE);
            case (state)
                IDLE: if (send && taking) begin
                          taking   <= 1'b0;
                          byte_idx <= '0;
                          csum     <= '0;
                          num      <= frame_num;
                          state    <= ADDR;
                      end
                ADDR: state <= FIRE;                      // buffer read takes one clk
                FIRE: if (!tx_busy) begin
                          // add each word to the sum as its low byte goes out
                          if (byte_idx[0] && word_idx != 10'd0 && word_idx != 10'(WORDS - 1)) csum <= csum + word;
                          state <= WAIT;
                      end
                WAIT: if (!tx_busy) begin
                          if (byte_idx == 11'(2 * WORDS - 1)) state <= IDLE;
                          else begin
                              byte_idx <= byte_idx + 1'b1;
                              state    <= ADDR;
                          end
                      end
            endcase
        end

endmodule
