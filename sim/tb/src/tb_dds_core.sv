`timescale 1ns/1ps
`default_nettype none

// DDS core trace testbench.
// Runs the top-level DDS through unmodulated, AM, FM, and PM modes and writes a
// CSV trace for numerical inspection. FTWs are chosen to produce integer periods.
module tb_dds_core;
    import tb_common_pkg::*;

    // Local aliases keep trace configuration tied to the package numeric
    // contract without hard-coding widths in checks.
    localparam int PHASE_WIDTH  = dds_pkg::PHASE_WIDTH;
    localparam int SAMPLE_WIDTH = dds_pkg::SAMPLE_WIDTH;
    localparam int AMP_WIDTH    = dds_pkg::AMP_WIDTH;

    // User-facing trace controls.
    // These frequencies intentionally reproduce the original integer-period
    // FTWs: carrier period is 64 clocks and modulation period is 1024 clocks.
    localparam real CARRIER_FREQ_HZ = CLK_HZ / 64.0;
    localparam real MOD_FREQ_HZ     = CLK_HZ / 1024.0;
    localparam real CARRIER_GAIN    = 1.0;
    localparam real AM_TRACE_DEPTH  = 0.5;
    localparam real FM_TRACE_DEPTH  = 1.0;
    localparam real PM_TRACE_DEPTH  = 1.0;

    localparam logic [PHASE_WIDTH-1:0] CARRIER_FTW = ftw_from_hz(CARRIER_FREQ_HZ, CLK_HZ);
    localparam logic [PHASE_WIDTH-1:0] MOD_FTW = ftw_from_hz(MOD_FREQ_HZ, CLK_HZ);
    localparam logic [AMP_WIDTH-1:0] CARRIER_AMP = amp_from_real(CARRIER_GAIN);
    localparam logic [AMP_WIDTH-1:0] AM_DEPTH = amp_from_real(AM_TRACE_DEPTH);
    localparam logic [AMP_WIDTH-1:0] FM_DEPTH = amp_from_real(FM_TRACE_DEPTH);
    localparam logic [AMP_WIDTH-1:0] PM_DEPTH = amp_from_real(PM_TRACE_DEPTH);
    localparam longint PHASE_PERIOD = 64'd1 << PHASE_WIDTH;
    localparam longint CARRIER_FTW_LONG = longint'(CARRIER_FTW);
    localparam longint MOD_FTW_LONG = longint'(MOD_FTW);
    localparam int CARRIER_PERIOD_CYCLES = int'(PHASE_PERIOD / CARRIER_FTW_LONG);
    localparam int MOD_PERIOD_CYCLES = int'(PHASE_PERIOD / MOD_FTW_LONG);
    localparam int TRACE_CYCLES = 2*MOD_PERIOD_CYCLES;
    localparam int CHECK_VALID_SAMPLES = 8;

    // Allow already-issued samples to leave the modulation, waveform, and
    // amplitude pipelines before expecting silence after disable/reset.
    localparam int PIPELINE_DRAIN_CYCLES = dds_pkg::WAVEFORM_LATENCY + 8;

    // DUT interface.
    logic i_clk;
    logic i_rst;
    dds_pkg::dds_config_t i_cfg;
    logic o_sample_valid;
    logic signed [SAMPLE_WIDTH-1:0] o_sample;

    int csv_fd;
    int trace_cycle;
    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Integer-period FTWs keep mode captures phase-repeatable and easier to
    // compare across waveform viewers or post-processing scripts.
    initial begin
        if (CARRIER_FTW == '0) begin
            $fatal(1, "CARRIER_FTW must be non-zero");
        end

        if ((PHASE_PERIOD % CARRIER_FTW_LONG) != 0) begin
            $fatal(1, "CARRIER_FTW must divide one full phase period");
        end

        if (MOD_FTW == '0) begin
            $fatal(1, "MOD_FTW must be non-zero");
        end

        if ((PHASE_PERIOD % MOD_FTW_LONG) != 0) begin
            $fatal(1, "MOD_FTW must divide one full phase period");
        end
    end

    // Top-level DDS under test.
    dds_core u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_cfg(i_cfg),
        .o_sample_valid(o_sample_valid),
        .o_sample(o_sample)
    );

    initial begin
        i_clk = 1'b0;
    end

    // Baseline configuration: enabled sine carrier at unity gain with modulation
    // disabled until each capture mode is selected.
    task automatic setup_cfg;
        begin
            i_cfg            = dds_pkg::default_config();
            i_cfg.rst        = 1'b1;
            i_cfg.carr_ftw   = CARRIER_FTW;
            i_cfg.carr_phase = 32'd0;
            i_cfg.carr_amp   = CARRIER_AMP;
            i_cfg.mod_ftw    = MOD_FTW;

            repeat (3) @(posedge i_clk);
            i_cfg.rst = 1'b0;
            i_cfg.en  = 1'b1;
        end
    endtask

    // Mode changes are applied on the inactive clock edge to avoid racing the
    // DUT's registered configuration sampling.
    task automatic apply_mode(
        input dds_pkg::mod_type_t mod_type,
        input logic [AMP_WIDTH-1:0] mod_depth
    );
        begin
            @(negedge i_clk);
            i_cfg.mod_type  = mod_type;
            i_cfg.mod_depth = mod_depth;
        end
    endtask

    // Disable and reset are synchronous pipeline events. The helper first lets
    // outstanding samples drain, then checks that no new valid samples appear.
    task automatic expect_no_valid(
        input string name,
        input int cycles
    );
        begin
            for (int drain_cycle = 0; drain_cycle < PIPELINE_DRAIN_CYCLES; drain_cycle++) begin
                tb_tick(i_clk);
            end

            for (int cycle = 0; cycle < cycles; cycle++) begin
                tb_tick(i_clk);
                check_bit_equal(error_count, $sformatf("%s cycle %0d", name, cycle),
                                o_sample_valid, 1'b0);
            end
        end
    endtask

    // Capture a fixed number of cycles for one modulation mode.
    task automatic capture_mode(
        input string name,
        input dds_pkg::mod_type_t mod_type,
        input logic [AMP_WIDTH-1:0] mod_depth
    );
        begin
            apply_mode(mod_type, mod_depth);

            for (int cycle = 0; cycle < TRACE_CYCLES; cycle++) begin
                tb_tick(i_clk);
                $fwrite(csv_fd, "%0d,%s,%0d,%0d,%0d,%0d,%0d\n",
                        trace_cycle,
                        name,
                        cycle,
                        i_cfg.mod_type,
                        i_cfg.mod_depth,
                        o_sample_valid,
                        o_sample);
                trace_cycle++;
            end
        end
    endtask

    // Nominal captures for each modulation path.
    // These are the waveform-oriented runs and intentionally preserve the
    // original mode order and depth values.
    task automatic capture_nominal_modes;
        begin
            capture_mode("none", dds_pkg::MOD_NONE, '0);
            capture_mode("am",   dds_pkg::MOD_AM,   AM_DEPTH);
            capture_mode("fm",   dds_pkg::MOD_FM,   FM_DEPTH);
            capture_mode("pm",   dds_pkg::MOD_PM,   PM_DEPTH);
        end
    endtask

    // Static DC configuration for deterministic value checks.
    // Zero FTWs remove phase motion so the expected output is set only by gain
    // scaling and AM depth.
    task automatic apply_static_dc_config(
        input dds_pkg::amp_t      carr_amp,
        input dds_pkg::mod_type_t mod_type,
        input dds_pkg::amp_t      mod_depth
    );
        begin
            @(negedge i_clk);
            i_cfg.en         = 1'b0;
            i_cfg.rst        = 1'b1;
            i_cfg.carr_ftw   = '0;
            i_cfg.carr_phase = '0;
            i_cfg.carr_amp   = carr_amp;
            i_cfg.carr_wave  = dds_pkg::WAVE_DC;
            i_cfg.mod_ftw    = '0;
            i_cfg.mod_depth  = mod_depth;
            i_cfg.mod_type   = mod_type;
            i_cfg.mod_wave   = dds_pkg::WAVE_DC;

            repeat (3) @(posedge i_clk);

            @(negedge i_clk);
            i_cfg.rst = 1'b0;
            i_cfg.en  = 1'b1;
        end
    endtask

    // Check a fixed number of valid output samples against an exact value.
    // This is stronger than a range check because it verifies the top-level
    // gain, clamp, and pipeline behavior for a deterministic waveform.
    task automatic expect_valid_samples_equal(
        input string name,
        input dds_pkg::sample_t expected
    );
        int seen;
        int wait_cycles;
        begin
            seen = 0;
            wait_cycles = 0;

            while (seen < CHECK_VALID_SAMPLES) begin
                tb_tick(i_clk);
                wait_cycles++;

                if (o_sample_valid) begin
                    if (o_sample !== expected) begin
                        error_count++;
                        $display("ERROR: %s expected sample=%0d got %0d",
                                 name, expected, o_sample);
                    end
                    seen++;
                end

                if (wait_cycles > 300) begin
                    error_count++;
                    $display("ERROR: %s timed out after %0d valid samples", name, seen);
                    return;
                end
            end
        end
    endtask

    // Deterministic value checks for gain clamping and zero-gain silence.
    // Zero-FTW DC cases are assertion-oriented and do not define the nominal
    // waveform trace shape.
    task automatic run_static_value_checks;
        begin
            apply_static_dc_config('0, dds_pkg::MOD_NONE, '0);
            expect_valid_samples_equal("zero carrier gain", '0);

            apply_static_dc_config(dds_pkg::AMP_ONE, dds_pkg::MOD_NONE, '0);
            expect_valid_samples_equal("unity carrier gain", dds_pkg::SAMPLE_MAX);

            apply_static_dc_config('1, dds_pkg::MOD_NONE, '0);
            expect_valid_samples_equal("over-range carrier gain clamps", dds_pkg::SAMPLE_MAX);

            apply_static_dc_config(dds_pkg::AMP_ONE, dds_pkg::MOD_AM, dds_pkg::AMP_ONE);
            expect_valid_samples_equal("unity AM depth", dds_pkg::SAMPLE_MAX);

            apply_static_dc_config(dds_pkg::AMP_ONE, dds_pkg::MOD_AM, '1);
            expect_valid_samples_equal("over-range AM depth clamps", dds_pkg::SAMPLE_MAX);
        end
    endtask

    initial begin
        i_rst = 1'b1;
        i_cfg = '0;
        trace_cycle = 0;
        error_count = 0;

        `TB_DUMP("sim/out/tb_dds_core.vcd", tb_dds_core);

        // CSV trace is retained for quick plotting of mode behavior, while the
        // self-checking assertions make the bench useful in automated runs.
        csv_fd = $fopen("sim/out/tb_dds_core_trace.csv", "w");
        if (csv_fd == 0) begin
            $fatal(1, "failed to open sim/out/tb_dds_core_trace.csv");
        end

        $fwrite(csv_fd, "trace_cycle,mode,mode_cycle,mod_type,mod_depth,o_sample_valid,o_sample\n");

        repeat (5) @(posedge i_clk);
        i_rst = 1'b0;
        setup_cfg();
        tb_common_pkg::wait_for_valid(error_count, i_clk, o_sample_valid,
                                      "DDS core", "o_sample_valid", 200);

        capture_nominal_modes();

        run_static_value_checks();

        // Disable and configuration reset are checked after pipeline drain, not
        // immediately at the control edge.
        @(negedge i_clk);
        i_cfg.en = 1'b0;
        expect_no_valid("disabled core after pipeline drain", PIPELINE_DRAIN_CYCLES);

        @(negedge i_clk);
        i_cfg.en = 1'b1;
        tb_common_pkg::wait_for_valid(error_count, i_clk, o_sample_valid,
                                      "DDS core", "o_sample_valid", 200);

        @(negedge i_clk);
        i_cfg.rst = 1'b1;
        expect_no_valid("configuration reset", 4);
        @(negedge i_clk);
        i_cfg.rst = 1'b0;
        i_cfg.en = 1'b1;
        tb_common_pkg::wait_for_valid(error_count, i_clk, o_sample_valid,
                                      "DDS core", "o_sample_valid", 200);

        $fclose(csv_fd);

        finish_on_errors("DDS core", error_count);

        $finish;
    end
endmodule

`default_nettype wire
