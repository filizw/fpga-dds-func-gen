#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

OCTAVE_MODEL_DIR="model/octave"
FIGURES_DIR="docs/figures"

run() {
    (
        cd "${OCTAVE_MODEL_DIR}"
        octave --no-gui run_demo.m
    )
}

clean() {
    rm -f \
        "${FIGURES_DIR}/dds_carrier_sine.svg" \
        "${FIGURES_DIR}/dds_carrier_sine.png" \
        "${FIGURES_DIR}/waveform_comparison.svg" \
        "${FIGURES_DIR}/waveform_comparison.png" \
        "${FIGURES_DIR}/am_modulation.svg" \
        "${FIGURES_DIR}/am_modulation.png" \
        "${FIGURES_DIR}/fm_modulation.svg" \
        "${FIGURES_DIR}/fm_modulation.png" \
        "${FIGURES_DIR}/pm_modulation.svg" \
        "${FIGURES_DIR}/pm_modulation.png"
}

usage() {
    cat <<'EOF'
Usage: scripts/run_octave.sh <command>

Commands:
  run    Run the Octave DDS demo and generate figures
  all    Run the Octave DDS demo and convert SVG figures to PNG
  png    Convert generated SVG figures to PNG using Inkscape
  clean  Remove generated documentation figures
EOF
}

case "${1:-all}" in
    run)
        run
        ;;
    all)
        run
        scripts/svg_to_png.sh
        ;;
    png)
        scripts/svg_to_png.sh
        ;;
    clean)
        clean
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
