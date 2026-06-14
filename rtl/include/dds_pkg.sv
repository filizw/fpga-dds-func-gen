`timescale 1ns/1ps
`ifndef DDS_PKG_SV
`define DDS_PKG_SV

// Shared DDS type, scale, and configuration package.
// Centralizes phase units, fixed-point gain/sample formats, and clamp helpers so
// the RTL datapath uses one numeric convention.
package dds_pkg;

    // Shared numeric contract for the DDS datapath.
    // Phase values are unsigned modulo-2^PHASE_WIDTH turns:
    // 0x0000_0000 = 0 degrees, 0x4000_0000 = 90 degrees.
    // Amplitudes are unsigned Q1.(AMP_WIDTH-1), where AMP_ONE is unity gain.
    // Internal samples keep guard bits so waveform generation and gain stages can
    // round and saturate only at the final output boundary.
    localparam int SAMPLE_WIDTH     = 8;
    localparam int INT_SAMPLE_WIDTH = SAMPLE_WIDTH + 4;
    localparam int PHASE_WIDTH      = 32;
    localparam int AMP_WIDTH        = INT_SAMPLE_WIDTH;
    localparam int CORDIC_MAX_ITER  = 14;
    localparam int CORDIC_ITER      = (INT_SAMPLE_WIDTH > CORDIC_MAX_ITER) ? CORDIC_MAX_ITER : INT_SAMPLE_WIDTH;
    localparam int WAVEFORM_LATENCY = CORDIC_ITER + 1;

    localparam int AMP_MULT1_WIDTH  = INT_SAMPLE_WIDTH + AMP_WIDTH;
    localparam int AMP_OUTPUT_SHIFT = (INT_SAMPLE_WIDTH - SAMPLE_WIDTH) + 2*(AMP_WIDTH - 1);

    // Fixed-point types used by all RTL modules.
    typedef logic             [PHASE_WIDTH-1:0] phase_t;
    typedef logic signed        [PHASE_WIDTH:0] phase_ext_t;
    typedef logic               [AMP_WIDTH-1:0] amp_t;
    typedef logic signed     [SAMPLE_WIDTH-1:0] sample_t;
    typedef logic signed [INT_SAMPLE_WIDTH-1:0] int_sample_t;
    typedef logic signed   [INT_SAMPLE_WIDTH:0] int_sample_ext_t;
    typedef logic signed  [AMP_MULT1_WIDTH-1:0] amp_mult1_t;
    typedef logic signed          [AMP_WIDTH:0] amp_ext_t;

    // Saturation limits and canonical scale factors.
    localparam amp_t        AMP_ONE         = amp_t'(amp_t'(1'b1) << (AMP_WIDTH-1));
    localparam phase_t      PHASE_HALF_TURN = phase_t'(phase_t'(1'b1) << (PHASE_WIDTH-1));
    localparam sample_t     SAMPLE_MAX      = {1'b0, {(SAMPLE_WIDTH-1){1'b1}}};
    localparam sample_t     SAMPLE_MIN      = {1'b1, {(SAMPLE_WIDTH-1){1'b0}}};
    localparam int_sample_t INT_SAMPLE_MAX  = {1'b0, {(INT_SAMPLE_WIDTH-1){1'b1}}};
    localparam int_sample_t INT_SAMPLE_MIN  = {1'b1, {(INT_SAMPLE_WIDTH-1){1'b0}}};

    // Supported carrier and modulation waveforms.
    typedef enum logic [1:0] {
        WAVE_DC       = 2'd0,
        WAVE_SINE     = 2'd1,
        WAVE_SQUARE   = 2'd2,
        WAVE_TRIANGLE = 2'd3
    } waveform_t;

    typedef enum logic [1:0] {
        MOD_NONE = 2'd0,
        MOD_AM   = 2'd1,
        MOD_FM   = 2'd2,
        MOD_PM   = 2'd3
    } mod_type_t;

    // Runtime configuration sampled by dds_core.
    // carr_ftw and mod_ftw are frequency tuning words in DDS phase units per clk.
    // carr_phase is a static phase offset in the same phase units.
    // carr_amp and mod_depth are clamped to [0.0, 1.0].
    typedef struct packed {
        logic      en;
        logic      rst;

        phase_t    carr_ftw;
        phase_t    carr_phase;
        amp_t      carr_amp;
        waveform_t carr_wave;

        phase_t    mod_ftw;
        amp_t      mod_depth;
        mod_type_t mod_type;
        waveform_t mod_wave;
    } dds_config_t;

    // Clamp unsigned Q1.(AMP_WIDTH-1) gain values to unity.
    function automatic amp_t clamp_amp(input amp_t value);
        clamp_amp = (value > AMP_ONE) ? AMP_ONE : value;
    endfunction

    // Clamp signed gain math back to the legal unsigned gain range.
    // Negative AM gain is treated as silence rather than phase inversion.
    function automatic amp_t clamp_signed_amp(input amp_ext_t value);
        begin
            if (value <= '0) begin
                clamp_signed_amp = '0;
            end
            else if (value > $signed({1'b0, AMP_ONE})) begin
                clamp_signed_amp = AMP_ONE;
            end
            else begin
                clamp_signed_amp = amp_t'(value[AMP_WIDTH-1:0]);
            end
        end
    endfunction

    // Saturate a one-guard-bit internal sample to the internal waveform range.
    function automatic int_sample_t clamp_int_sample(input int_sample_ext_t value);
        localparam int_sample_ext_t INT_SAMPLE_MAX_EXT =
            {{1{INT_SAMPLE_MAX[INT_SAMPLE_WIDTH-1]}}, INT_SAMPLE_MAX};
        localparam int_sample_ext_t INT_SAMPLE_MIN_EXT =
            {{1{INT_SAMPLE_MIN[INT_SAMPLE_WIDTH-1]}}, INT_SAMPLE_MIN};

        begin
            if (value > INT_SAMPLE_MAX_EXT) begin
                clamp_int_sample = INT_SAMPLE_MAX;
            end
            else if (value < INT_SAMPLE_MIN_EXT) begin
                clamp_int_sample = INT_SAMPLE_MIN;
            end
            else begin
                clamp_int_sample = value[INT_SAMPLE_WIDTH-1:0];
            end
        end
    endfunction

    // Apply a signed FM delta to the unsigned carrier FTW and clamp to [0, max].
    // This prevents negative effective frequency while preserving full positive range.
    function automatic phase_t clamp_ftw_delta(
        input phase_t base,
        input phase_t delta
    );
        phase_ext_t sum_ext;

        begin
            sum_ext = $signed({1'b0, base}) + $signed({delta[PHASE_WIDTH-1], delta});

            if (sum_ext <= '0) begin
                clamp_ftw_delta = '0;
            end
            else if (sum_ext > $signed({1'b0, {PHASE_WIDTH{1'b1}}})) begin
                clamp_ftw_delta = '1;
            end
            else begin
                clamp_ftw_delta = phase_t'(sum_ext[PHASE_WIDTH-1:0]);
            end
        end
    endfunction

    // Add a signed phase offset to an unsigned phase word.
    // Truncation is intentional and implements phase wrapping modulo 2^PHASE_WIDTH.
    function automatic phase_t add_phase_offset(
        input phase_t base,
        input phase_t offset
    );
        phase_ext_t offset_ext;

        begin
            offset_ext       = $signed({offset[PHASE_WIDTH-1], offset});
            add_phase_offset = PHASE_WIDTH'($signed({1'b0, base}) + offset_ext);
        end
    endfunction

    // Disabled sine carrier with unity gain is the benign power-up configuration.
    function automatic dds_config_t default_config();
        dds_config_t cfg;

        cfg.en         = 1'b0;
        cfg.rst        = 1'b0;
        cfg.carr_ftw   = '0;
        cfg.carr_phase = '0;
        cfg.carr_amp   = AMP_ONE;
        cfg.carr_wave  = WAVE_SINE;
        cfg.mod_ftw    = '0;
        cfg.mod_depth  = '0;
        cfg.mod_type   = MOD_NONE;
        cfg.mod_wave   = WAVE_SINE;

        default_config = cfg;
    endfunction

    // Bound user-visible amplitude controls before they enter multiplier pipelines.
    function automatic dds_config_t clamp_config(input dds_config_t cfg);
        dds_config_t clamped;

        clamped           = cfg;
        clamped.carr_amp  = clamp_amp(cfg.carr_amp);
        clamped.mod_depth = clamp_amp(cfg.mod_depth);

        clamp_config = clamped;
    endfunction

endpackage

`endif
