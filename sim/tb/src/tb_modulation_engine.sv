`timescale 1ns/1ps
`default_nettype none

// Modulation-engine unit testbench.
// Checks neutral modulation, DC-depth scaling for AM/FM/PM, and signed FM
// polarity using an alternating square modulation waveform.
module tb_modulation_engine;
    import tb_common_pkg::*;

    localparam int MOD_SAMPLE_FRAC_BITS = dds_pkg::INT_SAMPLE_WIDTH - 1;
    localparam int MOD_SCALED_FRAC_BITS = MOD_SAMPLE_FRAC_BITS + dds_pkg::AMP_WIDTH - 1;
    localparam dds_pkg::phase_t CARRIER_FTW = 32'h0000_0800;

    // DUT interface.
    logic               i_clk;
    logic               i_rst;
    logic               i_en;
    dds_pkg::phase_t    i_carr_ftw;
    dds_pkg::phase_t    i_mod_ftw;
    dds_pkg::amp_t      i_mod_depth;
    dds_pkg::mod_type_t i_mod_type;
    dds_pkg::waveform_t i_mod_wave;
    logic               o_mod_valid;
    dds_pkg::phase_t    o_fm_delta;
    dds_pkg::phase_t    o_pm_offset;
    dds_pkg::amp_t      o_am_gain;

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    modulation_engine u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_en(i_en),
        .i_carr_ftw(i_carr_ftw),
        .i_mod_ftw(i_mod_ftw),
        .i_mod_depth(i_mod_depth),
        .i_mod_type(i_mod_type),
        .i_mod_wave(i_mod_wave),
        .o_mod_valid(o_mod_valid),
        .o_fm_delta(o_fm_delta),
        .o_pm_offset(o_pm_offset),
        .o_am_gain(o_am_gain)
    );

    // Independent fixed-point references for the visible modulation controls.
    function automatic longint signed scaled_mod_sample(
        input dds_pkg::int_sample_t sample,
        input dds_pkg::amp_t        depth
    );
        begin
            scaled_mod_sample = longint'(sample) * longint'({1'b0, depth});
        end
    endfunction

    function automatic dds_pkg::phase_t expected_fm_delta(
        input dds_pkg::int_sample_t sample,
        input dds_pkg::amp_t        depth,
        input dds_pkg::phase_t      carr_ftw
    );
        longint signed product;
        begin
            product = scaled_mod_sample(sample, depth) * longint'({1'b0, carr_ftw});
            expected_fm_delta = dds_pkg::phase_t'(product >>> MOD_SCALED_FRAC_BITS);
        end
    endfunction

    function automatic dds_pkg::phase_t expected_pm_offset(
        input dds_pkg::int_sample_t sample,
        input dds_pkg::amp_t        depth
    );
        longint signed product;
        begin
            product = scaled_mod_sample(sample, depth) * longint'({1'b0, dds_pkg::PHASE_HALF_TURN});
            expected_pm_offset = dds_pkg::phase_t'(product >>> MOD_SCALED_FRAC_BITS);
        end
    endfunction

    function automatic dds_pkg::amp_t expected_am_gain(
        input dds_pkg::int_sample_t sample,
        input dds_pkg::amp_t        depth
    );
        int signed wave_depth;
        int signed gain_ext;
        begin
            wave_depth = int'(scaled_mod_sample(sample, depth) >>> MOD_SAMPLE_FRAC_BITS);
            gain_ext   = int'({1'b0, dds_pkg::AMP_ONE - (depth >>> 1)}) + (wave_depth >>> 1);

            if (gain_ext <= 0) begin
                expected_am_gain = '0;
            end
            else if (gain_ext > int'({1'b0, dds_pkg::AMP_ONE})) begin
                expected_am_gain = dds_pkg::AMP_ONE;
            end
            else begin
                expected_am_gain = dds_pkg::amp_t'(gain_ext);
            end
        end
    endfunction

    task automatic check_outputs(
        input string name,
        input logic expected_valid,
        input dds_pkg::phase_t expected_fm,
        input dds_pkg::phase_t expected_pm,
        input dds_pkg::amp_t expected_am
    );
        begin
            if (o_mod_valid !== expected_valid) begin
                error_count++;
                $display("ERROR: %s expected valid=%0b got %0b",
                         name, expected_valid, o_mod_valid);
            end
            if (o_fm_delta !== expected_fm) begin
                error_count++;
                $display("ERROR: %s expected fm_delta=0x%08x got 0x%08x",
                         name, expected_fm, o_fm_delta);
            end
            if (o_pm_offset !== expected_pm) begin
                error_count++;
                $display("ERROR: %s expected pm_offset=0x%08x got 0x%08x",
                         name, expected_pm, o_pm_offset);
            end
            if (o_am_gain !== expected_am) begin
                error_count++;
                $display("ERROR: %s expected am_gain=0x%03x got 0x%03x",
                         name, expected_am, o_am_gain);
            end
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge i_clk);
            i_rst = 1'b1;
            repeat (3) @(posedge i_clk);
            @(negedge i_clk);
            i_rst = 1'b0;
        end
    endtask

    task automatic start_scenario(
        input dds_pkg::mod_type_t mod_type,
        input dds_pkg::waveform_t mod_wave,
        input dds_pkg::phase_t    mod_ftw,
        input dds_pkg::amp_t      mod_depth
    );
        begin
            reset_dut();
            i_en = 1'b1;
            i_carr_ftw = CARRIER_FTW;
            i_mod_ftw = mod_ftw;
            i_mod_depth = mod_depth;
            i_mod_type = mod_type;
            i_mod_wave = mod_wave;
        end
    endtask

    // DC modulation samples make AM/FM/PM scaling deterministic and exact.
    task automatic check_constant_dc_mode(
        input string name,
        input dds_pkg::mod_type_t mod_type,
        input dds_pkg::amp_t      mod_depth
    );
        dds_pkg::phase_t expected_fm;
        dds_pkg::phase_t expected_pm;
        dds_pkg::amp_t   expected_am;
        begin
            start_scenario(mod_type, dds_pkg::WAVE_DC, '0, mod_depth);
            tb_common_pkg::wait_for_valid(error_count, i_clk, o_mod_valid, name, "o_mod_valid", 100);

            expected_fm = (mod_type == dds_pkg::MOD_FM)
                        ? expected_fm_delta(dds_pkg::INT_SAMPLE_MAX, mod_depth, CARRIER_FTW)
                        : '0;
            expected_pm = (mod_type == dds_pkg::MOD_PM)
                        ? expected_pm_offset(dds_pkg::INT_SAMPLE_MAX, mod_depth)
                        : '0;
            expected_am = (mod_type == dds_pkg::MOD_AM)
                        ? expected_am_gain(dds_pkg::INT_SAMPLE_MAX, mod_depth)
                        : dds_pkg::AMP_ONE;

            check_outputs(name, 1'b1, expected_fm, expected_pm, expected_am);
        end
    endtask

    // Disabled modulation must hold neutral controls after reset and drain.
    task automatic check_none_stays_neutral;
        begin
            start_scenario(dds_pkg::MOD_NONE, dds_pkg::WAVE_DC, '0, dds_pkg::AMP_ONE);

            for (int cycle = 0; cycle < dds_pkg::WAVEFORM_LATENCY + 8; cycle++) begin
                tb_tick(i_clk);
                check_outputs("MOD_NONE neutral", 1'b0, '0, '0, dds_pkg::AMP_ONE);
            end
        end
    endtask

    // Alternating square modulation proves that signed FM deltas keep polarity.
    task automatic check_square_fm_polarity;
        dds_pkg::phase_t expected_pos;
        dds_pkg::phase_t expected_neg;
        logic seen_pos;
        logic seen_neg;
        begin
            start_scenario(dds_pkg::MOD_FM, dds_pkg::WAVE_SQUARE, phase_turn(1, 2), dds_pkg::AMP_ONE);
            expected_pos = expected_fm_delta(dds_pkg::INT_SAMPLE_MAX, dds_pkg::AMP_ONE, CARRIER_FTW);
            expected_neg = expected_fm_delta(dds_pkg::INT_SAMPLE_MIN, dds_pkg::AMP_ONE, CARRIER_FTW);
            seen_pos = 1'b0;
            seen_neg = 1'b0;

            for (int cycle = 0; cycle < 40; cycle++) begin
                tb_tick(i_clk);
                if (o_mod_valid) begin
                    if (o_fm_delta === expected_pos) begin
                        seen_pos = 1'b1;
                    end
                    if (o_fm_delta === expected_neg) begin
                        seen_neg = 1'b1;
                    end
                end
            end

            if (!seen_pos) begin
                error_count++;
                $display("ERROR: square FM polarity did not produce positive delta 0x%08x", expected_pos);
            end
            if (!seen_neg) begin
                error_count++;
                $display("ERROR: square FM polarity did not produce negative delta 0x%08x", expected_neg);
            end
        end
    endtask

    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_en = 1'b0;
        i_carr_ftw = '0;
        i_mod_ftw = '0;
        i_mod_depth = '0;
        i_mod_type = dds_pkg::MOD_NONE;
        i_mod_wave = dds_pkg::WAVE_DC;
        error_count = 0;

        `TB_DUMP("sim/out/tb_modulation_engine.vcd", tb_modulation_engine);

        check_none_stays_neutral();
        check_constant_dc_mode("AM DC depth", dds_pkg::MOD_AM, dds_pkg::AMP_ONE);
        check_constant_dc_mode("FM DC depth", dds_pkg::MOD_FM, dds_pkg::AMP_ONE);
        check_constant_dc_mode("PM DC depth", dds_pkg::MOD_PM, dds_pkg::AMP_ONE);
        check_square_fm_polarity();

        finish_on_errors("modulation_engine", error_count);

        $finish;
    end
endmodule

`default_nettype wire
