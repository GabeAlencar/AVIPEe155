/*
 * Module: synchronizer
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   WIDTH - number of bits to synchronize.
 *
 * Two flop synchronizer for asynchronous inputs. Reused from Lab 3.
 */

module synchronizer #(
    parameter int WIDTH = 1
) (
    input  logic             clk,
    input  logic             reset_b,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

    logic [WIDTH-1:0] sync_stage1;

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            sync_stage1 <= '0;
            q           <= '0;
        end else begin
            sync_stage1 <= d;
            q           <= sync_stage1;
        end

endmodule
