/*
 * Module: uart_tx
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Parameters:
 *   CLKS_PER_BIT - clk cycles per bit. 16 gives 12 MHz / 16 = 750 kbaud.
 *
 * Sends one byte as 8N1 serial: a start bit (0), the 8 data bits LSB
 * first, and a stop bit (1). tx idles high.
 */

module uart_tx #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic       clk,
    input  logic       reset_b,
    input  logic       start,
    input  logic [7:0] data,
    output logic       busy,
    output logic       tx
);

    logic [7:0]                        shift;    // data bits not yet sent
    logic [3:0]                        bit_num;  // 0 start, 1-8 data, 9 stop
    logic [$clog2(CLKS_PER_BIT)-1:0]   count;    // clk cycles within one bit

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            tx      <= 1'b1;
            busy    <= 1'b0;
            shift   <= '0;
            bit_num <= '0;
            count   <= '0;
        end else if (!busy) begin
            if (start) begin
                tx      <= 1'b0;             // start bit
                shift   <= data;
                busy    <= 1'b1;
                bit_num <= '0;
                count   <= '0;
            end
        end else if (count == CLKS_PER_BIT - 1) begin
            count   <= '0;
            bit_num <= bit_num + 1'b1;
            if (bit_num == 4'd9) begin
                busy <= 1'b0;                // stop bit done
            end else begin
                tx    <= (bit_num == 4'd8) ? 1'b1 : shift[0];
                shift <= shift >> 1;
            end
        end else begin
            count <= count + 1'b1;
        end

endmodule
