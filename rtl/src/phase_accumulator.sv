`timescale 1ns/1ps
`default_nettype none

// DDS phase accumulator.
// Adds one frequency tuning word (FTW) per enabled clock. Overflow is
// intentional and implements modulo-2^PHASE_WIDTH phase arithmetic.
module phase_accumulator (
    input  logic            i_clk,
    input  logic            i_rst,

    input  logic            i_en,
    input  dds_pkg::phase_t i_ftw,

    output dds_pkg::phase_t o_phase
);

    // Phase word in full-turn DDS units.
    dds_pkg::phase_t phase_reg;

    assign o_phase = phase_reg;

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            phase_reg <= '0;
        end
        else if (i_en) begin
            phase_reg <= phase_reg + i_ftw;
        end
    end

endmodule

`default_nettype wire
