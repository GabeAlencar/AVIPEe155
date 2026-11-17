`timescale 1 ns/1 ps

/*
 * Module: HSOSC (simulation stand-in)
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26
 * Note: Behavioral model of the iCE40UP 48 MHz oscillator for testbenches
 *   that run a top level with HSOSC in it, without the Lattice simulation
 *   library. CLKHF is 48 MHz divided by 1, 2, 4, or 8 (CLKHF_DIV "0b00" to
 *   "0b11"). Compile it only for simulation, never in Radiant. If the
 *   Lattice iCE40UP library is compiled too, leave this file out.
 */

module HSOSC #(
    parameter CLKHF_DIV = "0b00"
) (
    input  logic CLKHFPU,
    input  logic CLKHFEN,
    output logic CLKHF
);

    localparam real HALF_48M = 10.4167;   // ns
    localparam real HALF = (CLKHF_DIV == "0b01") ? 2 * HALF_48M :
                           (CLKHF_DIV == "0b10") ? 4 * HALF_48M :
                           (CLKHF_DIV == "0b11") ? 8 * HALF_48M : HALF_48M;

    initial CLKHF = 1'b0;
    always begin
        #(HALF);
        CLKHF = (CLKHFPU && CLKHFEN) ? ~CLKHF : 1'b0;
    end

endmodule
