`timescale 1ns/1ps
`default_nettype none

// Triangle waveform generator.
// Maps the upper phase bits into a full-scale signed ramp. The phase MSB selects
// the falling or rising half-cycle; the next bits provide the ramp magnitude.
module triangle_generator (
    input  dds_pkg::phase_t      i_phase,

    output dds_pkg::int_sample_t o_sample
);

    // One guard bit allows the endpoint arithmetic to be expressed without
    // overflowing before the final slice back to int_sample_t.
    typedef logic      [dds_pkg::INT_SAMPLE_WIDTH-1:0] sample_bits_t;
    typedef logic signed [dds_pkg::INT_SAMPLE_WIDTH:0] sample_ext_t;

    sample_bits_t delta;
    sample_ext_t  sample_ext;

    // Use the highest available phase fraction bits so slope resolution tracks
    // INT_SAMPLE_WIDTH.
    always_comb begin
        delta      = i_phase[dds_pkg::PHASE_WIDTH-2 -: dds_pkg::INT_SAMPLE_WIDTH];
        sample_ext = '0;

        if (i_phase[dds_pkg::PHASE_WIDTH-1] == 1'b0) begin
            sample_ext = $signed({dds_pkg::INT_SAMPLE_MAX[dds_pkg::INT_SAMPLE_WIDTH-1], dds_pkg::INT_SAMPLE_MAX})
                       - $signed({1'b0, delta});
        end
        else begin
            sample_ext = $signed({dds_pkg::INT_SAMPLE_MIN[dds_pkg::INT_SAMPLE_WIDTH-1], dds_pkg::INT_SAMPLE_MIN})
                       + $signed({1'b0, delta});
        end

        o_sample = sample_ext[dds_pkg::INT_SAMPLE_WIDTH-1:0];
    end

endmodule

`default_nettype wire
