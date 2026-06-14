`timescale 1ns/1ps
`default_nettype none

// Flat-port wrapper for dds_core.
// Converts board- or tool-friendly scalar ports into the packed configuration
// record used internally. Numeric encodings match dds_pkg exactly.
module dds_core_wrapper (
    input  wire              i_clk,
    input  wire              i_rst,

    input  wire              i_en,
    input  wire              i_cfg_rst,

    input  wire       [31:0] i_carr_ftw,
    input  wire       [31:0] i_carr_phase,
    input  wire       [11:0] i_carr_amp,
    input  wire        [1:0] i_carr_wave,

    input  wire       [31:0] i_mod_ftw,
    input  wire       [11:0] i_mod_depth,
    input  wire        [1:0] i_mod_type,
    input  wire        [1:0] i_mod_wave,

    output wire              o_sample_valid,
    output wire signed [7:0] o_sample
);

    // Packed configuration image passed through to the core.
    dds_pkg::dds_config_t cfg;

    assign cfg.en         = i_en;
    assign cfg.rst        = i_cfg_rst;
    assign cfg.carr_ftw   = i_carr_ftw;
    assign cfg.carr_phase = i_carr_phase;
    assign cfg.carr_amp   = i_carr_amp;
    assign cfg.carr_wave  = dds_pkg::waveform_t'(i_carr_wave);
    assign cfg.mod_ftw    = i_mod_ftw;
    assign cfg.mod_depth  = i_mod_depth;
    assign cfg.mod_type   = dds_pkg::mod_type_t'(i_mod_type);
    assign cfg.mod_wave   = dds_pkg::waveform_t'(i_mod_wave);

    dds_core u_dds_core (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_cfg(cfg),
        .o_sample_valid(o_sample_valid),
        .o_sample(o_sample)
    );

endmodule

`default_nettype wire
