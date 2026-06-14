`timescale 1ns/1ps
`default_nettype none

// Output amplitude scaler.
// Applies carrier amplitude and AM gain to an internal signed waveform sample,
// rounds intermediate products to control width growth, then saturates to the
// external signed SAMPLE_WIDTH output. Gain inputs are unsigned Q1.(AMP_WIDTH-1).
module amplitude_control (
    input  logic                 i_clk,
    input  logic                 i_rst,

    input  logic                 i_sample_valid,
    input  dds_pkg::int_sample_t i_sample,
    input  dds_pkg::amp_t        i_carr_amp,
    input  dds_pkg::amp_t        i_am_gain,

    output logic                 o_sample_valid,
    output dds_pkg::sample_t     o_sample
);

    // The first product is shortened before the second gain multiply to keep the
    // final product width practical. OUTPUT_REDUCED_SHIFT preserves the same
    // total fixed-point scale as a full-width two-gain multiply.
    localparam int MULT1_REDUCE_SHIFT   = 6;
    localparam int MULT1_REDUCED_WIDTH  = dds_pkg::AMP_MULT1_WIDTH - MULT1_REDUCE_SHIFT;
    localparam int MULT2_REDUCED_WIDTH  = MULT1_REDUCED_WIDTH + dds_pkg::AMP_WIDTH;
    localparam int OUTPUT_REDUCED_SHIFT = dds_pkg::AMP_OUTPUT_SHIFT - MULT1_REDUCE_SHIFT;

    // Signed product types retain the waveform sign through both gain stages.
    typedef logic signed [MULT1_REDUCED_WIDTH-1:0] amp_mult1_reduced_t;
    typedef logic signed [MULT2_REDUCED_WIDTH-1:0] amp_mult2_reduced_t;

    // Four-cycle datapath: gain clamp, first multiply, second multiply, final
    // rounding/saturation.
    dds_pkg::amp_t       am_gain_reg;
    dds_pkg::amp_t       am_gain_mult2_reg;
    dds_pkg::amp_mult1_t mult1_reg;
    amp_mult1_reduced_t  mult1_reduced_reg;
    amp_mult2_reduced_t  mult2_reg;
    amp_mult2_reduced_t  rounded_reg;
    logic          [3:0] valid_pipe_reg;
    logic                sample_valid_reg;
    dds_pkg::sample_t    sample_reg;

    assign o_sample_valid = sample_valid_reg;
    assign o_sample       = sample_reg;

    // Round-to-nearest-even before reducing the first product width.
    // Arithmetic shift preserves the signed waveform product.
    function automatic amp_mult1_reduced_t round_mult1(
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

            round_mult1 = amp_mult1_reduced_t'(value_rounded[MULT1_REDUCED_WIDTH-1:0]);
        end
    endfunction

    // Round-to-nearest-even after restoring the final output scale.
    function automatic amp_mult2_reduced_t round_scaled_sample(
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

            round_scaled_sample = value_rounded;
        end
    endfunction

    // Saturate instead of wrapping so full-scale gain cannot invert the output.
    function automatic dds_pkg::sample_t saturate_sample(
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
                saturate_sample = dds_pkg::SAMPLE_MAX;
            end
            else if (value < SAMPLE_MIN_EXT) begin
                saturate_sample = dds_pkg::SAMPLE_MIN;
            end
            else begin
                saturate_sample = value[dds_pkg::SAMPLE_WIDTH-1:0];
            end
        end
    endfunction

    // Registered multiplier pipeline.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            am_gain_reg        <= dds_pkg::AMP_ONE;
            am_gain_mult2_reg  <= dds_pkg::AMP_ONE;
            mult1_reg          <= '0;
            mult1_reduced_reg  <= '0;
            mult2_reg          <= '0;
            rounded_reg        <= '0;
            valid_pipe_reg     <= '0;
            sample_valid_reg   <= 1'b0;
            sample_reg         <= '0;
        end
        else begin
            am_gain_reg       <= dds_pkg::clamp_amp(i_am_gain);
            am_gain_mult2_reg <= am_gain_reg;

            mult1_reg         <= i_sample * $signed({1'b0, dds_pkg::clamp_amp(i_carr_amp)});
            mult1_reduced_reg <= round_mult1(mult1_reg);
            mult2_reg         <= mult1_reduced_reg * $signed({1'b0, am_gain_mult2_reg});
            rounded_reg       <= round_scaled_sample(mult2_reg);

            valid_pipe_reg <= {valid_pipe_reg[2:0], i_sample_valid};

            sample_valid_reg <= valid_pipe_reg[3];
            sample_reg       <= saturate_sample(rounded_reg);
        end
    end

endmodule

`default_nettype wire
