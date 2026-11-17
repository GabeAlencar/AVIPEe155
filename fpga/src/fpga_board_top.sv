/*
 * Module: fpga_board_top
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 *
 * Hardware top level for the UPduino. Makes the 12 MHz clk from the
 * iCE40's internal 48 MHz oscillator (HSOSC divided by 4) and passes
 * everything else straight to fpga_top.
 *
 * The clock is kept out of fpga_top so the testbenches can still drive
 * clk directly without the Lattice simulation library. HSOSC is accurate
 * to about +/-10%, so bclk and ws can be up to 10% off from 3 MHz and
 * 46.875 kHz. The SPH0645 accepts bclk from 2.048 to 4.096 MHz, so this
 * only shifts the sample rate, and with it the FFT bin frequencies.
 */

module fpga_board_top (
    input  logic        reset_b,
    input  logic        sd,
    output logic        bclk,
    output logic        ws,
    input  logic [8:0]  read_index,
    output logic [15:0] read_data,
    output logic        frame_ready
);

    logic clk;

    // 48 MHz / 4 = 12 MHz
    HSOSC #(.CLKHF_DIV("0b10")) u_hsosc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));

    fpga_top u_fpga_top (.clk(clk), .reset_b(reset_b), .sd(sd), .bclk(bclk), .ws(ws), .read_index(read_index), .read_data(read_data), .frame_ready(frame_ready));

endmodule
