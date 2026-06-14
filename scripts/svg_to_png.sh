#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

OUT_DIR="docs/figures"
DPI="${DPI:-200}"

convert_one() {
    local name="$1"
    local src=""

    if [[ -f "${OUT_DIR}/${name}.svg" ]]; then
        src="${OUT_DIR}/${name}.svg"
    elif [[ -f "model/octave/figures/${name}.svg" ]]; then
        src="model/octave/figures/${name}.svg"
    else
        echo "Missing SVG source for ${name}" >&2
        return 1
    fi

    inkscape "${src}" --export-type=png --export-dpi="${DPI}" --export-filename="${OUT_DIR}/${name}.png"
}

mkdir -p "${OUT_DIR}"

convert_one dds_carrier_sine
convert_one waveform_comparison
convert_one am_modulation
convert_one fm_modulation
convert_one pm_modulation
