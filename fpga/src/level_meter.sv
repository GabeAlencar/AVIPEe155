/*
 * Module: level_meter
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/10/26 (rewritten 11/16/26: smoothed level, hysteresis, no peak-hold dot)
 * Parameters:
 *   N             - number of LEDs in the bar.
 *   LEVELS        - N 16-bit thresholds packed together, LED 0 in the low
 *                   16 bits. LED i turns on when the level goes above
 *                   LEVELS[i] and off when it falls below 3/4 of it.
 *   ATTACK_SHIFT  - the level rises toward |pcm| by 1/2^ATTACK_SHIFT of the
 *                   gap each sample. 4 is about 1 ms at 15.625 kHz.
 *   RELEASE_SHIFT - the level falls toward |pcm| by 1/2^RELEASE_SHIFT of the
 *                   gap each sample. 11 is about 130 ms.
 *   CLIP_SAMPLES  - how long the clip light stays on (7812 = 0.5 s).
 *
 * Hardware test. A VU meter on N LEDs:
 *   led   - a solid bar: LEDs 0 up to the current level are on.
 *   clip  - on for 0.5 s after any sample hits the 16-bit limit (32767 or
 *           -32768), meaning the DC removal output saturated.
 *
 * The level is a smoothed |pcm|: it rises fast and falls slowly, so speech
 * and music move the bar without it flickering on every sample. Each LED
 * also has hysteresis (on above LEVELS[i], off below 3/4 of it), so a sound
 * that sits right at a threshold holds the LED steady. Because the levels
 * go up, the LEDs always form a solid bar.
 *
 * The default levels, about 7 dB apart, come from the mic on the board
 * (fpga/model/captures): a quiet room with a fan sits near 170, under
 * LED 0. A 1 kHz tone from the monitor at moderate volume lights 4.
 *
 * The level keeps RELEASE_SHIFT fraction bits:
 *   level_acc = level * 2^RELEASE_SHIFT
 */

module level_meter #(
    parameter int              N             = 5,
    parameter logic [N*16-1:0] LEVELS        = {16'd10000, 16'd5000, 16'd2500, 16'd1200, 16'd500},
    parameter int              ATTACK_SHIFT  = 4,
    parameter int              RELEASE_SHIFT = 11,
    parameter int              CLIP_SAMPLES  = 7812
) (
    input  logic         clk,
    input  logic         reset_b,
    input  logic [15:0]  pcm,
    input  logic         pcm_valid,
    output logic [N-1:0] led,
    output logic         clip
);

    localparam int ACC_WIDTH = 17 + RELEASE_SHIFT;      // magnitude up to 32768, plus a sign bit for the gap
    localparam int TW        = $clog2(CLIP_SAMPLES + 1);

    logic [15:0]                 magnitude;     // |pcm|, unsigned, so -32768 gives 32768
    logic signed [ACC_WIDTH-1:0] level_acc, target, gap;
    logic [15:0]                 level;
    logic [TW-1:0]               clip_timer;
    logic                        full_scale;

    assign magnitude  = pcm[15] ? (~pcm + 1'b1) : pcm;
    assign target     = ACC_WIDTH'({magnitude, {RELEASE_SHIFT{1'b0}}});
    assign gap        = target - level_acc;
    assign level      = level_acc[RELEASE_SHIFT +: 16];
    assign full_scale = (pcm == 16'h7FFF) | (pcm == 16'h8000);

    // ---- smoothed level: fast attack, slow release ----
    always_ff @(posedge clk, negedge reset_b)
        if      (!reset_b)        level_acc <= '0;
        else if (pcm_valid)
            if (gap > 0)          level_acc <= level_acc + (gap >>> ATTACK_SHIFT);
            else                  level_acc <= level_acc + (gap >>> RELEASE_SHIFT);

    // ---- LEDs with hysteresis: on above the level, off below 3/4 of it ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) led <= '0;
        else
            for (int i = 0; i < N; i++)
                if      (level > LEVELS[i*16 +: 16])                                            led[i] <= 1'b1;
                else if (level < LEVELS[i*16 +: 16] - (LEVELS[i*16 +: 16] >> 2))                led[i] <= 1'b0;

    // ---- clip light ----
    always_ff @(posedge clk, negedge reset_b)
        if (!reset_b) begin
            clip_timer <= '0;
            clip       <= 1'b0;
        end else begin
            if (pcm_valid)
                if      (full_scale)      clip_timer <= TW'(CLIP_SAMPLES);
                else if (clip_timer != 0) clip_timer <= clip_timer - 1'b1;
            clip <= (clip_timer != 0);
        end

endmodule
