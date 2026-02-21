/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_vga_starfield (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,      // must be 25.175 MHz
    input  wire       rst_n
);

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // ─────────────────────────────────────────────
    // VGA Timing (640x480 @ 60Hz, 25MHz pixel clk)
    // ─────────────────────────────────────────────
    // Horizontal: 640 visible + 16 fp + 96 sync + 48 bp = 800 total
    // Vertical:   480 visible + 10 fp +  2 sync + 33 bp = 525 total

    reg [9:0] hcount; // 0–799
    reg [9:0] vcount; // 0–524

    wire hsync_pulse = (hcount >= 10'd656) && (hcount < 10'd752);
    wire vsync_pulse = (vcount >= 10'd490) && (vcount < 10'd492);
    wire active      = (hcount < 10'd640) && (vcount < 10'd480);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcount <= 0;
            vcount <= 0;
        end else begin
            if (hcount == 10'd799) begin
                hcount <= 0;
                vcount <= (vcount == 10'd524) ? 10'd0 : vcount + 1'b1;
            end else begin
                hcount <= hcount + 1'b1;
            end
        end
    end

    // ─────────────────────────────────────────────
    // Star LFSR — 16-bit Galois, advances each pixel
    // Taps: x^16 + x^15 + x^13 + x^4 + 1
    // ─────────────────────────────────────────────
    reg [15:0] lfsr_star;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_star <= 16'hACE1;
        else if (active)
            lfsr_star <= {1'b0, lfsr_star[15:1]} ^
                         (lfsr_star[0] ? 16'hB400 : 16'h0000);
    end

    // A pixel is a "star" if the LFSR output is very sparse
    // Threshold controls density — ~1 in 256 pixels
    wire is_star = (lfsr_star[7:0] == 8'hFF);

    // ─────────────────────────────────────────────
    // Twinkle LFSR — slow 8-bit, advances each line
    // ─────────────────────────────────────────────
    reg [7:0] lfsr_twinkle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_twinkle <= 8'hA5;
        else if (hcount == 10'd799) // advance once per line
            lfsr_twinkle <= {lfsr_twinkle[6:0], 
                             lfsr_twinkle[7] ^ lfsr_twinkle[5] ^
                             lfsr_twinkle[4] ^ lfsr_twinkle[3]};
    end

    wire twinkle_on = ui_in[0] ? lfsr_twinkle[vcount[2:0]] : 1'b1;

    // ─────────────────────────────────────────────
    // Scene Composition
    // ─────────────────────────────────────────────

    // Sky region: top 360 lines = deep space
    wire in_space   = (vcount < 10'd360);

    // Horizon glow: lines 360–479, brightness fades with distance
    // Use vcount[3] as a cheap dither for gradient effect
    wire in_horizon  = (vcount >= 10'd360) && active;
    wire [9:0] horizon_dist = vcount - 10'd360; // 0–119
    // Dithered gradient: lit if lower bits of hcount < (120 - dist)
    wire horizon_glow = ui_in[1] && in_horizon &&
                        (hcount[2:0] < horizon_dist[2:0]) &&
                        (horizon_dist < 10'd80);

    // Star color: white, but twinkle dims to blue
    wire star_r = is_star && in_space && twinkle_on;
    wire star_g = is_star && in_space && twinkle_on;
    wire star_b = is_star && in_space; // blue stays on even when dim

    // Horizon: warm amber glow (R+G, no B)
    wire glow_r = horizon_glow;
    wire glow_g = horizon_glow && (horizon_dist < 10'd40); // green fades sooner
    wire glow_b = 1'b0;

    // Combine layers
    wire pixel_r = active ? (star_r | glow_r) : 1'b0;
    wire pixel_g = active ? (star_g | glow_g) : 1'b0;
    wire pixel_b = active ? (star_b | glow_b) : 1'b0;

    // Nebula invert mode
    wire out_r = ui_in[2] ? ~pixel_r : pixel_r;
    wire out_g = ui_in[2] ? ~pixel_g : pixel_g;
    wire out_b = ui_in[2] ? ~pixel_b : pixel_b;

    // ─────────────────────────────────────────────
    // Output
    // ─────────────────────────────────────────────
    // TT VGA PMOD: active-low sync
    assign uo_out[0] = out_r;
    assign uo_out[1] = out_g;
    assign uo_out[2] = out_b;
    assign uo_out[3] = ~vsync_pulse;
    assign uo_out[4] = 1'b0;
    assign uo_out[5] = 1'b0;
    assign uo_out[6] = 1'b0;
    assign uo_out[7] = ~hsync_pulse;

endmodule
