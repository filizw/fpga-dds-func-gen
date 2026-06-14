`timescale 1ns/1ps
`ifndef TB_COMMON_PKG_SV
`define TB_COMMON_PKG_SV

`define TB_CLOCK_GEN(clk) always #CLK_HALF_PERIOD_NS clk = ~clk
`define TB_DUMP(file, scope) \
    $dumpfile(file); \
    $dumpvars(1, scope)

// Shared testbench helpers.
// Keeps common timing, scalar checks, and small reference helpers in one place
// while leaving each bench's DUT-specific model local.
package tb_common_pkg;

    localparam int CLK_HALF_PERIOD_NS = 5;
    localparam real CLK_HZ = 1.0e9 / real'(2*CLK_HALF_PERIOD_NS);

    // Return a DDS phase word for numerator/denominator turns.
    // The package currently uses 32-bit phase words, so 64-bit intermediate math
    // is enough for exact cardinal and octant constants.
    function automatic dds_pkg::phase_t phase_turn(
        input int unsigned numerator,
        input int unsigned denominator
    );
        longint unsigned period;
        begin
            period = 64'd1 << dds_pkg::PHASE_WIDTH;
            phase_turn = dds_pkg::phase_t'((period * longint'(numerator)) / longint'(denominator));
        end
    endfunction

    // Convert a real output frequency to a DDS frequency tuning word.
    // This lets tests describe stimulus in user units while preserving the
    // package's unsigned modulo phase representation.
    function automatic dds_pkg::phase_t ftw_from_hz(
        input real frequency_hz,
        input real clk_hz
    );
        real phase_period;
        real scaled_ftw;
        begin
            phase_period = real'(64'd1 << dds_pkg::PHASE_WIDTH);
            scaled_ftw   = (frequency_hz / clk_hz) * phase_period;

            if (scaled_ftw <= 0.0) begin
                ftw_from_hz = '0;
            end
            else if (scaled_ftw >= phase_period - 1.0) begin
                ftw_from_hz = '1;
            end
            else begin
                ftw_from_hz = dds_pkg::phase_t'($rtoi(scaled_ftw + 0.5));
            end
        end
    endfunction

    // Convert a real gain in the range [0.0, 1.0] to unsigned Q1.(AMP_WIDTH-1).
    // Out-of-range values are clamped to match the RTL control convention.
    function automatic dds_pkg::amp_t amp_from_real(input real gain);
        real scaled_gain;
        begin
            if (gain <= 0.0) begin
                amp_from_real = '0;
            end
            else if (gain >= 1.0) begin
                amp_from_real = dds_pkg::AMP_ONE;
            end
            else begin
                scaled_gain = gain * real'(dds_pkg::AMP_ONE);
                amp_from_real = dds_pkg::amp_t'($rtoi(scaled_gain + 0.5));
            end
        end
    endfunction

    function automatic dds_pkg::int_sample_t expected_square(input dds_pkg::phase_t sample_phase);
        begin
            expected_square = (sample_phase[dds_pkg::PHASE_WIDTH-1] == 1'b0)
                            ? dds_pkg::INT_SAMPLE_MAX
                            : dds_pkg::INT_SAMPLE_MIN;
        end
    endfunction

    function automatic dds_pkg::int_sample_t expected_triangle(input dds_pkg::phase_t sample_phase);
        typedef logic      [dds_pkg::INT_SAMPLE_WIDTH-1:0] sample_bits_t;
        typedef logic signed [dds_pkg::INT_SAMPLE_WIDTH:0] sample_ext_t;

        sample_bits_t delta;
        sample_ext_t  sample_ext;
        begin
            delta = sample_phase[dds_pkg::PHASE_WIDTH-2 -: dds_pkg::INT_SAMPLE_WIDTH];

            if (sample_phase[dds_pkg::PHASE_WIDTH-1] == 1'b0) begin
                sample_ext = $signed({dds_pkg::INT_SAMPLE_MAX[dds_pkg::INT_SAMPLE_WIDTH-1], dds_pkg::INT_SAMPLE_MAX})
                           - $signed({1'b0, delta});
            end
            else begin
                sample_ext = $signed({dds_pkg::INT_SAMPLE_MIN[dds_pkg::INT_SAMPLE_WIDTH-1], dds_pkg::INT_SAMPLE_MIN})
                           + $signed({1'b0, delta});
            end

            expected_triangle = sample_ext[dds_pkg::INT_SAMPLE_WIDTH-1:0];
        end
    endfunction

    function automatic dds_pkg::int_sample_t expected_sine_octant(
        input dds_pkg::phase_t sample_phase,
        input int inv_sqrt2_sample
    );
        begin
            unique case (sample_phase)
                phase_turn(0, 1): expected_sine_octant = '0;
                phase_turn(1, 8): expected_sine_octant = dds_pkg::int_sample_t'(inv_sqrt2_sample);
                phase_turn(1, 4): expected_sine_octant = dds_pkg::INT_SAMPLE_MAX;
                phase_turn(3, 8): expected_sine_octant = dds_pkg::int_sample_t'(inv_sqrt2_sample);
                phase_turn(1, 2): expected_sine_octant = '0;
                phase_turn(5, 8): expected_sine_octant = dds_pkg::int_sample_t'(-inv_sqrt2_sample);
                phase_turn(3, 4): expected_sine_octant = dds_pkg::INT_SAMPLE_MIN;
                phase_turn(7, 8): expected_sine_octant = dds_pkg::int_sample_t'(-inv_sqrt2_sample);
                default:          expected_sine_octant = '0;
            endcase
        end
    endfunction

    task automatic tb_tick(ref logic clk);
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check_bit_equal(
        ref int error_count,
        input string name,
        input logic actual,
        input logic expected
    );
        begin
            if (actual !== expected) begin
                error_count++;
                $display("ERROR: %s expected %0b got %0b", name, expected, actual);
            end
        end
    endtask

    task automatic check_phase_equal(
        ref int error_count,
        input string name,
        input dds_pkg::phase_t actual,
        input dds_pkg::phase_t expected
    );
        begin
            if (actual !== expected) begin
                error_count++;
                $display("ERROR: %s expected 0x%08x got 0x%08x", name, expected, actual);
            end
        end
    endtask

    task automatic check_int_near(
        ref int error_count,
        input string name,
        input int actual,
        input int expected,
        input int tolerance
    );
        int error;
        begin
            error = actual - expected;

            if ((error > tolerance) || (error < -tolerance)) begin
                error_count++;
                $display("ERROR: %s expected %0d +/- %0d got %0d",
                         name, expected, tolerance, actual);
            end
        end
    endtask

    task automatic check_int_equal(
        ref int error_count,
        input string name,
        input int actual,
        input int expected
    );
        begin
            if (actual != expected) begin
                error_count++;
                $display("ERROR: %s expected %0d got %0d", name, expected, actual);
            end
        end
    endtask

    task automatic wait_for_valid(
        ref int error_count,
        ref logic clk,
        ref logic valid,
        input string name,
        input string signal_name,
        input int timeout_cycles
    );
        int wait_cycles;
        begin
            wait_cycles = 0;

            do begin
                tb_tick(clk);
                wait_cycles++;

                if (wait_cycles > timeout_cycles) begin
                    error_count++;
                    $display("ERROR: %s timed out waiting for %s", name, signal_name);
                    return;
                end
            end while (!valid);
        end
    endtask

    task automatic finish_on_errors(
        input string test_name,
        input int error_count
    );
        begin
            if (error_count != 0) begin
                $fatal(1, "%s test failed with %0d errors", test_name, error_count);
            end
        end
    endtask

endpackage

`endif
