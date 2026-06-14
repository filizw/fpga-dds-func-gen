`timescale 1ns/1ps
`default_nettype none

// CORDIC functional testbench.
// Checks cardinal sine/cosine phases against full-scale expectations and emits
// one complete sampled waveform period for inspection.
module tb_cordic;
    import tb_common_pkg::*;

    // PHASE_STEP is one-sixteenth of a DDS turn, so the waveform capture covers
    // all quadrants with an integer number of samples.
    localparam int ITERATIONS = dds_pkg::CORDIC_ITER;
    localparam dds_pkg::phase_t PHASE_STEP = phase_turn(1, 16);
    localparam longint PHASE_PERIOD = 64'd1 << dds_pkg::PHASE_WIDTH;
    localparam longint PHASE_STEP_LONG = longint'(PHASE_STEP);
    localparam int WAVEFORM_CYCLES = int'(PHASE_PERIOD / PHASE_STEP_LONG);
    // Expected 45-degree magnitude for the configured fixed-point CORDIC.
    // The value includes the implementation's finite-iteration quantization.
    localparam int SAMPLE_INV_SQRT2 = 1450;

    // DUT interface.
    logic                           i_clk;
    logic                           i_rst;
    logic                           i_phase_valid;
    dds_pkg::phase_t                i_phase;
    logic                           o_sample_valid;
    dds_pkg::int_sample_t           o_sin_sample;
    dds_pkg::int_sample_t           o_cos_sample;

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Keep waveform capture deterministic by using a phase step that exactly
    // divides one DDS turn.
    initial begin
        if (PHASE_STEP == '0) begin
            $fatal(1, "PHASE_STEP must be non-zero");
        end

        if ((PHASE_PERIOD % PHASE_STEP_LONG) != 0) begin
            $fatal(1, "PHASE_STEP must divide one full phase period");
        end
    end

    // CORDIC under test.
    cordic u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_phase_valid(i_phase_valid),
        .i_phase(i_phase),
        .o_sample_valid(o_sample_valid),
        .o_sin_sample(o_sin_sample),
        .o_cos_sample(o_cos_sample)
    );

    // Single-sample tests isolate phase folding, sign restoration, and valid
    // latency for specific DDS phase words.
    // Apply a single phase word and wait for the CORDIC pipeline result.
    task automatic run_sample(
        input dds_pkg::phase_t sample_phase,
        input int expected_sin,
        input int expected_cos,
        input string name
    );
        begin
            @(negedge i_clk);
            i_phase = sample_phase;
            i_phase_valid = 1'b1;
            @(negedge i_clk);
            i_phase_valid = 1'b0;
            i_phase = '0;

            do begin
                tb_tick(i_clk);
            end while (!o_sample_valid);

            check_int_near(error_count, {name, " sine"}, int'(o_sin_sample), expected_sin, 3);
            check_int_near(error_count, {name, " cosine"}, int'(o_cos_sample), expected_cos, 3);
            $display("%s phase=0x%08x sin=%0d cos=%0d", name, sample_phase, o_sin_sample, o_cos_sample);
        end
    endtask

    // After an isolated valid input, the CORDIC valid pipeline must drain cleanly.
    task automatic check_invalid_gap(input int cycles);
        begin
            for (int cycle = 0; cycle < cycles; cycle++) begin
                tb_tick(i_clk);
                check_bit_equal(error_count, $sformatf("invalid gap cycle %0d", cycle),
                                o_sample_valid, 1'b0);
            end
        end
    endtask

    // Continuous phase sweep used for VCD waveform inspection.
    task automatic run_waveform;
        begin
            @(negedge i_clk);
            i_phase = 32'd0;
            i_phase_valid = 1'b1;

            for (int cycle = 0; cycle < WAVEFORM_CYCLES; cycle++) begin
                @(negedge i_clk);
                i_phase = i_phase + PHASE_STEP;
            end

            i_phase_valid = 1'b0;
            repeat (ITERATIONS + 4) @(posedge i_clk);
        end
    endtask

    // Cardinal samples verify quadrant boundaries and sign restoration.
    task automatic run_cardinal_samples;
        begin
            run_sample(phase_turn(0, 1),   0, int'(dds_pkg::INT_SAMPLE_MAX), "0 deg");
            run_sample(phase_turn(1, 4), int'(dds_pkg::INT_SAMPLE_MAX), 0, "90 deg");
            run_sample(phase_turn(1, 2),   0, int'(dds_pkg::INT_SAMPLE_MIN), "180 deg");
            run_sample(phase_turn(3, 4), int'(dds_pkg::INT_SAMPLE_MIN), 0, "270 deg");
        end
    endtask

    // Octant samples exercise nontrivial rotations where sine and cosine are
    // both active and finite-iteration error is visible.
    task automatic run_octant_samples;
        begin
            run_sample(phase_turn(1, 8),  SAMPLE_INV_SQRT2,  SAMPLE_INV_SQRT2, "45 deg");
            run_sample(phase_turn(3, 8),  SAMPLE_INV_SQRT2, -SAMPLE_INV_SQRT2, "135 deg");
            run_sample(phase_turn(5, 8), -SAMPLE_INV_SQRT2, -SAMPLE_INV_SQRT2, "225 deg");
            run_sample(phase_turn(7, 8), -SAMPLE_INV_SQRT2,  SAMPLE_INV_SQRT2, "315 deg");
        end
    endtask

    // Boundary-adjacent phase words catch quadrant-folding off-by-one errors.
    task automatic run_boundary_samples;
        begin
            run_sample(phase_turn(1, 4) - 1'b1, int'(dds_pkg::INT_SAMPLE_MAX), 0, "just below 90 deg");
            run_sample(phase_turn(1, 4) + 1'b1, int'(dds_pkg::INT_SAMPLE_MAX), 0, "just above 90 deg");
            run_sample(phase_turn(1, 2) - 1'b1, 0, int'(dds_pkg::INT_SAMPLE_MIN), "just below 180 deg");
            run_sample(phase_turn(1, 2) + 1'b1, 0, int'(dds_pkg::INT_SAMPLE_MIN), "just above 180 deg");
        end
    endtask

    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_phase_valid = 1'b0;
        i_phase = '0;
        error_count = 0;

        `TB_DUMP("sim/out/tb_cordic.vcd", tb_cordic);

        repeat (3) @(posedge i_clk);
        i_rst = 1'b0;
        run_cardinal_samples();

        check_invalid_gap(ITERATIONS + 3);

        run_octant_samples();

        run_boundary_samples();

        // Capture a short deterministic sweep for waveform-level inspection.
        $display("capturing sine/cosine waveform");
        run_waveform();
        $dumpoff;
        $dumpflush;

        finish_on_errors("CORDIC", error_count);

        $finish;
    end
endmodule

`default_nettype wire
