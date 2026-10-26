function plot_sensitivity_figure(root, show, mode, fs)
%% 关键参数敏感性矩阵(一图一幅): 各参数水平下本文方法相对各对比方案的累计NPV领先幅度(%)
%  plot_sensitivity_figure                       % 事后评估结果(sens_expost/), 弹出并保存
%  plot_sensitivity_figure([], false, 'replan')   % 重规划结果(sens_replan/), 只保存不弹出
%  plot_sensitivity_figure([], true, 'expost', 18) % 指定图中字号(磅), 默认 14; 版面随字号自动调整(utils/fit_figure_text)
%  输出: simulation_output/paper_figs/S01_sensitivity_matrix(.png/.pdf), 重规划为 S02_sensitivity_matrix_replan
%  行: 基准 + 各参数两个扰动水平(标注本文方法该水平下的累计NPV, 亿元); 列: 五组对比方案
if nargin < 1 || isempty(root); root = sens_root(); end
addpath(root);
if nargin < 2 || isempty(show); show = true; end
if nargin < 3 || isempty(mode); mode = 'expost'; end
if nargin < 4 || isempty(fs); fs = 14; end
setappdata(0, 'pf_fs', fs); addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'utils'));
T = collect_sensitivity(root, mode);
SP = sens_params(mode); pn = fieldnames(SP)';
C = comparison_cases(); sn = fieldnames(C)';
labc = {{'S1', 'AHGF'}, {'S2', 'PO-VFS-FBR'}, {'S3', 'AFZ-VFS-SHAP'}, {'S4', 'MRP'}, {'S5', 'WM'}};
% 列定义
cols = struct('param', {'base'}, 'level', {NaN}, 'name', {'Baseline'}, 'lv', {''});
for ip = 1:numel(pn)
    p = pn{ip};
    for il = 1:numel(SP.(p).levels)
        lev = SP.(p).levels(il);
        if SP.(p).rel; lv = sprintf('×%.1f', lev); else; lv = sprintf('%.0f%%', 100 * lev); end
        cols(end+1) = struct('param', p, 'level', lev, 'name', SP.(p).name, 'lv', lv); %#ok<AGROW>
    end
end
NC = numel(cols); NR = numel(sn);
V = nan(NR, NC); base = nan(1, NC);
for j = 1:NC
    for i = 0:NR
        if i == 0; s = 'Proposed'; else; s = sn{i}; end
        k = find(strcmp({T.param}, cols(j).param) & strcmp({T.scheme}, s) & ...
                 (isnan([T.level]) & isnan(cols(j).level) | [T.level] == cols(j).level), 1);
        if isempty(k); continue; end
        if i == 0; base(j) = T(k).npv; else; V(i, j) = T(k).rel; end
    end
end
if all(isnan(V(:))); fprintf('[敏感性图] 暂无可用结果, 跳过\n'); return; end

% 样式(与 plot_comparison_figures 一致); 行 = 参数水平, 列 = 对比方案, 标签全部水平排布
% 各对比方案均低于本文时, 色块显示本文方法的领先幅度(正值, 以本文累计NPV为基准); 否则显示相对差值率
S = sty_();
W = V'; NS = NC; NK = NR;                       % W(行=参数水平, 列=方案)
lead = all(W(isfinite(W)) <= 0);
if lead; W = -W; end
vis = 'off'; if show; vis = 'on'; end
f = figure('Visible', vis, 'Color', 'w', 'Units', 'centimeters', 'Position', [2 2 17 11]);
set(f, 'DefaultAxesFontName', S.font, 'DefaultTextFontName', S.font);
ax = axes(f); hold(ax, 'on'); ax.Position = [0.44 0.035 0.40 0.80];
lm = max(abs(W(:)), [], 'omitnan'); if ~(lm > 0); lm = 1; end
for i = 1:NS
    for j = 1:NK
        if isfinite(W(i, j))
            patch(ax, j + [-0.5 0.5 0.5 -0.5], i + [-0.5 -0.5 0.5 0.5], W(i, j), 'EdgeColor', [1 1 1], 'LineWidth', 1.2);
            tc = S.INK; if abs(W(i, j)) > 0.55 * lm; tc = [1 1 1]; end
            text(ax, j, i, sprintf('%.1f', W(i, j)), 'HorizontalAlignment', 'center', 'FontSize', fz(7.5), 'Color', tc);
        else
            patch(ax, j + [-0.5 0.5 0.5 -0.5], i + [-0.5 -0.5 0.5 0.5], [0.93 0.93 0.93], 'EdgeColor', [1 1 1], 'LineWidth', 1.2);
            text(ax, j, i, '/', 'HorizontalAlignment', 'center', 'FontSize', fz(7.5), 'Color', S.SOFT);
        end
    end
end
% 参数分组分隔线(水平)
gb = find(~strcmp({cols(2:end).param}, {cols(1:end-1).param})) + 0.5;
for g = gb; plot(ax, [0.5 NK + 0.5], [g g], '-', 'Color', [1 1 1], 'LineWidth', 3.5); end
if lead
    colormap(ax, S.SEQ); try; clim(ax, [0 lm]); catch; caxis(ax, [0 lm]); end %#ok<CAXIS>
    cbl = 'Lead of the proposed approach in cumulative NPV (%)';
else
    colormap(ax, S.DIV); try; clim(ax, [-lm lm]); catch; caxis(ax, [-lm lm]); end %#ok<CAXIS>
    cbl = 'Cumulative NPV relative to the proposed approach (%)';
end
% 列标题(方案编号, 全称见表1)置于矩阵上方; 行标签上方注明括号内数值的含义
for j = 1:NK
    text(ax, j, 0.42, labc{j}{1}, 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
        'FontSize', fz(7.5), 'Color', S.INK, 'Clipping', 'off');
end
text(ax, 0.40, 0.42, {'Parameter level', '(proposed NPV, billion CNY)'}, 'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', ...
    'FontSize', fz(7), 'Color', S.SOFT, 'Clipping', 'off');
yt = cell(1, NS);
for i = 1:NS
    if i == 1; head = 'Baseline'; else; head = sprintf('%s %s', cols(i).name, cols(i).lv); end
    if isfinite(base(i)); yt{i} = sprintf('%s (%.1f)', head, base(i) / 10); else; yt{i} = head; end
end
set(ax, 'XTick', [], 'YTick', 1:NS, 'YTickLabel', yt, 'YDir', 'reverse', 'TickLength', [0 0], ...
    'XLim', [0.5 NK + 0.5], 'YLim', [0.5 NS + 0.5], 'FontName', S.font, 'FontSize', fz(7.5), 'XColor', 'none', 'YColor', S.INK, ...
    'Box', 'off');
try; ax.YRuler.Axle.LineStyle = 'none'; catch; end
cb = colorbar(ax); cb.Color = S.SOFT; cb.FontSize = fz(6.5); cb.TickDirection = 'out';
cb.Position = [0.86 0.035 0.02 0.80];
cb.Label.String = cbl; cb.Label.Color = S.INK; cb.Label.FontSize = fz(8); try; cb.Box = 'off'; catch; end
% 保存
fd = fullfile(root, 'simulation_output', 'paper_figs'); if ~exist(fd, 'dir'); mkdir(fd); end
try; set(ax, 'Toolbar', []); catch; end
nm = 'S01_sensitivity_matrix'; if strcmp(mode, 'replan'); nm = 'S02_sensitivity_matrix_replan'; end
set(f, 'Name', nm, 'NumberTitle', 'off'); drawnow;
fit_figure_text(f);                                                   % 放大字号后的折行、收缩与防裁切
exportgraphics(f, fullfile(fd, [nm '.png']), 'Resolution', 600);
try; exportgraphics(f, fullfile(fd, [nm '.pdf']), 'ContentType', 'vector'); catch; end
if ~show; close(f); end
fprintf('[敏感性图] 已保存 %s\n', fullfile(fd, [nm '.png']));
end

% ─────────────────────────────────────────────────────────────────────────
function S = sty_()
fl = listfonts; cand = {'Arial', 'Helvetica', 'Liberation Sans'};
S.font = get(groot, 'defaultAxesFontName');
for k = 1:numel(cand); if any(strcmpi(fl, cand{k})); S.font = cand{k}; break; end; end
h = @(s) sscanf(s(2:end), '%2x%2x%2x', [1 3]) / 255;
S.INK = h('#2B3A44'); S.SOFT = h('#6B7780');
hx = {'#2F6E80', '#7FB3AE', '#F4F1E6', '#E3A07E', '#B4533A'};
Cm = cell2mat(cellfun(h, hx(:), 'Uni', 0));
S.DIV = interp1(linspace(0, 1, size(Cm, 1)), Cm, linspace(0, 1, 256)');
hs = {'#F4F1E6', '#D6E6DA', '#9BC7BB', '#5FA39A', '#2F6E80', '#1E3F5A'};
Cs = cell2mat(cellfun(h, hs(:), 'Uni', 0));
S.SEQ = interp1(linspace(0, 1, size(Cs, 1)), Cs, linspace(0, 1, 256)');
end
