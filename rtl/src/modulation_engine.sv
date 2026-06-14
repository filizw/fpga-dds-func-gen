`timescale 1ns/1ps
`default_nettype none

// Modulation waveform and scaling engine.
// Generates the modulation oscillator, converts its signed waveform sample into
// FM, PM, or AM control terms, and aligns control metadata with waveform latency.
// FM output is a signed FTW delta, PM output is a signed phase offset, and AM
// output is an unsigned gain in Q1.(AMP_WIDTH-1).
module modulation_engine (
    input  logic               i_clk,
    input  logic               i_rst,
    input  logic               i_en,

    input  dds_pkg::phase_t    i_carr_ftw,
    input  dds_pkg::phase_t    i_mod_ftw,
    input  dds_pkg::amp_t      i_mod_depth,
    input  dds_pkg::mod_type_t i_mod_type,
    input  dds_pkg::waveform_t i_mod_wave,

    output logic               o_mod_valid,
    output dds_pkg::phase_t    o_fm_delta,
    output dds_pkg::phase_t    o_pm_offset,
    output dds_pkg::amp_t      o_am_gain
);

    // Datapath widths and latency.
    localparam int PHASE_WIDTH = dds_pkg::PHASE_WIDTH;
    localparam int AMP_WIDTH   = dds_pkg::AMP_WIDTH;

    localparam int MOD_SAMPLE_WIDTH = dds_pkg::INT_SAMPLE_WIDTH;
    localparam int MOD_LATENCY      = dds_pkg::WAVEFORM_LATENCY;

    // Delay the selected modulation mode through waveform generation, product
    // registration, and output selection.
    localparam int MOD_TYPE_PIPE_DEPTH = MOD_LATENCY + 2;
    localparam int MOD_TYPE_OUT_IDX    = MOD_TYPE_PIPE_DEPTH - 1;

    // Signed modulation sample times unsigned depth. The waveform has
    // MOD_SAMPLE_WIDTH-1 fractional bits; depth is Q1.(AMP_WIDTH-1).
    localparam int MOD_SAMPLE_SCALED_WIDTH = MOD_SAMPLE_WIDTH + AMP_WIDTH + 1;
    localparam int MOD_SAMPLE_FRAC_BITS    = MOD_SAMPLE_WIDTH - 1;
    localparam int MOD_SCALED_FRAC_BITS    = MOD_SAMPLE_FRAC_BITS + AMP_WIDTH - 1;

    localparam int FM_DELTA_EXT_WIDTH  = MOD_SAMPLE_SCALED_WIDTH + PHASE_WIDTH + 1;
    localparam int PM_OFFSET_EXT_WIDTH = MOD_SAMPLE_SCALED_WIDTH + PHASE_WIDTH + 1;

    // Signed products retain modulation polarity for FM and PM.
    typedef logic signed [MOD_SAMPLE_SCALED_WIDTH-1:0] mod_sample_scaled_t;
    typedef logic signed      [FM_DELTA_EXT_WIDTH-1:0] fm_delta_ext_t;
    typedef logic signed     [PM_OFFSET_EXT_WIDTH-1:0] pm_offset_ext_t;
    typedef dds_pkg::amp_ext_t                         am_gain_ext_t;

    // Modulation oscillator state.
    logic                 mod_en;
    logic                 mod_sample_valid;
    dds_pkg::phase_t      mod_phase;
    dds_pkg::int_sample_t mod_sample;

    // Extended products before scale restoration.
    fm_delta_ext_t  fm_delta_ext;
    pm_offset_ext_t pm_offset_ext;
    am_gain_ext_t   am_depth_wave;
    am_gain_ext_t   am_gain_ext;

    dds_pkg::phase_t fm_delta_next;
    dds_pkg::phase_t pm_offset_next;
    dds_pkg::amp_t   am_gain_next;
    fm_delta_ext_t   fm_delta_ext_reg;
    pm_offset_ext_t  pm_offset_ext_reg;
    am_gain_ext_t    am_gain_ext_reg;

    // Delay lines align user controls with the modulation sample that uses them.
    dds_pkg::mod_type_t mod_type_pipe_reg  [0:MOD_TYPE_PIPE_DEPTH-1];
    dds_pkg::amp_t      mod_depth_pipe_reg [0:MOD_LATENCY-1];
    dds_pkg::phase_t    carr_ftw_pipe_reg  [0:MOD_LATENCY-1];
    logic               mod_valid_pipe_reg [0:1];

    mod_sample_scaled_t mod_sample_scaled_reg;
    dds_pkg::amp_t      mod_depth_reg;
    dds_pkg::phase_t    carr_ftw_reg;

    logic            mod_valid_reg;
    dds_pkg::phase_t fm_delta_reg;
    dds_pkg::phase_t pm_offset_reg;
    dds_pkg::amp_t   am_gain_reg;

    int stage;

    assign o_mod_valid = mod_valid_reg;
    assign o_fm_delta  = fm_delta_reg;
    assign o_pm_offset = pm_offset_reg;
    assign o_am_gain   = am_gain_reg;

    // Modulation oscillator.
    // Disabled modulation produces neutral FM/PM/AM outputs after the pipeline
    // drains.
    phase_accumulator u_phase_accumulator (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_en(mod_en),
        .i_ftw(i_mod_ftw),
        .o_phase(mod_phase)
    );

    waveform_generator u_waveform_generator (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_phase_valid(mod_en),
        .i_phase(mod_phase),
        .i_waveform(i_mod_wave),
        .o_sample_valid(mod_sample_valid),
        .o_sample(mod_sample)
    );

    // Product construction.
    // FM depth is relative to carrier FTW. PM depth is relative to half a turn,
    // so full-depth PM spans +/-180 degrees. AM maps depth around unity so
    // depth=0 keeps AMP_ONE and depth=1.0 gives approximately [0.0, 1.0].
    always_comb begin
        mod_en = i_en && (i_mod_type != dds_pkg::MOD_NONE);

        fm_delta_ext  = mod_sample_scaled_reg * $signed({1'b0, carr_ftw_reg});
        pm_offset_ext = mod_sample_scaled_reg * $signed({1'b0, dds_pkg::PHASE_HALF_TURN});
        am_depth_wave = am_gain_ext_t'(mod_sample_scaled_reg >>> MOD_SAMPLE_FRAC_BITS);
        am_gain_ext   = $signed({1'b0, dds_pkg::AMP_ONE - (mod_depth_reg >>> 1)}) + (am_depth_wave >>> 1);
    end

    // Restore fixed-point scale and select the active modulation path.
    // PHASE_WIDTH casts intentionally keep signed FM/PM offsets modulo
    // 2^PHASE_WIDTH for downstream phase arithmetic.
    always_comb begin
        fm_delta_next  = '0;
        pm_offset_next = '0;
        am_gain_next   = dds_pkg::AMP_ONE;

        unique case (mod_type_pipe_reg[MOD_TYPE_OUT_IDX])
            dds_pkg::MOD_FM: fm_delta_next  = PHASE_WIDTH'(fm_delta_ext_reg >>> MOD_SCALED_FRAC_BITS);
            dds_pkg::MOD_PM: pm_offset_next = PHASE_WIDTH'(pm_offset_ext_reg >>> MOD_SCALED_FRAC_BITS);
            dds_pkg::MOD_AM: am_gain_next   = dds_pkg::clamp_signed_amp(am_gain_ext_reg);
            default: begin
            end
        endcase
    end

    // Modulation control pipeline.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            for (stage = 0; stage < MOD_TYPE_PIPE_DEPTH; stage = stage + 1) begin
                mod_type_pipe_reg[stage] <= dds_pkg::MOD_NONE;
            end

            for (stage = 0; stage < MOD_LATENCY; stage = stage + 1) begin
                mod_depth_pipe_reg[stage] <= '0;
                carr_ftw_pipe_reg[stage]  <= '0;
            end

            mod_sample_scaled_reg <= '0;
            mod_depth_reg         <= '0;
            carr_ftw_reg          <= '0;
            fm_delta_ext_reg      <= '0;
            pm_offset_ext_reg     <= '0;
            am_gain_ext_reg       <= '0;
            mod_valid_pipe_reg[0] <= 1'b0;
            mod_valid_pipe_reg[1] <= 1'b0;

            mod_valid_reg <= 1'b0;
            fm_delta_reg  <= '0;
            pm_offset_reg <= '0;
            am_gain_reg   <= dds_pkg::AMP_ONE;
        end
        else begin
            mod_type_pipe_reg[0]  <= i_mod_type;
            mod_depth_pipe_reg[0] <= dds_pkg::clamp_amp(i_mod_depth);
            carr_ftw_pipe_reg[0]  <= i_carr_ftw;

            for (stage = 0; stage < MOD_TYPE_PIPE_DEPTH-1; stage = stage + 1) begin
                mod_type_pipe_reg[stage+1] <= mod_type_pipe_reg[stage];
            end

            for (stage = 0; stage < MOD_LATENCY-1; stage = stage + 1) begin
                mod_depth_pipe_reg[stage+1] <= mod_depth_pipe_reg[stage];
                carr_ftw_pipe_reg[stage+1]  <= carr_ftw_pipe_reg[stage];
            end

            mod_sample_scaled_reg <= mod_sample * $signed({1'b0, mod_depth_pipe_reg[MOD_LATENCY-1]});
            mod_depth_reg         <= mod_depth_pipe_reg[MOD_LATENCY-1];
            carr_ftw_reg          <= carr_ftw_pipe_reg[MOD_LATENCY-1];
            fm_delta_ext_reg      <= fm_delta_ext;
            pm_offset_ext_reg     <= pm_offset_ext;
            am_gain_ext_reg       <= am_gain_ext;
            mod_valid_pipe_reg[0] <= mod_sample_valid;
            mod_valid_pipe_reg[1] <= mod_valid_pipe_reg[0];

            mod_valid_reg <= mod_valid_pipe_reg[1];
            fm_delta_reg  <= fm_delta_next;
            pm_offset_reg <= pm_offset_next;
            am_gain_reg   <= am_gain_next;
        end
    end

endmodule

`default_nettype wire
