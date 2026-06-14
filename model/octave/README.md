# Octave DDS Model

This is a small behavioral DDS model for playing with carriers, waveform
shapes, and AM/FM/PM modulation. It uses normalized floating-point values:
amplitude is around `-1.0 ... 1.0`, phase is in radians, and frequency is in
cycles per sample when `sample_rate = 1.0`.

## Files

- `dds_model.m` - the model.
- `generate_figures.m` - creates a few SVG examples.
- `run_demo.m` - simple entry point.
- `figures/` - default output directory created by `generate_figures`.

## Quick Start

Run the demo from this directory:

```sh
octave run_demo.m
```

Or call the model directly:

```octave
y = dds_model();
plot(y.n, y.carrier);
```

Override only the fields you want:

```octave
cfg.waveform = 'triangle';
cfg.mod_waveform = 'sine';
cfg.carrier_freq = 1/40;
cfg.mod_freq = 1/400;
cfg.fm_depth = 0.5;

y = dds_model(cfg);
plot(y.n, y.fm);
```

## Configuration

- `sample_rate` - samples per second in your chosen scale; default `1.0`.
- `num_samples` - number of generated samples.
- `carrier_freq` - carrier frequency.
- `mod_freq` - modulator frequency.
- `carrier_amp` - output amplitude scale.
- `carrier_phase` - static carrier phase offset in radians.
- `initial_phase` - starting phase for carrier and modulator.
- `waveform` - `dc`, `sine`, `square`, or `triangle`.
- `mod_waveform` - `dc`, `sine`, `square`, or `triangle`.
- `am_depth` - AM depth; `1.0` moves gain from `0.0` to `1.0`.
- `fm_depth` - FM depth; `1.0` gives `+/-100%` carrier-frequency deviation.
- `pm_depth` - PM depth; `1.0` gives `+/-pi` radians phase deviation.

## Output

`dds_model` returns a struct with:

- `n` / `clk` - sample index.
- `carrier` - unmodulated carrier.
- `mod_signal` - modulating waveform.
- `am` - amplitude-modulated carrier.
- `fm` - frequency-modulated carrier.
- `pm` - phase-modulated carrier.
- `am_gain`, `fm_freq`, `fm_phase`, `pm_offset` - useful internal curves for
  plotting and debugging.

`generate_figures()` writes these SVG files:

- `figures/dds_carrier_sine.svg`
- `figures/waveform_comparison.svg`
- `figures/am_modulation.svg`
- `figures/fm_modulation.svg`
- `figures/pm_modulation.svg`
