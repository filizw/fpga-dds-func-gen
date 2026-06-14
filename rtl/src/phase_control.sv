`timescale 1ns/1ps
`default_nettype none

// Carrier phase control.
// Combines the base carrier FTW with FM delta, accumulates carrier phase, then
// applies static carrier phase and PM offset in DDS phase units. The final add
// wraps naturally modulo 2^PHASE_WIDTH.
module phase_control (
    input  logic            i_clk,
    input  logic            i_rst,

    input  logic            i_en,
    input  dds_pkg::phase_t i_carr_ftw,
    input  dds_pkg::phase_t i_carr_phase,
    input  logic            i_mod_valid,
    input  dds_pkg::phase_t i_fm_delta,
    input  dds_pkg::phase_t i_pm_offset,

    output dds_pkg::phase_t o_acc_phase
);

    // Effective carrier tuning word after optional FM.
    dds_pkg::phase_t eff_ftw;
    dds_pkg::phase_t eff_ftw_reg;

    // Static and modulation phase offsets are delayed to match the registered
    // accumulator path before the output phase is presented to waveform logic.
    dds_pkg::phase_t carr_phase_reg;
    logic            mod_valid_pipe_reg [0:1];
    dds_pkg::phase_t pm_offset_pipe_reg [0:1];
    dds_pkg::phase_t acc_phase;

    dds_pkg::phase_t phase_with_carrier_reg;
    dds_pkg::phase_t acc_phase_reg;

    assign o_acc_phase = acc_phase_reg;

    // FM delta is interpreted as a signed phase-step perturbation.
    // clamp_ftw_delta keeps the effective FTW non-negative.
    assign eff_ftw = i_mod_valid ? dds_pkg::clamp_ftw_delta(i_carr_ftw, i_fm_delta) : i_carr_ftw;

    phase_accumulator u_phase_accumulator (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_en(i_en),
        .i_ftw(eff_ftw_reg),
        .o_phase(acc_phase)
    );

    // Output phase pipeline.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            eff_ftw_reg            <= '0;
            carr_phase_reg         <= '0;
            mod_valid_pipe_reg[0]  <= 1'b0;
            mod_valid_pipe_reg[1]  <= 1'b0;
            pm_offset_pipe_reg[0]  <= '0;
            pm_offset_pipe_reg[1]  <= '0;
            phase_with_carrier_reg <= '0;
            acc_phase_reg          <= '0;
        end
        else begin
            eff_ftw_reg           <= eff_ftw;
            carr_phase_reg        <= i_carr_phase;
            mod_valid_pipe_reg[0] <= i_mod_valid;
            pm_offset_pipe_reg[0] <= i_pm_offset;

            if (i_en) begin
                phase_with_carrier_reg <= acc_phase + carr_phase_reg;
                mod_valid_pipe_reg[1]  <= mod_valid_pipe_reg[0];
                pm_offset_pipe_reg[1]  <= mod_valid_pipe_reg[0] ? pm_offset_pipe_reg[0] : '0;
                acc_phase_reg          <= dds_pkg::add_phase_offset(phase_with_carrier_reg,
                                                                     pm_offset_pipe_reg[1]);
            end
        end
    end

endmodule

`default_nettype wire
