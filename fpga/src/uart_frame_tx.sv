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
    localparam int BYTES = 2 * WORDS;

    typedef enum logic {IDLE = 1'b0, SEND = 1'b1} statetype;
    statetype state, nextstate;

    logic        taking;            // this frame is being written into the buffer
    logic [10:0] byte_idx;          // next byte to send, 0 to 1029
    logic [9:0]  word_idx, bin_off;
    logic [7:0]  num;
    logic [15:0] csum, word;
    logic [31:0] rdata;
    logic [7:0]  tx_byte;
    logic        tx_start, tx_busy;

    // X[0..255]; written only while idle, read one clk after the address
    dual_port_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_buf (.clk(clk), .write_en(we & (waddr == 8'd0 ? state == IDLE : taking)), .write_addr(waddr), .write_data(wdata), .read_addr(bin_off[8:1]), .read_data(rdata));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (.clk(clk), .reset_b(reset_b), .start(tx_start), .data(tx_byte), .busy(tx_busy), .tx(tx));

    // ---- byte to send: high byte of each word first ----
    assign word_idx = byte_idx[10:1];
    assign bin_off  = word_idx - 10'd2;
    assign tx_byte  = byte_idx[0] ? word[7:0] : word[15:8];

    always_comb
        if      (word_idx == 10'd0)           word = 16'hA55A;
        else if (word_idx == 10'd1)           word = {num, 8'(STAGE_SHIFT)};
        else if (word_idx == 10'(WORDS - 1))  word = csum;
        else if (bin_off[0])                  word = rdata[15:0];
        else                                  word = rdata[31:16];

    // ---- state register ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) state <= IDLE;
        else          state <= nextstate;

    // ---- next state logic ----
    always_comb
        case (state)
            IDLE:    nextstate = (send && taking) ? SEND : IDLE;
            SEND:    nextstate = (!tx_busy && byte_idx == 11'(BYTES)) ? IDLE : SEND;
            default: nextstate = IDLE;
        endcase

    // start the next byte as soon as the last one is out
    assign tx_start = (state == SEND) & ~tx_busy & (byte_idx != 11'(BYTES));

    // ---- take a frame only if idle when X[0] arrives ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)            taking <= 1'b0;
        else if (we && waddr == 8'd0) taking <= (state == IDLE);
        else if (send)                taking <= 1'b0;

    // ---- byte counter, frame number and checksum ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            byte_idx <= '0;
            num      <= '0;
            csum     <= '0;
        end else if (state == IDLE) begin
            byte_idx <= '0;
            num      <= frame_num;
            csum     <= '0;
        end else if (tx_start) begin
            byte_idx <= byte_idx + 1'b1;
            // add words 1 to 513 to the sum as their low byte goes out
            if (byte_idx[0] && word_idx != 10'd0 && word_idx != 10'(WORDS - 1))
                csum <= csum + word;
        end

endmodule
