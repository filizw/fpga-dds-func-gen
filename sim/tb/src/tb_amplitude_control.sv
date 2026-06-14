`timescale 1ns/1ps
`default_nettype none

// Amplitude-control unit testbench.
// Stresses gain clamping, signed sample extremes, round-to-nearest-even,
// saturation, and the four-cycle valid pipeline.
module tb_amplitude_control;
    import tb_common_pkg::*;

    // Match the RTL reduction points so the reference model checks exact
    // fixed-point rounding and saturation behavior.
    localparam int MULT1_REDUCE_SHIFT   = 6;
    localparam int MULT1_REDUCED_WIDTH  = dds_pkg::AMP_MULT1_WIDTH - MULT1_REDUCE_SHIFT;
    localparam int MULT2_REDUCED_WIDTH  = MULT1_REDUCED_WIDTH + dds_pkg::AMP_WIDTH;
    localparam int OUTPUT_REDUCED_SHIFT = dds_pkg::AMP_OUTPUT_SHIFT - MULT1_REDUCE_SHIFT;

    typedef logic signed [MULT1_REDUCED_WIDTH-1:0] amp_mult1_reduced_t;
    typedef logic signed [MULT2_REDUCED_WIDTH-1:0] amp_mult2_reduced_t;

    // DUT interface.
    logic                 i_clk;
    logic                 i_rst;
    logic                 i_sample_valid;
    dds_pkg::int_sample_t i_sample;
    dds_pkg::amp_t        i_carr_amp;
    dds_pkg::amp_t        i_am_gain;
    logic                 o_sample_valid;
    dds_pkg::sample_t     o_sample;

    // Cycle-accurate reference pipeline.
    // Registers are named after the RTL stages to make latency mismatches easy
    // to diagnose from error reports or VCD traces.
    dds_pkg::amp_t       model_am_gain_reg;
    dds_pkg::amp_t       model_am_gain_mult2_reg;
    dds_pkg::amp_mult1_t model_mult1_reg;
    amp_mult1_reduced_t  model_mult1_reduced_reg;
    amp_mult2_reduced_t  model_mult2_reg;
    amp_mult2_reduced_t  model_rounded_reg;
    logic          [3:0] model_valid_pipe_reg;
    logic                model_sample_valid_reg;
    dds_pkg::sample_t    model_sample_reg;

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Output scaler under test.
    amplitude_control u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_sample_valid(i_sample_valid),
        .i_sample(i_sample),
        .i_carr_amp(i_carr_amp),
        .i_am_gain(i_am_gain),
        .o_sample_valid(o_sample_valid),
        .o_sample(o_sample)
    );

    // Reference round-to-nearest-even for the first product-width reduction.
    // Arithmetic shifts keep the sign of the waveform product.
    function automatic amp_mult1_reduced_t model_round_mult1(
        input dds_pkg::amp_mult1_t value
    );
        dds_pkg::amp_mult1_t value_truncated;
        dds_pkg::amp_mult1_t value_rounded;
        logic round_bit;
        logic sticky_bits;
        logic lsb_after_shift;
        begin
            value_truncated = value >>> MULT1_REDUCE_SHIFT;
            round_bit       = value[MULT1_REDUCE_SHIFT-1];
            sticky_bits     = (MULT1_REDUCE_SHIFT > 1) ? |value[MULT1_REDUCE_SHIFT-2:0] : 1'b0;
            lsb_after_shift = value_truncated[0];
            value_rounded   = value_truncated;

            if (round_bit && (sticky_bits || lsb_after_shift)) begin
                value_rounded = value_truncated + 1;
            end

            model_round_mult1 = amp_mult1_reduced_t'(value_rounded[MULT1_REDUCED_WIDTH-1:0]);
        end
    endfunction

    // Reference round-to-nearest-even after restoring the final output scale.
    function automatic amp_mult2_reduced_t model_round_scaled_sample(
        input amp_mult2_reduced_t value
    );
        amp_mult2_reduced_t value_truncated;
        amp_mult2_reduced_t value_rounded;
        logic round_bit;
        logic sticky_bits;
        logic lsb_after_shift;
        begin
            value_truncated = value >>> OUTPUT_REDUCED_SHIFT;
            round_bit       = value[OUTPUT_REDUCED_SHIFT-1];
            sticky_bits     = (OUTPUT_REDUCED_SHIFT > 1) ? |value[OUTPUT_REDUCED_SHIFT-2:0] : 1'b0;
            lsb_after_shift = value_truncated[0];
            value_rounded   = value_truncated;

            if (round_bit && (sticky_bits || lsb_after_shift)) begin
                value_rounded = value_truncated + 1;
            end

            model_round_scaled_sample = value_rounded;
        end
    endfunction

    // Reference saturation to the signed external sample range.
    // Wrapping here would hide gain or rounding overflow errors.
    function automatic dds_pkg::sample_t model_saturate_sample(
        input amp_mult2_reduced_t value
    );
        localparam amp_mult2_reduced_t SAMPLE_MAX_EXT =
            {{(MULT2_REDUCED_WIDTH-dds_pkg::SAMPLE_WIDTH){dds_pkg::SAMPLE_MAX[dds_pkg::SAMPLE_WIDTH-1]}},
             dds_pkg::SAMPLE_MAX};
        localparam amp_mult2_reduced_t SAMPLE_MIN_EXT =
            {{(MULT2_REDUCED_WIDTH-dds_pkg::SAMPLE_WIDTH){dds_pkg::SAMPLE_MIN[dds_pkg::SAMPLE_WIDTH-1]}},
             dds_pkg::SAMPLE_MIN};
        begin
            if (value > SAMPLE_MAX_EXT) begin
                model_saturate_sample = dds_pkg::SAMPLE_MAX;
            end
            else if (value < SAMPLE_MIN_EXT) begin
                model_saturate_sample = dds_pkg::SAMPLE_MIN;
            end
            else begin
                model_saturate_sample = value[dds_pkg::SAMPLE_WIDTH-1:0];
            end
        end
    endfunction

    // Mirror the RTL multiplier pipeline exactly, including clamped gain inputs
    // and valid delay.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            model_am_gain_reg        <= dds_pkg::AMP_ONE;
            model_am_gain_mult2_reg  <= dds_pkg::AMP_ONE;
            model_mult1_reg          <= '0;
            model_mult1_reduced_reg  <= '0;
            model_mult2_reg          <= '0;
            model_rounded_reg        <= '0;
            model_valid_pipe_reg     <= '0;
            model_sample_valid_reg   <= 1'b0;
            model_sample_reg         <= '0;
        end
        else begin
            model_am_gain_reg       <= dds_pkg::clamp_amp(i_am_gain);
            model_am_gain_mult2_reg <= model_am_gain_reg;

            model_mult1_reg         <= i_sample * $signed({1'b0, dds_pkg::clamp_amp(i_carr_amp)});
            model_mult1_reduced_reg <= model_round_mult1(model_mult1_reg);
            model_mult2_reg         <= model_mult1_reduced_reg * $signed({1'b0, model_am_gain_mult2_reg});
            model_rounded_reg       <= model_round_scaled_sample(model_mult2_reg);

            model_valid_pipe_reg <= {model_valid_pipe_reg[2:0], i_sample_valid};

            model_sample_valid_reg <= model_valid_pipe_reg[3];
            model_sample_reg       <= model_saturate_sample(model_rounded_reg);
        end
    end

    // Check both data and valid every cycle; invalid cycles still check the
    // registered data path because stale arithmetic can reveal pipeline bugs.
    task automatic tick_and_check(input string name);
        begin
            tb_tick(i_clk);
            check_bit_equal(error_count, {name, " valid"}, o_sample_valid, model_sample_valid_reg);
            if (o_sample !== model_sample_reg) begin
                error_count++;
                $display("ERROR: %s expected sample=%0d got %0d",
                         name, model_sample_reg, o_sample);
            end
        end
    endtask

    // Apply stimulus on the inactive edge so registered DUT inputs are stable at
    // the active clock edge.
    task automatic drive_sample(
        input string name,
        input dds_pkg::int_sample_t next_sample,
        input dds_pkg::amp_t        next_carr_amp,
        input dds_pkg::amp_t        next_am_gain,
        input logic                 next_valid
    );
        begin
            @(negedge i_clk);
            i_sample = next_sample;
            i_carr_amp = next_carr_amp;
            i_am_gain = next_am_gain;
            i_sample_valid = next_valid;
            tick_and_check(name);
        end
    endtask

    // Gain extremes cover silence, unity, and over-range values that must be
    // clamped before multiplication.
    task automatic run_gain_extreme_cases;
        begin
            drive_sample("zero carrier gain", dds_pkg::INT_SAMPLE_MAX, '0, dds_pkg::AMP_ONE, 1'b1);
            drive_sample("unity gain positive", dds_pkg::INT_SAMPLE_MAX, dds_pkg::AMP_ONE, dds_pkg::AMP_ONE, 1'b1);
            drive_sample("unity gain negative", dds_pkg::INT_SAMPLE_MIN, dds_pkg::AMP_ONE, dds_pkg::AMP_ONE, 1'b1);
            drive_sample("over-range carrier gain clamps", dds_pkg::INT_SAMPLE_MAX, '1, dds_pkg::AMP_ONE, 1'b1);
            drive_sample("over-range AM gain clamps", dds_pkg::INT_SAMPLE_MAX, dds_pkg::AMP_ONE, '1, 1'b1);
        end
    endtask

    // Fractional gain cases exercise both rounding stages with positive and
    // negative signed samples, then hit final output saturation.
    task automatic run_fractional_and_saturation_cases;
        begin
            drive_sample("half carrier half AM", 12'sd1024, 12'h400, 12'h400, 1'b1);
            drive_sample("rounding positive", 12'sd513, 12'h555, 12'h666, 1'b1);
            drive_sample("rounding negative", -12'sd513, 12'h555, 12'h666, 1'b1);
            drive_sample("invalid bubble", 12'sd777, 12'h800, 12'h800, 1'b0);
            drive_sample("sample max with saturated gains", dds_pkg::INT_SAMPLE_MAX, '1, '1, 1'b1);
            drive_sample("sample min with saturated gains", dds_pkg::INT_SAMPLE_MIN, '1, '1, 1'b1);
        end
    endtask

    // Drain the four-cycle valid pipeline and make sure invalid input bubbles
    // propagate cleanly.
    task automatic drain_valid_pipeline;
        begin
            repeat (8) begin
                drive_sample("pipeline drain", '0, '0, '0, 1'b0);
            end
        end
    endtask

    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_sample_valid = 1'b0;
        i_sample = '0;
        i_carr_amp = '0;
        i_am_gain = '0;
        error_count = 0;

        `TB_DUMP("sim/out/tb_amplitude_control.vcd", tb_amplitude_control);

        repeat (3) tick_and_check("reset");
        i_rst = 1'b0;
        run_gain_extreme_cases();

        run_fractional_and_saturation_cases();

        drain_valid_pipeline();

        finish_on_errors("amplitude_control", error_count);

        $finish;
    end
endmodule

`default_nettype wire
