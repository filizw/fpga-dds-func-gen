`timescale 1ns/1ps
`default_nettype none

// Waveform-generator unit testbench.
// Verifies that DC, square, triangle, and sine selections are aligned to the
// common CORDIC latency when the waveform selection changes while streaming.
module tb_waveform_generator;
    import tb_common_pkg::*;

    // The module registers the CORDIC result once after waveform selection, so
    // externally observed latency is one cycle beyond WAVEFORM_LATENCY.
    localparam int OUTPUT_LATENCY = dds_pkg::WAVEFORM_LATENCY + 1;
    localparam int LATENCY = OUTPUT_LATENCY;
    localparam int PIPE_DEPTH = LATENCY + 1;
    localparam int SAMPLE_INV_SQRT2 = 1450;

    // DUT interface.
    logic                 i_clk;
    logic                 i_rst;
    logic                 i_phase_valid;
    dds_pkg::phase_t      i_phase;
    dds_pkg::waveform_t   i_waveform;
    logic                 o_sample_valid;
    dds_pkg::int_sample_t o_sample;

    // Expected-output delay line.
    // It tracks the phase, waveform selection, and tolerance that should emerge
    // from the mixed CORDIC/combinational datapath on each valid cycle.
    logic                 expected_valid_pipe [0:PIPE_DEPTH-1];
    dds_pkg::int_sample_t expected_sample_pipe [0:PIPE_DEPTH-1];
    int                   expected_tol_pipe [0:PIPE_DEPTH-1];

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Waveform selector under test.
    waveform_generator u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_phase_valid(i_phase_valid),
        .i_phase(i_phase),
        .i_waveform(i_waveform),
        .o_sample_valid(o_sample_valid),
        .o_sample(o_sample)
    );

    // Select the expected primitive sample before latency alignment.
    function automatic dds_pkg::int_sample_t expected_waveform_sample(
        input dds_pkg::phase_t    sample_phase,
        input dds_pkg::waveform_t sample_waveform
    );
        begin
            unique case (sample_waveform)
                dds_pkg::WAVE_DC:       expected_waveform_sample = dds_pkg::INT_SAMPLE_MAX;
                dds_pkg::WAVE_SINE:     expected_waveform_sample = expected_sine_octant(sample_phase,
                                                                                         SAMPLE_INV_SQRT2);
                dds_pkg::WAVE_SQUARE:   expected_waveform_sample = expected_square(sample_phase);
                dds_pkg::WAVE_TRIANGLE: expected_waveform_sample = expected_triangle(sample_phase);
                default:                expected_waveform_sample = '0;
            endcase
        end
    endfunction

    // Sine permits a small CORDIC tolerance; combinational waveforms are exact.
    function automatic int expected_waveform_tolerance(input dds_pkg::waveform_t sample_waveform);
        begin
            expected_waveform_tolerance = (sample_waveform == dds_pkg::WAVE_SINE) ? 3 : 0;
        end
    endfunction

    // Push the newly requested output into the expected latency queue.
    task automatic push_expected;
        input logic                 next_valid;
        input dds_pkg::phase_t      next_phase;
        input dds_pkg::waveform_t   next_waveform;
        begin
            for (int idx = PIPE_DEPTH-1; idx > 0; idx--) begin
                expected_valid_pipe[idx]  = expected_valid_pipe[idx-1];
                expected_sample_pipe[idx] = expected_sample_pipe[idx-1];
                expected_tol_pipe[idx]    = expected_tol_pipe[idx-1];
            end

            expected_valid_pipe[0]  = next_valid;
            expected_sample_pipe[0] = next_valid ? expected_waveform_sample(next_phase, next_waveform) : '0;
            expected_tol_pipe[0]    = expected_waveform_tolerance(next_waveform);
        end
    endtask

    // Compare valid and sample together to catch waveform-selection skew.
    task automatic tick_and_check(input string name);
        int error;
        begin
            tb_tick(i_clk);
            check_bit_equal(error_count, {name, " valid"},
                            o_sample_valid, expected_valid_pipe[LATENCY]);

            error = int'(o_sample) - int'(expected_sample_pipe[LATENCY]);
            if ((error > expected_tol_pipe[LATENCY]) || (error < -expected_tol_pipe[LATENCY])) begin
                error_count++;
                $display("ERROR: %s expected o_sample=%0d +/- %0d got %0d",
                         name, expected_sample_pipe[LATENCY], expected_tol_pipe[LATENCY], o_sample);
            end
        end
    endtask

    // Apply phase and waveform updates before the active edge.
    task automatic drive_phase(
        input string name,
        input logic                 next_valid,
        input dds_pkg::phase_t      next_phase,
        input dds_pkg::waveform_t   next_waveform
    );
        begin
            @(negedge i_clk);
            i_phase_valid = next_valid;
            i_phase = next_phase;
            i_waveform = next_waveform;
            push_expected(next_valid, next_phase, next_waveform);
            tick_and_check(name);
        end
    endtask

    // Change waveform type every valid cycle. This stresses alignment of the
    // delayed square/triangle/control paths against the registered sine path.
    task automatic run_waveform_selection_sequence;
        begin
            drive_phase("DC zero phase",       1'b1, phase_turn(0, 1), dds_pkg::WAVE_DC);
            drive_phase("square first half",   1'b1, phase_turn(0, 1), dds_pkg::WAVE_SQUARE);
            drive_phase("square second half",  1'b1, phase_turn(1, 2), dds_pkg::WAVE_SQUARE);
            drive_phase("triangle start",      1'b1, phase_turn(0, 1), dds_pkg::WAVE_TRIANGLE);
            drive_phase("triangle quarter",    1'b1, phase_turn(1, 4), dds_pkg::WAVE_TRIANGLE);
            drive_phase("sine zero",           1'b1, phase_turn(0, 1), dds_pkg::WAVE_SINE);
            drive_phase("sine octant",         1'b1, phase_turn(1, 8), dds_pkg::WAVE_SINE);
            drive_phase("sine quarter",        1'b1, phase_turn(1, 4), dds_pkg::WAVE_SINE);
            drive_phase("invalid bubble",      1'b0, phase_turn(1, 2), dds_pkg::WAVE_DC);
            drive_phase("sine third octant",   1'b1, phase_turn(3, 8), dds_pkg::WAVE_SINE);
            drive_phase("sine third quarter",  1'b1, phase_turn(3, 4), dds_pkg::WAVE_SINE);
            drive_phase("DC after bubble",     1'b1, 32'h1234_5678, dds_pkg::WAVE_DC);
        end
    endtask

    // Invalid inputs must drain without creating extra valid samples.
    task automatic drain_pipeline;
        begin
            repeat (LATENCY + 4) begin
                drive_phase("pipeline drain", 1'b0, '0, dds_pkg::WAVE_DC);
            end
        end
    endtask

    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_phase_valid = 1'b0;
        i_phase = '0;
        i_waveform = dds_pkg::WAVE_DC;
        error_count = 0;

        for (int idx = 0; idx < PIPE_DEPTH; idx++) begin
            expected_valid_pipe[idx] = 1'b0;
            expected_sample_pipe[idx] = '0;
            expected_tol_pipe[idx] = 0;
        end

        `TB_DUMP("sim/out/tb_waveform_generator.vcd", tb_waveform_generator);

        // Initialize the expected queue to match reset-cleared DUT outputs.
        repeat (3) begin
            tb_tick(i_clk);
        end

        i_rst = 1'b0;

        run_waveform_selection_sequence();

        drain_pipeline();

        finish_on_errors("waveform_generator", error_count);

        $finish;
    end
endmodule

`default_nettype wire
