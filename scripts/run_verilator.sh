#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

export CCACHE_DISABLE="${CCACHE_DISABLE:-1}"

mkdir -p sim/out

RTL_SOURCES=(
    rtl/include/dds_pkg.sv
    rtl/src/phase_accumulator.sv
    rtl/src/cordic.sv
    rtl/src/square_generator.sv
    rtl/src/triangle_generator.sv
    rtl/src/waveform_generator.sv
    rtl/src/modulation_engine.sv
    rtl/src/phase_control.sv
    rtl/src/amplitude_control.sv
    rtl/src/dds_core.sv
    rtl/src/dds_core_wrapper.sv
)

TB_CORDIC_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_cordic.sv
    rtl/src/cordic.sv
)

TB_PHASE_ACCUMULATOR_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_phase_accumulator.sv
    rtl/src/phase_accumulator.sv
)

TB_PHASE_CONTROL_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_phase_control.sv
    rtl/src/phase_accumulator.sv
    rtl/src/phase_control.sv
)

TB_AMPLITUDE_CONTROL_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_amplitude_control.sv
    rtl/src/amplitude_control.sv
)

TB_WAVEFORM_GENERATOR_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_waveform_generator.sv
    rtl/src/cordic.sv
    rtl/src/square_generator.sv
    rtl/src/triangle_generator.sv
    rtl/src/waveform_generator.sv
)

TB_MODULATION_ENGINE_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_modulation_engine.sv
    rtl/src/phase_accumulator.sv
    rtl/src/cordic.sv
    rtl/src/square_generator.sv
    rtl/src/triangle_generator.sv
    rtl/src/waveform_generator.sv
    rtl/src/modulation_engine.sv
)

TB_DDS_CORE_SOURCES=(
    rtl/include/dds_pkg.sv
    sim/tb/include/tb_common_pkg.sv
    sim/tb/src/tb_dds_core.sv
    rtl/src/phase_accumulator.sv
    rtl/src/cordic.sv
    rtl/src/square_generator.sv
    rtl/src/triangle_generator.sv
    rtl/src/waveform_generator.sv
    rtl/src/modulation_engine.sv
    rtl/src/phase_control.sv
    rtl/src/amplitude_control.sv
    rtl/src/dds_core.sv
)

lint() {
    verilator --lint-only "${RTL_SOURCES[@]}"
    verilator --lint-only --top-module tb_phase_accumulator "${TB_PHASE_ACCUMULATOR_SOURCES[@]}"
    verilator --lint-only --top-module tb_phase_control "${TB_PHASE_CONTROL_SOURCES[@]}"
    verilator --lint-only --top-module tb_amplitude_control "${TB_AMPLITUDE_CONTROL_SOURCES[@]}"
    verilator --lint-only --top-module tb_waveform_generator "${TB_WAVEFORM_GENERATOR_SOURCES[@]}"
    verilator --lint-only --top-module tb_cordic "${TB_CORDIC_SOURCES[@]}"
    verilator --lint-only --top-module tb_modulation_engine "${TB_MODULATION_ENGINE_SOURCES[@]}"
    verilator --lint-only --top-module tb_dds_core "${TB_DDS_CORE_SOURCES[@]}"
}

build() {
    verilator --binary --trace --timing --top-module tb_phase_accumulator "${TB_PHASE_ACCUMULATOR_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_phase_control "${TB_PHASE_CONTROL_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_amplitude_control "${TB_AMPLITUDE_CONTROL_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_waveform_generator "${TB_WAVEFORM_GENERATOR_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_cordic "${TB_CORDIC_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_modulation_engine "${TB_MODULATION_ENGINE_SOURCES[@]}"
    verilator --binary --trace --timing --top-module tb_dds_core "${TB_DDS_CORE_SOURCES[@]}"
    verilator --binary --trace --timing --top-module dds_core "${RTL_SOURCES[@]}"
}

run() {
    obj_dir/Vtb_phase_accumulator
    obj_dir/Vtb_phase_control
    obj_dir/Vtb_amplitude_control
    obj_dir/Vtb_waveform_generator
    obj_dir/Vtb_cordic
    obj_dir/Vtb_modulation_engine
    obj_dir/Vtb_dds_core
}

clean() {
    rm -rf obj_dir sim/out
}

usage() {
    cat <<'EOF'
Usage: scripts/run_verilator.sh <command>

Commands:
  lint   Lint RTL and supported testbenches
  build  Build RTL and supported testbenches
  run    Run built testbench executables
  all    Run lint, build, and testbenches
  clean  Remove Verilator build artifacts and generated simulation outputs
EOF
}

case "${1:-all}" in
    lint)
        lint
        ;;
    build)
        build
        ;;
    run)
        run
        ;;
    clean)
        clean
        ;;
    all)
        lint
        build
        run
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
