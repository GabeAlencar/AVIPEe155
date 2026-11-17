/*
 * Module: ring_buffer
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   ADDR_WIDTH  - number of address bits, so the buffer holds 2**ADDR_WIDTH samples
 *   DATA_WIDTH  - number of bits in each sample.
 *   HOP_SAMPLES - new samples between frames.
 */

module ring_buffer #(
    parameter int ADDR_WIDTH  = 9,
    parameter int DATA_WIDTH  = 16,
    parameter int HOP_SAMPLES = 312
) (
    input  logic                  clk,
    input  logic                  reset_b,
    input  logic [DATA_WIDTH-1:0] pcm,
    input  logic                  pcm_valid,
    input  logic [ADDR_WIDTH-1:0] read_index,
    output logic [DATA_WIDTH-1:0] read_data,
    output logic                  frame_ready
);

    localparam int DEPTH = 2**ADDR_WIDTH;

    logic [ADDR_WIDTH-1:0] write_addr;    // where the next sample goes
    logic [ADDR_WIDTH-1:0] hop_count;     // samples since the last frame boundary
    logic [ADDR_WIDTH-1:0] frame_start;   // address of the oldest sample in the frame
    logic [ADDR_WIDTH-1:0] read_addr;
    logic                  filled;        // DEPTH samples have been written
    logic                  last_addr, hop_done;

    // next write address, wraps after the last address
    counter #(.WIDTH(ADDR_WIDTH), .MAX(DEPTH - 1)) u_write_counter (.clk(clk), .reset_b(reset_b), .enable(pcm_valid), .count(write_addr));

    // samples within one hop
    counter #(.WIDTH(ADDR_WIDTH), .MAX(HOP_SAMPLES - 1)) u_hop_counter (.clk(clk), .reset_b(reset_b), .enable(pcm_valid), .count(hop_count));

    // 512 x 16 block RAM
    dual_port_ram #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_dual_port_ram (.clk(clk), .write_en(pcm_valid), .write_addr(write_addr), .write_data(pcm), .read_addr(read_addr), .read_data(read_data));

    assign last_addr = (write_addr == DEPTH[ADDR_WIDTH-1:0] - 1'b1);
    assign hop_done  = pcm_valid & (hop_count == HOP_SAMPLES[ADDR_WIDTH-1:0] - 1'b1);

    // read_index 0 is the oldest sample of the frame
    assign read_addr = frame_start + read_index;

    // ---- buffer filled flag ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)              filled <= 1'b0;
        else if (pcm_valid & last_addr) filled <= 1'b1;

    // ---- frame registers ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            frame_ready <= 1'b0;
            frame_start <= '0;
        end else begin
            frame_ready <= hop_done & (filled | last_addr);
            // the sample after the one just written is the oldest one kept
            if (hop_done) frame_start <= write_addr + 1'b1;
        end

endmodule
