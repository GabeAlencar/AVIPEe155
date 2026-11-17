/*
 * Module: mic_fft_test_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/15/26
 * Parameters:
 *   STAGE_SHIFT - fft scaling, see fft_butterfly. 1 for 16-bit pcm.
 *
 * Hardware test of the mic chain and Katie's FFT together on the UPduino:
 *
 *   SPH0645 -> i2s_receiver -> sum_of_3 -> dc_removal -> ring_buffer -> fft
 *
 * Every frame the ring buffer finishes, fft_frame_uart loads it into the
 * fft, runs it, and sends the input frame and the 512 fft outputs to the PC
 * over the USB serial port (pin 14). Frames that come while a packet is
 * still going out are skipped. Read the packets with
 * fpga/model/fft_capture.py and fpga/model/hw_fft_full.ipynb.
 *
 * LEDs: bar[4:0] and led_clip are the VU meter from mic_hw_test_top.
 * led_heartbeat (D6) toggles every 25 frames, so it blinks once a second
 * while the mic chain and ring buffer are running.
 */

module mic_fft_test_top #(
    parameter int STAGE_SHIFT = 1
) (
    input  logic       reset_b,
    input  logic       sd,
    output logic       bclk,
    output logic       ws,
    output logic [4:0] bar,
    output logic       led_heartbeat,
    output logic       led_clip,
    output logic       uart_tx
);

    logic        clk;
    logic [17:0] sample;
    logic        sample_valid;
    logic [19:0] sum;
    logic        sum_valid;
    logic [15:0] pcm;
    logic        pcm_valid;
    logic [8:0]  read_index;
    logic [15:0] read_data;
    logic        frame_ready;
    logic        sending, sending_d;
    logic [7:0]  status, frames_seen;
    logic        pkt_tx, st_tx, st_start, st_busy, in_packet;
    logic [13:0] st_timer;
    logic [23:0] st_bytes;
    logic [1:0]  st_left;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    // ---- the chain, same as fpga_top ----
    i2s_receiver #(.DATA_WIDTH(18), .CHANNEL(1'b0)) u_i2s_receiver (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .sample(sample), .sample_valid(sample_valid));

    sum_of_3 #(.DATA_WIDTH(18)) u_sum_of_3 (.clk(clk), .reset_b(reset_b), .sample(sample), .sample_valid(sample_valid), .sum(sum), .sum_valid(sum_valid));

    dc_removal #(.IN_WIDTH(20), .OUT_WIDTH(16), .AVERAGE_SHIFT(10)) u_dc_removal (.clk(clk), .reset_b(reset_b), .sum(sum), .sum_valid(sum_valid), .pcm(pcm), .pcm_valid(pcm_valid));

    ring_buffer #(.ADDR_WIDTH(9), .DATA_WIDTH(16), .HOP_SAMPLES(312)) u_ring_buffer (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

    // ---- ring buffer -> fft -> PC ----
    fft_frame_uart #(.STAGE_SHIFT(STAGE_SHIFT), .CLKS_PER_BIT(16)) u_fft_frame_uart (.clk(clk), .reset_b(reset_b), .frame_ready(frame_ready), .read_index(read_index), .read_data(read_data), .tx(pkt_tx), .sending(sending), .status(status));

    // ---- debug status: EE, status, frames seen, every 1 ms while no packet bytes go out ----
    // state codes: 0 IDLE, 1 FFT_RESET, 2 LOAD, 3 START, 4 RUN, 5 READ, 6-8 sending
    assign in_packet = (status[7:4] >= 4'd6);
    uart_tx #(.CLKS_PER_BIT(16)) u_status_tx (.clk(clk), .reset_b(reset_b), .start(st_start), .data(st_bytes[23:16]), .busy(st_busy), .tx(st_tx));
    assign st_start = (st_left != 2'd0) & ~st_busy;
    assign uart_tx  = (in_packet | sending_d & (status[7:4] >= 4'd6)) ? pkt_tx : st_tx;

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            st_timer <= '0; st_bytes <= '0; st_left <= '0; frames_seen <= '0;
        end else begin
            if (frame_ready) frames_seen <= frames_seen + 1'b1;
            st_timer <= st_timer + 1'b1;
            if (st_timer == 14'd11999 && !in_packet && st_left == 2'd0 && !st_busy) begin
                st_bytes <= {8'hEE, status, frames_seen};
                st_left  <= 2'd3;
                st_timer <= '0;
            end else if (st_timer == 14'd11999) st_timer <= '0;
            else if (st_start) begin
                st_bytes <= st_bytes << 8;
                st_left  <= st_left - 1'b1;
            end
        end

    // ---- LEDs ----
    level_meter #(.N(5)) u_level_meter (.clk(clk), .reset_b(reset_b), .pcm(pcm), .pcm_valid(pcm_valid), .led(bar), .clip(led_clip));

    // heartbeat: toggles every 25 frames (0.5 s at 50 frames/s), so it
    // blinks once a second while the mic chain and ring buffer are running
    logic [4:0] hb_count;

    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            sending_d     <= 1'b0;
            led_heartbeat <= 1'b0;
            hb_count      <= '0;
        end else begin
            sending_d <= sending;
            if (frame_ready)
                if (hb_count == 5'd24) begin
                    hb_count      <= '0;
                    led_heartbeat <= ~led_heartbeat;
                end else hb_count <= hb_count + 1'b1;
        end

endmodule
