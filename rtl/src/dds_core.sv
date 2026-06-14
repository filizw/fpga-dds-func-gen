`timescale 1ns/1ps
`default_nettype none

// Top-level DDS signal path.
// Samples and clamps the configuration, applies optional FM/PM/AM modulation,
// generates the selected carrier waveform, then scales and saturates the output
// sample. The AM gain path is delayed to match the carrier waveform latency.
module dds_core (
    input  logic                 i_clk,
    input  logic                 i_rst,

    input  dds_pkg::dds_config_t i_cfg,

    output logic                 o_sample_valid,
    output dds_pkg::sample_t     o_sample
);

    // Phase control adds two registered stages before waveform generation.
    // AM gain is generated before carrier phase control, so it must be delayed
    // by those stages plus the waveform generator latency.
    localparam int PHASE_CONTROL_OUTPUT_LATENCY = 2;
    localparam int AM_GAIN_ALIGNMENT_LATENCY =
        PHASE_CONTROL_OUTPUT_LATENCY + dds_pkg::WAVEFORM_LATENCY;

    // Registered configuration is the external control boundary inside the core.
    // cfg.rst becomes an internal synchronous reset for the signal path.
    dds_pkg::dds_config_t cfg_reg;
    logic                 rst;

    // Modulation outputs in the formats defined by modulation_engine.
    logic                                                         mod_valid;
    dds_pkg::amp_t                                                am_gain;
    logic [AM_GAIN_ALIGNMENT_LATENCY-1:0]                         am_gain_valid_pipe_reg;
    logic [AM_GAIN_ALIGNMENT_LATENCY-1:0][dds_pkg::AMP_WIDTH-1:0] am_gain_pipe_reg;
    dds_pkg::amp_t                                                am_gain_eff;

    // Carrier phase terms in DDS phase units.
    dds_pkg::phase_t fm_delta;
    dds_pkg::phase_t pm_offset;
    dds_pkg::phase_t acc_phase;

    // Internal carrier sample before output gain scaling.
    logic                 carrier_sample_valid;
    dds_pkg::int_sample_t carrier_sample;

    assign rst         = i_rst | cfg_reg.rst;
    assign am_gain_eff = am_gain_valid_pipe_reg[AM_GAIN_ALIGNMENT_LATENCY-1]
                       ? dds_pkg::amp_t'(am_gain_pipe_reg[AM_GAIN_ALIGNMENT_LATENCY-1])
                       : dds_pkg::AMP_ONE;

    // Clamp gain controls before they enter multiplier pipelines.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            cfg_reg <= dds_pkg::default_config();
        end
        else begin
            cfg_reg <= dds_pkg::clamp_config(i_cfg);
        end
    end

    modulation_engine u_modulation_engine (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_en(cfg_reg.en),
        .i_carr_ftw(cfg_reg.carr_ftw),
        .i_mod_ftw(cfg_reg.mod_ftw),
        .i_mod_depth(cfg_reg.mod_depth),
        .i_mod_type(cfg_reg.mod_type),
        .i_mod_wave(cfg_reg.mod_wave),
        .o_mod_valid(mod_valid),
        .o_fm_delta(fm_delta),
        .o_pm_offset(pm_offset),
        .o_am_gain(am_gain)
    );

    // AM gain alignment pipeline.
    // Missing or inactive AM samples use unity gain, keeping non-AM modes
    // independent of stale modulation pipeline contents.
    always_ff @(posedge i_clk) begin
        if (rst) begin
            am_gain_valid_pipe_reg <= '0;
            am_gain_pipe_reg       <= {AM_GAIN_ALIGNMENT_LATENCY{dds_pkg::AMP_ONE}};
        end
        else begin
            am_gain_valid_pipe_reg <= {am_gain_valid_pipe_reg[AM_GAIN_ALIGNMENT_LATENCY-2:0], mod_valid};
            am_gain_pipe_reg       <= {am_gain_pipe_reg[AM_GAIN_ALIGNMENT_LATENCY-2:0], am_gain};
        end
    end

    phase_control u_phase_control (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_en(cfg_reg.en),
        .i_carr_ftw(cfg_reg.carr_ftw),
        .i_carr_phase(cfg_reg.carr_phase),
        .i_mod_valid(mod_valid),
        .i_fm_delta(fm_delta),
        .i_pm_offset(pm_offset),
        .o_acc_phase(acc_phase)
    );

    waveform_generator u_waveform_generator (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_phase_valid(cfg_reg.en),
        .i_phase(acc_phase),
        .i_waveform(cfg_reg.carr_wave),
        .o_sample_valid(carrier_sample_valid),
        .o_sample(carrier_sample)
    );

    amplitude_control u_amplitude_control (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_sample_valid(carrier_sample_valid),
        .i_sample(carrier_sample),
        .i_carr_amp(cfg_reg.carr_amp),
        .i_am_gain(am_gain_eff),
        .o_sample_valid(o_sample_valid),
        .o_sample(o_sample)
    );

endmodule

`default_nettype wire
