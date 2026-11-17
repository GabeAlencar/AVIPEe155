/*
 * Module: frame_dumper
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Parameters:
 *   ADDR_WIDTH  - ring buffer address bits (9 for 512 samples).
 *   HALF_PERIOD - clk cycles per half sck period.
 *
 * Hardware test. On each frame_ready, reads the whole frame out of the
 * ring buffer through read_index and sends it over SPI mode 0, MSB first,
 * with cs_b low for the whole frame:
 *   word 0       frame number (counts from 0 after reset)
 *   words 1-512  the frame, oldest sample first
 *
 * With HALF_PERIOD = 4 each word takes 128 clk, so sample i is read about
 * 131 (i + 1) clk after frame_ready. That is well before the ring buffer
 * overwrites it (767 + 768 i clk after frame_ready), and the whole frame
 * is sent long before the next frame_ready.
 */

module frame_dumper #(
    parameter int ADDR_WIDTH  = 9,
    parameter int HALF_PERIOD = 4
) (
    input  logic                  clk,
    input  logic                  reset_b,
    input  logic                  frame_ready,
    output logic [ADDR_WIDTH-1:0] read_index,
    input  logic [15:0]           read_data,
    output logic                  sck,
    output logic                  sdo,
    output logic                  cs_b
);

    typedef enum logic [2:0] {IDLE, HEADER, WAIT_TX, FETCH, LOAD, SEND} state_t;
    state_t state;

    logic [15:0] frame_num;
    logic        last_word;     // the word being sent is the last sample
    logic        start, busy;
    logic [15:0] tx_data;

    spi_word_tx #(.WIDTH(16), .HALF_PERIOD(HALF_PERIOD)) u_spi_word_tx (.clk(clk), .reset_b(reset_b), .start(start), .data(tx_data), .busy(busy), .sck(sck), .sdo(sdo));

    assign start   = (state == HEADER) | (state == SEND);
    assign tx_data = (state == HEADER) ? frame_num : read_data;

    // ---- sequencer ----
    // FETCH sets read_index, LOAD waits while the block RAM reads it, and
    // SEND hands read_data to the transmitter.
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            state      <= IDLE;
            frame_num  <= '0;
            read_index <= '0;
            last_word  <= 1'b0;
            cs_b       <= 1'b1;
        end else begin
            case (state)
                IDLE:    if (frame_ready) begin
                             cs_b      <= 1'b0;
                             last_word <= 1'b0;
                             state     <= HEADER;
                         end
                HEADER:  begin
                             frame_num  <= frame_num + 1'b1;
                             read_index <= '0;
                             state      <= WAIT_TX;
                         end
                WAIT_TX: if (!busy && !start) begin
                             if (last_word) begin
                                 cs_b  <= 1'b1;
                                 state <= IDLE;
                             end else begin
                                 state <= FETCH;
                             end
                         end
                FETCH:   state <= LOAD;
                LOAD:    state <= SEND;
                SEND:    begin
                             last_word  <= (read_index == '1);
                             read_index <= read_index + 1'b1;
                             state      <= WAIT_TX;
                         end
                default: state <= IDLE;
            endcase
        end

endmodule
