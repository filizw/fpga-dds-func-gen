function y = dds_model(cfg)
%DDS_MODEL Small behavioral DDS model for experiments.
%
%   y = dds_model() runs with friendly defaults.
%   y = dds_model(struct('waveform', 'square', 'am_depth', 0.8)) overrides
%   only the fields you care about.

if nargin < 1
    cfg = struct();
end

cfg = with_defaults(cfg);
n = 0:(round(cfg.num_samples) - 1);

carrier_phase = phase_ramp(n, cfg.carrier_freq, cfg.sample_rate, cfg.initial_phase);
mod_phase = phase_ramp(n, cfg.mod_freq, cfg.sample_rate, cfg.initial_phase);
mod_signal = waveform_from_phase(mod_phase, cfg.mod_waveform);

output_phase = carrier_phase + cfg.carrier_phase;
carrier = cfg.carrier_amp * waveform_from_phase(output_phase, cfg.waveform);

am_gain = 1.0 - cfg.am_depth / 2.0 + cfg.am_depth / 2.0 * mod_signal;
fm_freq = max(cfg.carrier_freq * (1.0 + cfg.fm_depth * mod_signal), 0.0);
fm_phase = wrap_phase(cfg.initial_phase + [0, cumsum(2 * pi * fm_freq(1:end - 1) / cfg.sample_rate)]);
pm_phase = output_phase + cfg.pm_depth * pi * mod_signal;

am = am_gain .* carrier;
fm = cfg.carrier_amp * waveform_from_phase(fm_phase + cfg.carrier_phase, ...
                                           cfg.waveform);
pm = cfg.carrier_amp * waveform_from_phase(pm_phase, cfg.waveform);

y.cfg = cfg;
y.n = n;
y.clk = n;
y.carrier_phase = carrier_phase;
y.mod_signal = mod_signal;
y.carrier = carrier;
y.am_gain = am_gain;
y.am = am;
y.fm_freq = fm_freq;
y.fm_phase = fm_phase;
y.fm = fm;
y.pm_offset = cfg.pm_depth * pi * mod_signal;
y.pm = pm;
end

function cfg = with_defaults(cfg)
    defaults = struct( ...
        'sample_rate', 1.0, ...
        'num_samples', 1024, ...
        'carrier_freq', 1/64, ...
        'mod_freq', 1/1024, ...
        'carrier_amp', 1.0, ...
        'carrier_phase', 0.0, ...
        'am_depth', 0.5, ...
        'fm_depth', 1.0, ...
        'pm_depth', 1.0, ...
        'waveform', 'sine', ...
        'mod_waveform', 'sine', ...
        'initial_phase', 0.0);

    for name = fieldnames(defaults)'
        key = name{1};
        if ~isfield(cfg, key)
            cfg.(key) = defaults.(key);
        end
    end
end

function phase = phase_ramp(n, freq, sample_rate, initial_phase)
    phase = wrap_phase(initial_phase + 2 * pi * freq * n / sample_rate);
end

function phase = wrap_phase(phase)
    phase = mod(phase, 2 * pi);
end

function x = waveform_from_phase(phase, waveform)
    switch lower(waveform)
        case 'sine'
            x = sin(phase);
        case 'dc'
            x = ones(size(phase));
        case 'square'
            x = sign(sin(phase));
            x(x == 0) = 1;
        case 'triangle'
            cycle = mod(phase / (2 * pi), 1.0);
            x = 4 * abs(cycle - 0.5) - 1;
        otherwise
            error('Unsupported waveform "%s". Use dc, sine, square, or triangle.', waveform);
    end
end
