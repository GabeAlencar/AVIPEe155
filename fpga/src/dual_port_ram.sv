/*
 * Module: dual_port_ram
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   ADDR_WIDTH - number of address bits, so the RAM holds 2**ADDR_WIDTH words.
 *   DATA_WIDTH - number of bits in each word.
 *
 * Simple dual-port RAM: one write port and one read port on the same clk.
 * Like sbox_sync from Lab 7, the read is synchronous, so Radiant maps the
 * memory to embedded block RAM (EBR) instead of logic. 512 x 16 uses 2 of
 * the 30 EBR blocks (256 x 16 each).
 *
 * write_data is stored at write_addr on each clk edge where write_en is
 * high. read_data is the word at read_addr, one clk later. The RAM has no
 * reset, since EBR contents cannot be cleared by a reset.
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

    // ---- read port, registered so it maps to EBR ----
    always_ff @(posedge clk)
        read_data <= mem[read_addr];

endmodule
