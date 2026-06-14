`timescale 1ns/1ps
`default_nettype none

// Phase accumulator unit testbench.
// Exercises reset, enable hold, zero FTW, normal accumulation, and intentional
// modulo wraparound at the DDS phase-word boundary.
module tb_phase_accumulator;
    import tb_common_pkg::*;

    // DUT interface.
    logic            i_clk;
    logic            i_rst;
    logic            i_en;
    dds_pkg::phase_t i_ftw;
    dds_pkg::phase_t o_phase;

    int error_count;

    `TB_CLOCK_GEN(i_clk);

    // Accumulator under test.
    phase_accumulator u_dut (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_en(i_en),
        .i_ftw(i_ftw),
        .o_phase(o_phase)
    );

    // Phase checks use exact equality because the accumulator is pure integer
    // modulo arithmetic with no rounding or latency ambiguity.
    initial begin
        i_clk = 1'b0;
    end

    initial begin
        i_rst = 1'b1;
        i_en = 1'b0;
        i_ftw = '0;
        error_count = 0;

        `TB_DUMP("sim/out/tb_phase_accumulator.vcd", tb_phase_accumulator);

        // Reset and disabled-enable cases prove phase state changes only through
        // the enabled accumulation path.
        tb_tick(i_clk);
        check_phase_equal(error_count, "reset clears phase", o_phase, '0);

        i_rst = 1'b0;
        i_ftw = 32'h1234_5678;
        i_en = 1'b0;
        repeat (3) tb_tick(i_clk);
        check_phase_equal(error_count, "disabled accumulator holds phase", o_phase, '0);

        i_en = 1'b1;
        i_ftw = 32'h0000_0000;
        repeat (2) tb_tick(i_clk);
        check_phase_equal(error_count, "zero FTW does not advance phase", o_phase, '0);

        // Smallest nonzero FTW exercises LSB accumulation without wrap.
        i_ftw = 32'h0000_0001;
        tb_tick(i_clk);
        check_phase_equal(error_count, "single-LSB FTW advances by one", o_phase, 32'h0000_0001);
        tb_tick(i_clk);
        check_phase_equal(error_count, "single-LSB FTW accumulates", o_phase, 32'h0000_0002);

        i_rst = 1'b1;
        tb_tick(i_clk);
        i_rst = 1'b0;

        // Large FTWs intentionally overflow the phase word; the wrapped result
        // is the DDS representation of phase modulo one turn.
        i_ftw = 32'hffff_fffe;
        i_en = 1'b1;
        tb_tick(i_clk);
        check_phase_equal(error_count, "large FTW first step", o_phase, 32'hffff_fffe);
        tb_tick(i_clk);
        check_phase_equal(error_count, "large FTW wraps modulo phase width", o_phase, 32'hffff_fffc);

        i_ftw = phase_turn(1, 2);
        tb_tick(i_clk);
        check_phase_equal(error_count, "half-turn FTW wraps through upper half", o_phase, 32'h7fff_fffc);
        tb_tick(i_clk);
        check_phase_equal(error_count, "half-turn FTW returns after two cycles", o_phase, 32'hffff_fffc);

        finish_on_errors("phase_accumulator", error_count);

        $finish;
    end
endmodule

`default_nettype wire
