`timescale 1ns/1ps
`default_nettype none

// Phase-control unit testbench.
// Uses an explicit reference pipeline to verify FM clamping, static carrier
// phase, PM offset wrapping, enable holds, and reset behavior.
module tb_phase_control;
    import tb_common_pkg::*;

    // DUT interface.
    logic            i_clk;
    logic            i_rst;
    logic            i_en;
    dds_pkg::phase_t i_carr_ftw;
    dds_pkg::phase_t i_carr_phase;
    logic            i_mod_valid;
    dds_pkg::phase_t i_fm_delta;
    dds_pkg::phase_t i_pm_offset;
    dds_pkg::phase_t o_acc_phase;

    // Cycle-accurate reference state.
    // The model mirrors the RTL pipeline so FM clamp, static phase, and PM wrap
    // are checked after the same registered delays seen by waveform generation.
    dds_pkg::phase_t model_eff_ftw_reg;
    dds_pkg::phase_t model_carr_phase_reg;
    logic            model_mod_valid_pipe_reg [0:1];
    dds_pkg::phase_t model_pm_offset_pipe_reg [0:1];
    dds_pkg::phase_t model_phase_acc;
    dds_pkg::phase_t model_phase_with_carrier_reg;
    dds_pkg::phase_t model_acc_phase_reg;

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Phase-control block under test.
    phase_control u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_en(i_en),
        .i_carr_ftw(i_carr_ftw),
        .i_carr_phase(i_carr_phase),
        .i_mod_valid(i_mod_valid),
        .i_fm_delta(i_fm_delta),
        .i_pm_offset(i_pm_offset),
        .o_acc_phase(o_acc_phase)
    );

    // FM delta is signed in a phase_t container; this helper applies the same
    // non-negative FTW clamp used by the design.
    function automatic dds_pkg::phase_t expected_eff_ftw;
        input dds_pkg::phase_t base;
        input logic            valid;
        input dds_pkg::phase_t delta;
        begin
            expected_eff_ftw = valid ? dds_pkg::clamp_ftw_delta(base, delta) : base;
        end
    endfunction

    // Reference output pipeline.
    // Phase accumulation wraps naturally through phase_t width truncation, while
    // add_phase_offset preserves signed PM offset semantics.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            model_eff_ftw_reg            <= '0;
            model_carr_phase_reg         <= '0;
            model_mod_valid_pipe_reg[0]  <= 1'b0;
            model_mod_valid_pipe_reg[1]  <= 1'b0;
            model_pm_offset_pipe_reg[0]  <= '0;
            model_pm_offset_pipe_reg[1]  <= '0;
            model_phase_acc              <= '0;
            model_phase_with_carrier_reg <= '0;
            model_acc_phase_reg          <= '0;
        end
        else begin
            model_eff_ftw_reg           <= expected_eff_ftw(i_carr_ftw, i_mod_valid, i_fm_delta);
            model_carr_phase_reg        <= i_carr_phase;
            model_mod_valid_pipe_reg[0] <= i_mod_valid;
            model_pm_offset_pipe_reg[0] <= i_pm_offset;

            if (i_en) begin
                model_phase_acc              <= model_phase_acc + model_eff_ftw_reg;
                model_phase_with_carrier_reg <= model_phase_acc + model_carr_phase_reg;
                model_mod_valid_pipe_reg[1]  <= model_mod_valid_pipe_reg[0];
                model_pm_offset_pipe_reg[1]  <= model_mod_valid_pipe_reg[0] ? model_pm_offset_pipe_reg[0] : '0;
                model_acc_phase_reg          <= dds_pkg::add_phase_offset(model_phase_with_carrier_reg,
                                                                           model_pm_offset_pipe_reg[1]);
            end
        end
    end

    // Compare after the clock edge so DUT and model nonblocking assignments have
    // both updated.
    task automatic tick_and_check(input string name);
        begin
            tb_tick(i_clk);
            check_phase_equal(error_count, name, o_acc_phase, model_acc_phase_reg);
        end
    endtask

    // Run a scenario long enough for the phase-control pipeline to fill.
    task automatic run_cycles(input string name, input int cycles);
        begin
            for (int cycle = 0; cycle < cycles; cycle++) begin
                tick_and_check(name);
            end
        end
    endtask

    task automatic apply_controls_and_run(
        input string name,
        input int cycles,
        input logic next_en,
        input dds_pkg::phase_t next_carr_ftw,
        input dds_pkg::phase_t next_fm_delta,
        input dds_pkg::phase_t next_pm_offset
    );
        begin
            i_en = next_en;
            i_carr_ftw = next_carr_ftw;
            i_fm_delta = next_fm_delta;
            i_pm_offset = next_pm_offset;
            run_cycles(name, cycles);
        end
    endtask

    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_en = 1'b0;
        i_carr_ftw = '0;
        i_carr_phase = '0;
        i_mod_valid = 1'b0;
        i_fm_delta = '0;
        i_pm_offset = '0;
        error_count = 0;

        `TB_DUMP("sim/out/tb_phase_control.vcd", tb_phase_control);

        // Baseline phase accumulation with a static quarter-turn carrier offset.
        run_cycles("reset", 3);

        i_rst = 1'b0;
        i_en = 1'b1;
        i_carr_ftw = 32'h0000_0004;
        i_carr_phase = phase_turn(1, 4);
        run_cycles("base FTW with static phase", 8);

        i_mod_valid = 1'b1;
        apply_controls_and_run("positive FM and PM", 8,
                               1'b1, i_carr_ftw, 32'h0000_0002, 32'h0000_0010);

        // Negative FM is represented as a two's-complement delta and clamps the
        // effective FTW at zero instead of wrapping to a large positive value.
        apply_controls_and_run("negative FM clamp and negative PM wrap", 8,
                               1'b1, i_carr_ftw, 32'hffff_fff0, 32'hffff_fff8);

        apply_controls_and_run("positive FM clamp at max FTW", 8,
                               1'b1, 32'hffff_fff0, 32'h0000_0100, 32'h7fff_ffff);

        // Disable holds accumulator-dependent state while input controls change.
        apply_controls_and_run("disabled phase hold", 5,
                               1'b0, 32'h0000_1000, 32'h0000_1000, 32'h0000_1000);

        i_rst = 1'b1;
        run_cycles("reset clears pipeline", 2);

        finish_on_errors("phase_control", error_count);

        $finish;
    end
endmodule

`default_nettype wire
