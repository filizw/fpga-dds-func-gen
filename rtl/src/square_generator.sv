`timescale 1ns/1ps
`default_nettype none

// Square waveform generator.
// Uses the phase MSB as the half-turn discriminator and emits full-scale
// internal samples with no pipeline latency.
module square_generator (
    input  dds_pkg::phase_t      i_phase,

    output dds_pkg::int_sample_t o_sample
);

    // Phase units wrap at 2^PHASE_WIDTH; the MSB changes state every half turn.
    always_comb begin
        o_sample = (i_phase[dds_pkg::PHASE_WIDTH-1] == 1'b0)
                 ? dds_pkg::INT_SAMPLE_MAX
                 : dds_pkg::INT_SAMPLE_MIN;
    end

endmodule

`default_nettype wire
