/*
 * Module: spi_word_tx
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Parameters:
 *   WIDTH       - bits per word.
 *   HALF_PERIOD - clk cycles per half sck period. 4 gives 12 MHz / 8 = 1.5 MHz.
 *
 * Sends one word as an SPI master in mode 0 (sck idles low, data is read
 * on the rising edge of sck), MSB first. 
 */

module spi_word_tx #(
    parameter int WIDTH       = 16,
    parameter int HALF_PERIOD = 4
) (
    input  logic             clk,
    input  logic             reset_b,
    input  logic             start,
    input  logic [WIDTH-1:0] data,
    output logic             busy,
    output logic             sck,
    output logic             sdo
);

    logic [WIDTH-1:0]               shift;
    logic [$clog2(WIDTH+1)-1:0]     bits_left;
    logic [$clog2(HALF_PERIOD)-1:0] div;      // clk cycles within one half period
    logic                           half_done;

    assign half_done = (div == HALF_PERIOD[$clog2(HALF_PERIOD)-1:0] - 1'b1);
    assign sdo       = shift[WIDTH-1];

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            busy      <= 1'b0;
            sck       <= 1'b0;
            shift     <= '0;
            bits_left <= '0;
            div       <= '0;
        end else if (!busy) begin
            div <= '0;
            sck <= 1'b0;
            if (start) begin
                busy      <= 1'b1;
                shift     <= data;
                bits_left <= WIDTH[$clog2(WIDTH+1)-1:0];
            end
        end else begin
            div <= half_done ? '0 : div + 1'b1;
            if (half_done) begin
                if (!sck) begin
                    sck <= 1'b1;                    // receiver reads sdo here
                end else begin
                    sck       <= 1'b0;              // next bit goes out
                    shift     <= shift << 1;
                    bits_left <= bits_left - 1'b1;
                    if (bits_left == 1) busy <= 1'b0;
                end
            end
        end

endmodule
