/*
 * Module: sum_of_3
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/6/26
 * Parameters:
 *   DATA_WIDTH - width of each two's complement input sample.
 */

module sum_of_3 #(
    parameter int DATA_WIDTH = 18
) (
    input  logic                  clk,
    input  logic                  reset_b,
    input  logic [DATA_WIDTH-1:0] sample,
    input  logic                  sample_valid,
    output logic [DATA_WIDTH+1:0] sum,
    output logic                  sum_valid
);

    localparam int SUM_WIDTH = DATA_WIDTH + 2;

    logic [1:0]           sample_count;  // which sample of the group is next: 0, 1, or 2
    logic [SUM_WIDTH-1:0] sample_ext;    // sample sign-extended to the sum width
    logic [SUM_WIDTH-1:0] partial_sum;   // sum of the samples so far in this group
    logic [SUM_WIDTH-1:0] next_sum;
    logic                 last_sample;

    // counts samples 0, 1, 2 and wraps after the third one
    counter #(.WIDTH(2), .MAX(2)) u_sample_counter (.clk(clk), .reset_b(reset_b), .enable(sample_valid), .count(sample_count));

    assign sample_ext  = {{(SUM_WIDTH-DATA_WIDTH){sample[DATA_WIDTH-1]}}, sample};

    // the first sample of a group starts a new sum
    assign next_sum    = (sample_count == 2'd0) ? sample_ext : partial_sum + sample_ext;
    assign last_sample = sample_valid & (sample_count == 2'd2);

    // ---- running sum: holds the finished sum until the next group starts ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)     partial_sum <= '0;
        else if (sample_valid) partial_sum <= next_sum;

    assign sum = partial_sum;

    // sum_valid pulses the clk after the third sample is added
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) sum_valid <= 1'b0;
        else          sum_valid <= last_sample;

endmodule
