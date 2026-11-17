/*
 * Module: dual_port_ram
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   ADDR_WIDTH - number of address bits, so the RAM holds 2**ADDR_WIDTH words.
 *   DATA_WIDTH - number of bits in each word.
 */

module dual_port_ram #(
    parameter int ADDR_WIDTH = 9,
    parameter int DATA_WIDTH = 16
) (
    input  logic                  clk,
    input  logic                  write_en,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic [DATA_WIDTH-1:0] write_data,
    input  logic [ADDR_WIDTH-1:0] read_addr,
    output logic [DATA_WIDTH-1:0] read_data
);

    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

    // ---- write port ----
    always_ff @(posedge clk)
        if (write_en) mem[write_addr] <= write_data;

    // ---- read port ----
    always_ff @(posedge clk)
        read_data <= mem[read_addr];

endmodule
