function generate_figures(out_dir)
%GENERATE_FIGURES Draw a few DDS examples as SVG files.
%
%   generate_figures() writes to ./figures.
%   generate_figures('/tmp/dds') writes to a custom directory.

if nargin < 1
    out_dir = fullfile(pwd, 'figures');
end

if ~exist(out_dir, 'dir')
    mkdir(out_dir);
end

set(0, 'defaultfigurevisible', 'off');
set(0, 'defaultaxesfontsize', 11);
set(0, 'defaulttextfontsize', 11);
set(0, 'defaultlinelinewidth', 1.45);

cfg = demo_config();

printf('DDS figure generator\n');
printf('  output    = %s\n', out_dir);
printf('  format    = SVG\n');
printf('  carrier   = %.6g cycles/sample\n', cfg.carrier_freq);
printf('  modulator = %.6g cycles/sample\n', cfg.mod_freq);

plot_carrier(cfg, out_dir);
plot_waveforms(cfg, out_dir);
plot_modulation(cfg, out_dir, 'am', 'Modulacja AM');
plot_modulation(cfg, out_dir, 'fm', 'Modulacja FM');
plot_modulation(cfg, out_dir, 'pm', 'Modulacja PM');

printf('Done.\n');
end

function cfg = demo_config()
    cfg.sample_rate = 1.0;
    cfg.carrier_freq = 1/64;
    cfg.mod_freq = 1/512;
    cfg.carrier_amp = 1.0;
    cfg.carrier_phase = 0.0;
    cfg.am_depth = 0.75;
    cfg.fm_depth = 0.75;
    cfg.pm_depth = 0.75;
    cfg.waveform = 'sine';
    cfg.mod_waveform = 'sine';
end

function plot_carrier(cfg, out_dir)
    cfg.num_samples = round(3 / cfg.carrier_freq);
    y = dds_model(cfg);

    fig = figure_px([1500, 720]);
    plot_sample_stairs(y.n, y.carrier, palette(1), 1.8);
    style_axis('Sample n', 'Normalized amplitude', y.n);
    title('DDS sine carrier');
    save_svg(fig, out_dir, 'dds_carrier_sine');
end

function plot_waveforms(cfg, out_dir)
    cfg.num_samples = round(2 / cfg.carrier_freq);
    waveforms = {'dc', 'sine', 'square', 'triangle'};

    fig = figure_px([1500, 900]);
    for idx = 1:numel(waveforms)
        cfg.waveform = waveforms{idx};
        y = dds_model(cfg);

        subplot(numel(waveforms), 1, idx);
        plot_sample_stairs(y.n, y.carrier, palette(idx), 1.5);
        style_axis('', upper_first(waveforms{idx}), y.n);
        if idx < numel(waveforms)
            set(gca, 'XTickLabel', []);
        else
            xlabel('Sample n');
        end
        if idx == 1
            title('DDS waveform shapes');
        end
    end
    save_svg(fig, out_dir, 'waveform_comparison');
end

function plot_modulation(cfg, out_dir, field, title_text)
    cfg.num_samples = round(2 / cfg.mod_freq);
    y = dds_model(cfg);

    fig = figure_px([1500, 900]);
    traces = { ...
        y.carrier, 'Carrier'; ...
        y.mod_signal, 'Modulator'; ...
        y.(field), 'Output'};

    num_traces = size(traces, 1);
    for idx = 1:num_traces
        subplot(num_traces, 1, idx);
        plot_sample_stairs(y.n, traces{idx, 1}, palette(idx), 1.45);
        style_axis('', traces{idx, 2}, y.n);
        if idx < num_traces
            set(gca, 'XTickLabel', []);
        else
            xlabel('Sample n');
        end
        if idx == 1
            title(title_text);
        end
    end
    save_svg(fig, out_dir, [field, '_modulation']);
end

function style_axis(x_text, y_text, n)
    grid on;
    set(gca, 'YGrid', 'on', 'XGrid', 'on');
    xlabel(x_text);
    ylabel(y_text);
    ylim([-1.15, 1.15]);
    yticks([-1, 0, 1]);
    xlim([n(1), n(end) + 1]);
end

function plot_sample_stairs(n, signal, color, line_width)
    x = [n, n(end) + 1];
    y = [signal, signal(end)];
    stairs(x, y, 'Color', color, 'LineWidth', line_width);
end

function fig = figure_px(size_px)
    fig = figure('Position', [100, 100, size_px(1), size_px(2)]);
    set(fig, 'PaperPositionMode', 'auto');
end

function save_svg(fig, out_dir, name)
    print(fig, fullfile(out_dir, [name, '.svg']), '-dsvg');
    close(fig);
end

function c = palette(idx)
    colors = [
        0.00, 0.28, 0.70;
        0.10, 0.55, 0.20;
        0.85, 0.25, 0.05;
        0.25, 0.25, 0.25
    ];
    c = colors(idx, :);
end

function s = upper_first(s)
    s(1) = upper(s(1));
end
