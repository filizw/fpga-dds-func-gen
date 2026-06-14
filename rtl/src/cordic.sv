`timescale 1ns/1ps
`default_nettype none

// Pipelined sine/cosine CORDIC.
// Accepts a DDS phase word where 2^PHASE_WIDTH represents one full turn and
// emits signed internal samples after CORDIC_ITER+1 cycles. The input phase is
// folded into quadrant I so the iterative rotator only covers 0..90 degrees.
module cordic (
    input  logic                 i_clk,
    input  logic                 i_rst,

    input  logic                 i_phase_valid,
    input  dds_pkg::phase_t      i_phase,

    output logic                 o_sample_valid,
    output dds_pkg::int_sample_t o_sin_sample,
    output dds_pkg::int_sample_t o_cos_sample
);

    // CORDIC datapath format.
    localparam int INT_SAMPLE_WIDTH = dds_pkg::INT_SAMPLE_WIDTH;
    localparam int PHASE_WIDTH      = dds_pkg::PHASE_WIDTH;

    localparam int ITERATIONS = dds_pkg::CORDIC_ITER;

    // Internal x/y values use signed Q1.FRAC_BITS. CORDIC_OUTPUT_SHIFT restores
    // the package's int_sample_t scale before final saturation.
    localparam int FRAC_BITS           = INT_SAMPLE_WIDTH - 2;
    localparam int CORDIC_OUTPUT_SHIFT = (INT_SAMPLE_WIDTH - 1) - FRAC_BITS;

    typedef logic signed [PHASE_WIDTH:0] phase_ext_t;

    // Preload x with 1/K so the rotation gain is compensated in the pipeline.
    // 0.607252935 is the reciprocal CORDIC gain for enough rotation stages.
    localparam longint               CORDIC_GAIN_COMP_INT = (((64'd1 << FRAC_BITS) * 607252935 + 500000000) / 1000000000);
    localparam dds_pkg::int_sample_t CORDIC_GAIN_COMP     = $signed(INT_SAMPLE_WIDTH'(CORDIC_GAIN_COMP_INT));

    // Simulation-time guards.
`ifndef SYNTHESIS
    initial begin
        if (PHASE_WIDTH != 32) begin
            $fatal(1, "cordic currently requires 32-bit phase words");
        end

        if (FRAC_BITS < 0) begin
            $fatal(1, "cordic INT_SAMPLE_WIDTH is too narrow");
        end
    end
`endif

    logic  [1:0] quadrant;
    logic [29:0] phase_fraction;
    logic [30:0] folded_phase;
    logic        negate_sin;
    logic        negate_cos;

    // Pipelined CORDIC state and delayed quadrant sign corrections.
    phase_ext_t           initial_phase_err;
    dds_pkg::int_sample_t sin_result;
    dds_pkg::int_sample_t cos_result;

    dds_pkg::int_sample_t x_pipe_reg [0:ITERATIONS];
    dds_pkg::int_sample_t y_pipe_reg [0:ITERATIONS];
    phase_ext_t           phase_err_pipe_reg [0:ITERATIONS];
    logic                 negate_sin_pipe_reg [0:ITERATIONS];
    logic                 negate_cos_pipe_reg [0:ITERATIONS];
    logic                 valid_pipe_reg [0:ITERATIONS];

    dds_pkg::int_sample_t sin_sample_reg;
    dds_pkg::int_sample_t cos_sample_reg;
    logic                 sample_valid_reg;

    int stage;

    assign o_sin_sample   = sin_sample_reg;
    assign o_cos_sample   = cos_sample_reg;
    assign o_sample_valid = sample_valid_reg;

    function automatic dds_pkg::phase_t atan_lut(input int index);
        case (index)
            0:  atan_lut = 32'h2000_0000;
            1:  atan_lut = 32'h12e4_051e;
            2:  atan_lut = 32'h09fb_385b;
            3:  atan_lut = 32'h0511_11d4;
            4:  atan_lut = 32'h028b_0d43;
            5:  atan_lut = 32'h0145_d7e1;
            6:  atan_lut = 32'h00a2_f61e;
            7:  atan_lut = 32'h0051_7c55;
            8:  atan_lut = 32'h0028_be53;
            9:  atan_lut = 32'h0014_5f2f;
            10: atan_lut = 32'h000a_2f98;
            11: atan_lut = 32'h0005_17cc;
            12: atan_lut = 32'h0002_8be6;
            13: atan_lut = 32'h0001_45f3;
            default: atan_lut = '0;
        endcase
    endfunction

    // Fold phase into the first quadrant and track output signs.
    // The two phase MSBs select the quadrant; the remaining 30 bits represent
    // fractional phase inside that quadrant for a 32-bit phase word.
    always_comb begin
        quadrant       = i_phase[PHASE_WIDTH-1 -: 2];
        phase_fraction = i_phase[PHASE_WIDTH-3 -: 30];

        folded_phase = {1'b0, phase_fraction};
        negate_sin   = 1'b0;
        negate_cos   = 1'b0;

        case (quadrant)
            2'd0: begin
                folded_phase = {1'b0, phase_fraction};
                negate_sin   = 1'b0;
                negate_cos   = 1'b0;
            end

            2'd1: begin
                folded_phase = 31'h4000_0000 - {1'b0, phase_fraction};
                negate_sin   = 1'b0;
                negate_cos   = 1'b1;
            end

            2'd2: begin
                folded_phase = {1'b0, phase_fraction};
                negate_sin   = 1'b1;
                negate_cos   = 1'b1;
            end

            2'd3: begin
                folded_phase = 31'h4000_0000 - {1'b0, phase_fraction};
                negate_sin   = 1'b1;
                negate_cos   = 1'b0;
            end
        endcase

        initial_phase_err = $signed({2'b00, folded_phase});
    end

    // Restore the sine/cosine signs removed by quadrant folding.
    always_comb begin
        sin_result = negate_sin_pipe_reg[ITERATIONS] ? -y_pipe_reg[ITERATIONS] : y_pipe_reg[ITERATIONS];
        cos_result = negate_cos_pipe_reg[ITERATIONS] ? -x_pipe_reg[ITERATIONS] : x_pipe_reg[ITERATIONS];
    end

    // Iterative rotation pipeline.
    // Each stage rotates by +/-atan(2^-stage). Arithmetic shifts preserve the
    // sign of x/y while implementing the power-of-two multiply.
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            for (stage = 0; stage <= ITERATIONS; stage = stage + 1) begin
                x_pipe_reg[stage]          <= '0;
                y_pipe_reg[stage]          <= '0;
                phase_err_pipe_reg[stage]  <= '0;
                negate_sin_pipe_reg[stage] <= 1'b0;
                negate_cos_pipe_reg[stage] <= 1'b0;
                valid_pipe_reg[stage]      <= 1'b0;
            end

            sin_sample_reg   <= '0;
            cos_sample_reg   <= '0;
            sample_valid_reg <= 1'b0;
        end
        else begin
            x_pipe_reg[0]          <= i_phase_valid ? CORDIC_GAIN_COMP : '0;
            y_pipe_reg[0]          <= '0;
            phase_err_pipe_reg[0]  <= i_phase_valid ? initial_phase_err : '0;
            negate_sin_pipe_reg[0] <= i_phase_valid ? negate_sin : 1'b0;
            negate_cos_pipe_reg[0] <= i_phase_valid ? negate_cos : 1'b0;
            valid_pipe_reg[0]      <= i_phase_valid;

            for (stage = 0; stage < ITERATIONS; stage = stage + 1) begin
                // Drive residual phase toward zero; the sign selects rotation
                // direction for the next micro-rotation.
                if (phase_err_pipe_reg[stage] >= 0) begin
                    x_pipe_reg[stage+1]         <= x_pipe_reg[stage] - (y_pipe_reg[stage] >>> stage);
                    y_pipe_reg[stage+1]         <= y_pipe_reg[stage] + (x_pipe_reg[stage] >>> stage);
                    phase_err_pipe_reg[stage+1] <= phase_err_pipe_reg[stage] - $signed({1'b0, atan_lut(stage)});
                end
                else begin
                    x_pipe_reg[stage+1]         <= x_pipe_reg[stage] + (y_pipe_reg[stage] >>> stage);
                    y_pipe_reg[stage+1]         <= y_pipe_reg[stage] - (x_pipe_reg[stage] >>> stage);
                    phase_err_pipe_reg[stage+1] <= phase_err_pipe_reg[stage] + $signed({1'b0, atan_lut(stage)});
                end

                negate_sin_pipe_reg[stage+1] <= negate_sin_pipe_reg[stage];
                negate_cos_pipe_reg[stage+1] <= negate_cos_pipe_reg[stage];
                valid_pipe_reg[stage+1]      <= valid_pipe_reg[stage];
            end

            // Saturation protects the two's-complement minimum/maximum endpoints
            // after gain compensation and final scale restoration.
            sin_sample_reg <= dds_pkg::clamp_int_sample(dds_pkg::int_sample_ext_t'(sin_result) <<< CORDIC_OUTPUT_SHIFT);
            cos_sample_reg <= dds_pkg::clamp_int_sample(dds_pkg::int_sample_ext_t'(cos_result) <<< CORDIC_OUTPUT_SHIFT);

            sample_valid_reg <= valid_pipe_reg[ITERATIONS];
        end
    end

endmodule

`default_nettype wire
