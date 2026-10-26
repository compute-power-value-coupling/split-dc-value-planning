function plot_paper_figures(out_dir, show, fs)
%% 论文仿真图 v3 —— 期刊风格(一图一幅、低饱和配色), 读取已有结果, 无需重跑仿真
%  plot_paper_figures                              % 读取 simulation_output, 自动弹出图窗并保存
%  plot_paper_figures('simulation_output', false)  % 只保存不弹出
%  plot_paper_figures('simulation_output', true, 18)  % 指定图中字号(磅), 默认 14; 版面随字号自动调整(utils/fit_figure_text)
%  输出: <out_dir>/paper_figs/   N01–N13 本文仿真图 + M1–M4 国家地图仿真图 (PNG 600dpi + PDF)
%  数据: checkpoint/ckpt_latest.mat, asset_recovery.csv, counterfactual_marginal.csv,
%        investment_force_law.csv, ahm_graph_edges.csv, wm_buffer.mat;  底图: map_data/*.geojson
%  图式: 三维切片瀑布 | 联合核密度+边缘分布 | 六边形分箱+条件均值 | 月份-时刻地形 | 山脊图 |
%        价值势地形+轨迹 | 正负堆叠流 | 气泡矩阵 | 热图+前瞻曲线 | 三维收敛 | 全国流线地图 | 时空立方体
if nargin < 1 || isempty(out_dir); out_dir = 'simulation_output'; end
if nargin < 2; show = true; end
if nargin < 3 || isempty(fs); fs = 14; end
setappdata(0, 'pf_show', show); setappdata(0, 'pf_fs', fs);
root = fileparts(mfilename('fullpath'));
if ~exist(out_dir, 'dir') && exist(fullfile(root, out_dir), 'dir'); out_dir = fullfile(root, out_dir); end
addpath(fullfile(root,'utils'), fullfile(root,'data_loader'), fullfile(root,'output_module'));
fd = fullfile(out_dir, 'paper_figs'); if ~exist(fd,'dir'); mkdir(fd); end
old = [dir(fullfile(fd,'Fig*.*')); dir(fullfile(fd,'N*.*')); dir(fullfile(fd,'M*.*'))];
for k = 1:numel(old); try; delete(fullfile(fd, old(k).name)); catch; end; end
S = sty();
P = struct(); try; [~, P] = evalc('init_parameters()'); catch; end
fprintf('[论文图] 读取结果: %s\n', out_dir);
D = load_all(out_dir);
if D.NY == 0; fprintf('[论文图] 未找到 %s, 无法作图\n', fullfile(out_dir,'checkpoint','ckpt_latest.mat')); return; end
try; MP = map_load(root); catch ME; fprintf('[地图] 底图读取失败: %s\n', ME.message); MP = struct('ok', false); end
figs = {@N01, @N02, @N03, @N04, @N05, @N06, @N07, @N08, @N09, @N10, @N12, @N13, @M1, @M2, @M3, @M4};
for k = 1:numel(figs)
    nm = func2str(figs{k});
    try
        figs{k}(D, P, S, MP, fd); fprintf('  [论文图] %s 完成\n', nm);
    catch ME
        fprintf('  [论文图] %s 跳过: %s (行%d)\n', nm, ME.message, ME.stack(1).line);
    end
end
fprintf('[论文图] 输出目录: %s\n', fd);
end

%% ═══════════════════════════════ 本文仿真图 ═══════════════════════════════
function N01(D, P, S, ~, fd)
% SLA分级需求(三维切片瀑布): x 年份, y SLA类别, z 需求功率, 颜色 h = 单位电量服务价值
NY = D.NY; y = (1:NY)'; dem = D.dem / 1e3;                                   % GW
if all(dem(:) == 0); error('无 demand_y 数据'); end
pueE = mean(getp(P,'eta_PUE_east',[1.25 1.32 1.38])); pueW = mean(getp(P,'eta_PUE_west',[1.20 1.25 1.23 1.20]));
vd = [D.pR D.pR D.pB D.pT] .* (0.1 * D.eta * 1e4) ./ [pueE pueE pueE pueW];  % 元/MWh
[f, ax] = fig3(S, 16, 11.5);
[~, od] = sort(dem(end,:));                                                 % 期末需求小者在前
nm = {'A real-time inference','B interactive inference','C batch tasks','D training'};
for k = 1:4; slice3(ax, S, y, find(od == k) - 1, dem(:,k), vd(:,k), 0); end
cb = cbar_(ax, S, S.TER, [min(vd(:)) max(vd(:))], 'Service value per unit electricity (CNY MWh^{-1})');
set(ax, 'XLim',[1 NY], 'YLim',[-0.4 3.4], 'ZLim',[0 max(dem(:))*1.05], 'YTick',0:3, 'YTickLabel', nm(od));
xlabel(ax,'Planning year','Color',S.INK); zlabel(ax,'Demand (GW)','Color',S.INK);
view(ax, 28, 24); shrink_cb(cb, 0.6);
savefig_(f, fd, 'N01_sla_demand_value', true);
end

function N02(D, ~, S, ~, fd)
% 绿电–训练负荷联合分布: 散点 + 二维核密度等值线 + 边缘分布
NY = D.NY; ys = unique(max(1, round(NY*[1/3 2/3 1]))); cs = [S.NAVY; S.TEAL; S.TERRA];
f = newfig(S, 15, 13);
ax  = axes(f, 'Position', [0.11 0.10 0.64 0.64]); style2(ax, S, true); ax.XGrid = 'on';
axt = axes(f, 'Position', [0.11 0.755 0.64 0.17]); hold(axt, 'on');
axr = axes(f, 'Position', [0.76 0.10 0.17 0.64]); hold(axr, 'on');
gmax = max(max(D.h_green(:, ys))) / 1e3 * 1.02; tmax = max(max(D.h_train(:, ys))) / 1e3 * 1.05;
gx = linspace(0, gmax, 120); gy = linspace(0, tmax, 120);
st = RandStream('mt19937ar', 'Seed', 3); hs = gobjects(1, numel(ys));
for q = 1:numel(ys)
    c = cs(min(q, 3), :); xg = D.h_green(:, ys(q)) / 1e3; yt = D.h_train(:, ys(q)) / 1e3;
    idx = randperm(st, numel(xg), min(1400, numel(xg)));
    scatter(ax, xg(idx), yt(idx), 3, c, 'filled', 'MarkerFaceAlpha', 0.30, 'MarkerEdgeColor', 'none');
    hs(q) = scatter(ax, NaN, NaN, 20, c, 'filled', 'MarkerEdgeColor', 'none');                 % 图例代理
    Z = kde2(xg(idx), yt(idx), gx, gy, 0.22);
    lv = qtile(Z(Z > max(Z(:)) * 1e-3), [0.55 0.75 0.88 0.96]); lw = [0.5 0.7 0.9 1.1];
    for j = 1:4; contour(ax, gx, gy, Z, [lv(j) lv(j)], 'LineColor', c, 'LineWidth', lw(j)); end
    dx = kde1(xg, gx); patch(axt, [gx fliplr(gx)], [dx zeros(size(dx))], c, 'FaceAlpha', 0.18, 'EdgeColor', 'none');
    plot(axt, gx, dx, '-', 'Color', c, 'LineWidth', 1.0);
    dy = kde1(yt, gy); patch(axr, [dy zeros(size(dy))], [gy fliplr(gy)], c, 'FaceAlpha', 0.18, 'EdgeColor', 'none');
    plot(axr, dy, gy, '-', 'Color', c, 'LineWidth', 1.0);
end
set(ax, 'XLim', [0 gmax], 'YLim', [0 tmax]); set(axt, 'XLim', [0 gmax]); set(axr, 'YLim', [0 tmax]);
axis(axt, 'off'); axis(axr, 'off');
xlabel(ax, 'Western green output (GW)', 'Color', S.INK); ylabel(ax, 'Training load (GW)', 'Color', S.INK);
legend(ax, hs, arrayfun(@(v) sprintf('Year %d', v), ys, 'Uni', 0), 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(7.5));
savefig_(f, fd, 'N02_green_training_joint', true);
end

function N03(D, ~, S, ~, fd)
% 价值驱动迁移: 六边形分箱(对数计数) + 条件均值及95%置信带
NY = D.NY; yy = max(1, NY-9):NY;
sp = reshape(D.h_pe(:, yy) - D.h_pw(:, yy), [], 1); ab = reshape(D.h_mig(:, yy) + D.h_boff(:, yy), [], 1) / 1e3;
ok = isfinite(sp) & isfinite(ab); sp = sp(ok); ab = ab(ok);
f = newfig(S, 15, 10.5); ax = axes(f); style2(ax, S, false);
cnt = hexbin_(ax, sp, ab, 48, [min(sp) max(sp)], [min(ab) max(ab)]);
lc = log10(max(cnt, 1));
e = qtile(sp, linspace(0.01, 0.99, 13)); mids = []; mu = []; lo = []; hi = [];
for k = 1:12
    m = sp >= e(k) & sp < e(k+1);
    if nnz(m) > 80
        v = ab(m); se = 1.96 * std(v) / sqrt(numel(v));
        mids(end+1) = mean(sp(m)); mu(end+1) = mean(v); lo(end+1) = mean(v) - se; hi(end+1) = mean(v) + se; %#ok<AGROW>
    end
end
hh = gobjects(0);
if numel(mids) >= 2
    xs = linspace(min(mids), max(mids), 200);
    hh(1) = patch(ax, [xs fliplr(xs)], [sm(mids, lo, xs) fliplr(sm(mids, hi, xs))], S.TERRA, 'FaceAlpha', 0.25, 'EdgeColor', 'none');
    hh(2) = plot(ax, xs, sm(mids, mu, xs), '-', 'Color', S.TERRA, 'LineWidth', 1.8);
    legend(ax, hh, {'95% confidence band', 'Conditional mean'}, 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(7.5));
end
cb = cbar_(ax, S, S.SEQ, [0 max(max(lc), 0.5)], 'Hours (log scale)');
t = 0:floor(max(lc)); cb.Ticks = t; cb.TickLabels = arrayfun(@(v) sprintf('10^{%d}', v), t, 'Uni', 0);
set(ax, 'XLim', qtile(sp, [0.005 0.995]), 'YLim', [min(ab) max(ab)] + [-0.02 0.02]*max(range_(ab), 1e-6));
xlabel(ax, 'East–west price spread (CNY MWh^{-1})', 'Color', S.INK); ylabel(ax, 'Western migration and cross-regional service (GW)', 'Color', S.INK);
savefig_(f, fd, 'N03_value_driven_migration', false);
end

function N04(D, ~, S, ~, fd)
% 月份–时刻运行地形(末年): x 时刻, y 月份, z 训练负荷, 颜色 = 西部绿电出力, 底面投影
yv = D.NY; tr = reshape(D.h_train(1:8760, yv), 24, 365)' / 1e3; gr = reshape(D.h_green(1:8760, yv), 24, 365)' / 1e3;
mon = repelem(1:12, [31 28 31 30 31 30 31 31 30 31 30 31])';
TRm = zeros(12, 24); GRm = zeros(12, 24);
for m = 1:12; TRm(m,:) = mean(tr(mon == m, :), 1); GRm(m,:) = mean(gr(mon == m, :), 1); end
TRm = gsmooth(TRm, 0.9, 1.1); GRm = gsmooth(GRm, 0.9, 1.1);
hh = linspace(0, 23, 96); mm = linspace(0, 11, 60);
Tz = grid_interp(TRm, hh, mm); Gz = grid_interp(GRm, hh, mm); [XX, MM] = meshgrid(hh, mm);
[f, ax] = fig3(S, 16, 11.5); lim = [min(Gz(:)) max(Gz(:))];
surf(ax, XX, MM, Tz, Gz, 'FaceColor', 'interp', 'EdgeColor', [1 1 1], 'EdgeAlpha', 0.35, 'LineWidth', 0.15);
surf(ax, XX, MM, zeros(size(XX)), Gz, 'FaceColor', 'interp', 'EdgeColor', 'none', 'FaceAlpha', 0.55);
[~, hc] = contour(ax, XX, MM, Gz, 8, 'LineColor', [1 1 1], 'LineWidth', 0.35); hc.ContourZLevel = 0.003 * max(Tz(:));
cb = cbar_(ax, S, S.TER, lim, 'Western green output (GW)');
set(ax, 'XLim', [0 23], 'YLim', [0 11], 'ZLim', [0 max(Tz(:))*1.02], 'XTick', [0 6 12 18 23], ...
    'YTick', [0 3 6 9 11], 'YTickLabel', {'Jan','Apr','Jul','Oct','Dec'});
xlabel(ax, 'Hour of day', 'Color', S.INK); ylabel(ax, 'Month', 'Color', S.INK); zlabel(ax, 'Training load (GW)', 'Color', S.INK);
view(ax, -38, 30); shrink_cb(cb, 0.6);
savefig_(f, fd, 'N04_month_hour_terrain', true);
end

function N05(D, ~, S, ~, fd)
% 逐年小时训练负荷山脊图(竖线为中位数)
NY = D.NY; f = newfig(S, 13, 14); ax = axes(f); style2(ax, S, false);
gmax = max(D.h_train(:)) / 1e3 * 1.16; gx = linspace(0, gmax, 500); step = 0.85;
cols = cmap_rgb(S.TER, linspace(0.05, 0.95, NY));
for yv = NY:-1:1
    v = D.h_train(:, yv) / 1e3; d = kde1(v, gx, 0.12); d = d / max(max(d), eps) * 2.2; b = (NY - yv) * step;
    patch(ax, [gx fliplr(gx)], [b + d, b * ones(size(d))], cols(yv,:), 'FaceAlpha', 0.92, 'EdgeColor', 'none');
    plot(ax, gx, b + d, '-', 'Color', [1 1 1], 'LineWidth', 0.9);
    plot(ax, gx, b + d, '-', 'Color', [S.INK 0.5], 'LineWidth', 0.25);
    md = median(v); plot(ax, [md md], [b, b + interp1(gx, d, md)], '-', 'Color', [1 1 1], 'LineWidth', 0.7);
    text(ax, -0.04 * gmax, b + 0.08, sprintf('Year %d', yv), 'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', ...
        'FontSize', fz(7), 'Color', S.SOFT);
end
set(ax, 'YTick', [], 'YColor', 'none', 'XLim', [0 gmax], 'YLim', [-0.1, (NY-1)*step + 2.4]);
xlabel(ax, 'Hourly training load (GW)', 'Color', S.INK);
savefig_(f, fd, 'N05_training_load_ridges', false);
end

function N06(D, ~, S, ~, fd)
% 净价值势地形(世界模型样本三次响应面) + 实际规划轨迹 + 底面等值线
w = D.wmb; if isempty(w) || ~isfield(w, 'samples'); error('缺少 wm_buffer.samples'); end
Sm = w.samples; if iscell(Sm); Sm = [Sm{:}]; end
kb = w.kbar(:)'; cu = w.c_unit(:)'; r = 0.08; crf = @(n) r*(1+r)^n / ((1+r)^n - 1);
au = cu(1:7) .* [0.3*crf(15) + 0.7*crf(4), crf(15), crf(20), crf(10), crf(10), crf(25), crf(20)];
n = numel(Sm); sT = zeros(n,1); sG = sT; Phi = sT; yr = sT; re = false(n,1);
for k = 1:n
    K = Sm(k).K(:)'; Dk = Sm(k).D; F = Sm(k).F(:)';
    sT(k) = log1p(K(1) / (Dk * kb(1))); sG(k) = log1p(K(3) / (Dk * kb(3)));
    Phi(k) = (sum(F) - sum(au(1:numel(K)) .* K)) / max(1, Dk); yr(k) = Sm(k).year; re(k) = logical(Sm(k).real);
end
A = [ones(n,1) sT sG sT.^2 sG.^2 sT.*sG sT.^3 sG.^3]; co = A \ Phi;
pf = @(x, y) co(1) + co(2)*x + co(3)*y + co(4)*x.^2 + co(5)*y.^2 + co(6)*x.*y + co(7)*x.^3 + co(8)*y.^3;
[gx, gy] = meshgrid(linspace(min(sT), max(sT), 70), linspace(min(sG), max(sG), 70)); gz = pf(gx, gy);
lim = [min(gz(:)) max(gz(:))]; z0 = lim(1) - 0.45 * diff(lim);
[f, ax] = fig3(S, 16, 11.5);
surf(ax, gx, gy, gz, gz, 'FaceColor', 'interp', 'EdgeColor', [1 1 1], 'EdgeAlpha', 0.4, 'LineWidth', 0.12);
surf(ax, gx, gy, z0 * ones(size(gz)), gz, 'FaceColor', 'interp', 'EdgeColor', 'none', 'FaceAlpha', 0.5);
[~, hc] = contour(ax, gx, gy, gz, 9, 'LineColor', 0.6*S.INK + 0.4, 'LineWidth', 0.3); hc.ContourZLevel = z0 + 0.003*diff(lim);
ix = find(re);
if numel(ix) >= 2
    [uy, ~, ic] = unique(yr(ix)); tx = accumarray(ic, sT(ix), [], @mean); ty = accumarray(ic, sG(ix), [], @mean);
    if numel(uy) >= 2
        tf = linspace(min(uy), max(uy), 200); px = sm(uy, tx, tf); py = sm(uy, ty, tf); pz = pf(px, py); off = 0.006 * diff(lim);
        plot3(ax, px, py, pz + off, '-', 'Color', [1 1 1], 'LineWidth', 3.0);
        plot3(ax, px, py, pz + off, '-', 'Color', S.BRICK, 'LineWidth', 1.4);
        plot3(ax, px, py, (z0 + 0.004*diff(lim)) * ones(size(px)), '--', 'Color', S.BRICK, 'LineWidth', 0.8);
        cy = cmap_rgb(S.SEQ, (uy - min(uy)) / max(1, max(uy) - min(uy)));
        scatter3(ax, tx, ty, pf(tx, ty) + off, 14, cy, 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.5);
        for q = [1 numel(uy)]
            text(ax, tx(q), ty(q), pf(tx(q), ty(q)) + 0.10*diff(lim), sprintf('Year %d', uy(q)), 'FontSize', fz(7), 'Color', S.BRICK);
        end
    end
end
cb = cbar_(ax, S, S.TER, lim, 'Net value potential (10^4 CNY MW^{-1})');
set(ax, 'XLim', [min(sT) max(sT)], 'YLim', [min(sG) max(sG)], 'ZLim', [z0 - 0.01*diff(lim), lim(2) + 0.05*diff(lim)]);
xlabel(ax, 'Training saturation s_{W_T}', 'Color', S.INK); ylabel(ax, 'Green power saturation s_G', 'Color', S.INK); zlabel(ax, 'Net value potential (10^4 CNY MW^{-1})', 'Color', S.INK);
view(ax, -32, 32); shrink_cb(cb, 0.6);
savefig_(f, fd, 'N06_value_potential_terrain', true);
end

function N07(D, ~, S, ~, fd)
% 资产累计折现运营价值: 正负堆叠流 + 系统净值线
NY = D.NY; r = 0.08; disc = (1 + r) .^ -(1:NY)';
CF = D.CF / 10; CF(end+1:NY, :) = NaN; cum = cumsum(CF(1:NY, 1:6) .* disc, 1);
xs = linspace(1, NY, 281); f = newfig(S, 15.5, 10); ax = axes(f); style2(ax, S, true);
ax.Position = [0.11 0.12 0.70 0.82]; posb = zeros(size(xs)); negb = posb;
for k = [2 6 3 1 5 4]
    v = sm(1:NY, cum(:,k), xs); v(~isfinite(v)) = 0; p = max(v, 0); q = min(v, 0);
    patch(ax, [xs fliplr(xs)], [posb + p, fliplr(posb)], S.CA(k,:), 'FaceAlpha', 0.85, 'EdgeColor', 'none');
    plot(ax, xs, posb + p, '-', 'Color', [1 1 1], 'LineWidth', 0.7);
    patch(ax, [xs fliplr(xs)], [negb + q, fliplr(negb)], S.CA(k,:), 'FaceAlpha', 0.85, 'EdgeColor', 'none');
    plot(ax, xs, negb + q, '-', 'Color', [1 1 1], 'LineWidth', 0.7);
    if cum(end,k) >= 0; yl = posb(end) + p(end)/2; else; yl = negb(end) + q(end)/2; end
    text(ax, NY + 0.25, yl, sprintf('%s %+.1f', S.ASSETS{k}, cum(end,k)), 'FontSize', fz(7), 'Color', S.CA(k,:));
    posb = posb + p; negb = negb + q;
end
cum7 = cumsum(fillmissing(CF(1:NY, 1:min(7, size(CF, 2))), 'constant', 0) .* disc, 1);   % 净值与缺口计入直连光缆路由 R, 与表2一致
net = sm(1:NY, sum(cum7, 2), xs);
hn = plot(ax, xs, net, '-', 'Color', S.INK, 'LineWidth', 1.6); plot(ax, xs, net, ':', 'Color', [1 1 1], 'LineWidth', 0.6);
yline(ax, 0, '-', 'Color', S.INK, 'LineWidth', 0.6);
ce = cum7(end, :);
text(ax, 1.3, max(posb) * 0.92, {sprintf('Year %d net value %.1f', NY, sum(ce)), sprintf('Recovery gap %.1f', -sum(ce(ce < 0)))}, 'FontSize', fz(7.5), 'Color', S.SOFT, 'VerticalAlignment', 'top');
legend(ax, hn, 'System net value', 'Location', 'southwest', 'Box', 'off', 'FontSize', fz(7.5));
set(ax, 'XLim', [1 NY]); xlabel(ax, 'Planning year', 'Color', S.INK); ylabel(ax, 'Cumulative discounted operating value (billion CNY)', 'Color', S.INK);
savefig_(f, fd, 'N07_asset_value_stack', false);
end

function N08(D, ~, S, ~, fd)
% 边际学习力气泡矩阵: 颜色 = 边际学习力 ρ, 面积 = 次年投资速度
NY = D.NY; an = {'训练','推理','绿电','西储','东储','HVDC'}; mg = nan(NY, 6); C = D.cfm;
for rr = 2:size(C, 1)
    y = ynum(C{rr,1}); k = find(strcmp(an, cstr(C{rr,2})));
    if ~isempty(k) && y >= 1 && y <= NY; mg(y,k) = tonum(C{rr,4}); end
end
cu = D.wmb.c_unit(:)'; r = 0.08; L = [15 15 20 10 10 25]; AF = arrayfun(@(l) sum((1/(1+r)) .^ (0:l-1)), L);
rho = min(max(mg .* AF ./ cu(1:6) - 1, -2.5), 3.0); rho(~isfinite(mg)) = NaN;
K = [sum(D.WT,2) sum(D.WI,2) sum(D.G,2) sum(D.Ew,2) sum(D.Ee,2) D.dL];
vel = zeros(NY, 6); vel(1:end-1, :) = min(max(100 * diff(K, 1, 1) ./ max(K(1:end-1, :), 1e-6), 0), 80);
cn = nan(size(rho)); ng = rho < 0; ps = rho >= 0;
cn(ng) = 0.5 * (rho(ng) + 2.5) / 2.5; cn(ps) = 0.5 + 0.5 * rho(ps) / 3;   % 以0为中心的双斜率归一
f = newfig(S, 15, 8.5); ax = axes(f); style2(ax, S, false); ax.Position = [0.11 0.14 0.74 0.78];
for k = 1:6; plot(ax, [1 NY], [k k] - 1, '-', 'Color', S.GRID, 'LineWidth', 0.8); end
for k = 1:6
    ok = isfinite(cn(:,k)); yy = find(ok);
    if isempty(yy); continue; end
    scatter(ax, yy, (k-1) * ones(numel(yy), 1), 8 + 6.5 * vel(ok,k), cmap_rgb(S.DIV, cn(ok,k)), 'filled', ...
        'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.6);
end
set(ax, 'YTick', 0:5, 'YTickLabel', S.ASSETS, 'XTick', 1:NY, 'XLim', [0.4 NY + 0.6], 'YLim', [-0.7 6.6], 'TickLength', [0 0]);
setappdata(f, 'pf_after_fit', @() bubble_key_(ax, S));                % 气泡大小图例在版面定稿后绘制
try; ax.YRuler.Axle.LineStyle = 'none'; catch; end
xlabel(ax, 'Planning year', 'Color', S.INK);
cb = cbar_(ax, S, S.DIV, [0 1], 'Value learning force \rho'); tv = -2:3; tv0 = tv; tv0(tv < 0) = 0.5*(tv(tv < 0) + 2.5)/2.5; tv0(tv >= 0) = 0.5 + 0.5*tv(tv >= 0)/3;
cb.Ticks = tv0; cb.TickLabels = arrayfun(@(v) sprintf('%d', v), tv, 'Uni', 0);
savefig_(f, fd, 'N08_learning_force_bubbles', false);
end

function bubble_key_(ax, S)
% 气泡大小图例: 文字与气泡按实际字宽依次排开(间距以磅换算为数据长度), 在 fit_figure_text 收缩坐标区之后调用
yl = 6.0; vv = [10 30 60]; un = ax.Units; ax.Units = 'points'; pw = ax.Position(3); ax.Units = un; u = diff(ax.XLim) / pw;
t0 = text(ax, ax.XLim(1) + 0.2, yl, 'Investment speed', 'FontSize', fz(7), 'Color', S.INK); e = t0.Extent; x = e(1) + e(3) + 8 * u;
for q = 1:3
    r0 = sqrt(8 + 6.5 * vv(q)) / 2;                                    % 气泡半径(磅)
    scatter(ax, x + r0 * u, yl, 8 + 6.5 * vv(q), [0.79 0.81 0.82], 'filled', 'MarkerEdgeColor', [1 1 1]);
    t1 = text(ax, x + (2 * r0 + 3) * u, yl, sprintf('%d%%', vv(q)), 'FontSize', fz(7), 'Color', S.SOFT); e = t1.Extent; x = e(1) + e(3) + 8 * u;
end
end

function N09(D, ~, S, ~, fd)
% 投资速度–学习力联合分布: 二维核密度等值区 + 散点(大小随年份) + 边缘密度
C = D.inv; if isempty(C); error('缺少 investment_force_law.csv'); end
nm = {'训练','推理','绿电','HVDC'}; cs = [S.NAVY; S.TERRA; S.TEAL; S.OCHRE];
f = newfig(S, 15, 12);
ax  = axes(f, 'Position', [0.11 0.10 0.66 0.66]); style2(ax, S, true); ax.XGrid = 'on';
axt = axes(f, 'Position', [0.11 0.77 0.66 0.15]); hold(axt, 'on');
axr = axes(f, 'Position', [0.78 0.10 0.15 0.66]); hold(axr, 'on');
gxr = linspace(-2.6, 3.2, 200); gyv = linspace(0, 100, 200);
gx = linspace(-2.8, 3.3, 160); gy = linspace(-8, 108, 160); [gX, gY] = meshgrid(gx, gy); hs = gobjects(1, 4);
for a = 1:4
    rows = [];
    for rr = 2:size(C, 1); if strcmp(cstr(C{rr,2}), nm{a}); rows(end+1) = rr; end; end %#ok<AGROW>
    if isempty(rows); continue; end
    yrs = arrayfun(@(rr) ynum(C{rr,1}), rows); [~, o] = sort(yrs); rows = rows(o);
    fr0 = arrayfun(@(rr) tonum(C{rr,3}), rows); vv0 = 100 * arrayfun(@(rr) tonum(C{rr,4}), rows); tt = 0:numel(fr0)-1;
    ok = isfinite(fr0) & isfinite(vv0); fr = min(max(fr0, -2.5), 3); vv = min(max(vv0, 0), 100); fr = fr(ok); vv = vv(ok); tt = tt(ok);
    if isempty(fr); continue; end
    Z = zeros(size(gX));
    for i = 1:numel(fr); Z = Z + exp(-0.5 * (((gX - fr(i)) / 0.22).^2 + ((gY - vv(i)) / 7).^2)); end
    Z = Z / max(Z(:)); lev = [0.12 0.35 0.65]; al = [0.07 0.0645 0.1034]; lw = [0.5 0.7 0.9];   % 逐层叠加后为 0.07/0.13/0.22
    for j = 1:3; fill_contour(ax, gx, gy, Z, lev(j), cs(a,:), al(j)); end
    for j = 1:3; contour(ax, gx, gy, Z, [lev(j) lev(j)], 'LineColor', 0.75*cs(a,:) + 0.25, 'LineWidth', lw(j)); end
    hs(a) = scatter(ax, fr, vv, 10 + 2.2 * tt, cs(a,:), 'filled', 'MarkerFaceAlpha', 0.85, 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.5);
    d1 = kde1(fr, gxr, 0.5); patch(axt, [gxr fliplr(gxr)], [d1 zeros(size(d1))], cs(a,:), 'FaceAlpha', 0.15, 'EdgeColor', 'none');
    plot(axt, gxr, d1, '-', 'Color', cs(a,:), 'LineWidth', 1.0);
    d2 = kde1(vv, gyv, 0.5); patch(axr, [d2 zeros(size(d2))], [gyv fliplr(gyv)], cs(a,:), 'FaceAlpha', 0.15, 'EdgeColor', 'none');
    plot(axr, d2, gyv, '-', 'Color', cs(a,:), 'LineWidth', 1.0);
end
xline(ax, 0, '--', 'Color', S.LINE, 'LineWidth', 0.6);
set(ax, 'XLim', [-2.8 3.5], 'YLim', [-8 108]); set(axt, 'XLim', [-2.8 3.5]); set(axr, 'YLim', [-8 108]);
axis(axt, 'off'); axis(axr, 'off');
xlabel(ax, 'Previous-year value learning force \rho^{y-1}', 'Color', S.INK); ylabel(ax, 'Investment speed (%)', 'Color', S.INK);
v = isgraphics(hs);
if any(v)
    nmE = {'Training','Inference','Green power','HVDC'}; legend(ax, hs(v), nmE(v), 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(7.5));
end
savefig_(f, fd, 'N09_investment_force_joint', true);
end

function N10(D, ~, S, ~, fd)
% 前瞻修正热图(年份×资产: 前瞻−近视首年增量) + 顶部逐年前瞻价值 VoF
w = D.wmb; pl = w.plan; pm = w.plan_myo; NY = min([D.NY size(pl,1) size(pm,1) size(w.log,1)]);
dlt = 100 * (pl(1:NY, 1:6) - pm(1:NY, 1:6)); dlt(~isfinite(dlt)) = 0; lim = max(qtile(abs(dlt(:)), 0.96), 1e-6);
vof = w.log(1:NY, 4) / 10;
f = newfig(S, 15, 10);
ax = axes(f, 'Position', [0.10 0.12 0.72 0.58]); hold(ax, 'on');
axt = axes(f, 'Position', [0.10 0.73 0.72 0.19]); hold(axt, 'on');
for i = 1:NY
    for k = 1:6
        patch(ax, i + [-0.5 0.5 0.5 -0.5], (k-1) + [-0.5 -0.5 0.5 0.5], dlt(i,k), 'EdgeColor', [1 1 1], 'LineWidth', 1.2);
    end
end
colormap(ax, S.DIV); clim_(ax, [-lim lim]);
set(ax, 'YTick', 0:5, 'YTickLabel', S.ASSETS, 'XTick', 1:NY, 'XLim', [0.5 NY + 0.5], 'YLim', [-0.5 5.5], 'TickLength', [0 0], ...
    'Box', 'off', 'XColor', S.SOFT, 'YColor', S.SOFT, 'FontName', S.font, 'FontSize', fz(8));
try; ax.XRuler.Axle.LineStyle = 'none'; ax.YRuler.Axle.LineStyle = 'none'; catch; end
xlabel(ax, 'Planning year', 'Color', S.INK);
ok = isfinite(vof); y = (1:NY)';
if nnz(ok) >= 2
    xs = linspace(min(y(ok)), max(y(ok)), 200); vs = sm(y(ok), vof(ok), xs);
    patch(axt, [xs fliplr(xs)], [vs zeros(size(vs))], S.TEAL, 'FaceAlpha', 0.18, 'EdgeColor', 'none');
    plot(axt, xs, vs, '-', 'Color', S.TEAL, 'LineWidth', 1.2); scatter(axt, y(ok), vof(ok), 7, S.TEAL, 'filled');
    set(axt, 'YLim', [0 max(vof(ok)) * 1.15]);
end
set(axt, 'XLim', [0.5 NY + 0.5], 'XTick', [], 'XColor', 'none', 'YColor', S.SOFT, 'Box', 'off', 'FontName', S.font, 'FontSize', fz(6.5), 'TickDir', 'out');
ylabel(axt, 'VoF (billion CNY)', 'Color', S.INK, 'FontSize', fz(7));
cb = colorbar(ax, 'Position', [0.85 0.12 0.022 0.80]); cb.Color = S.SOFT; cb.FontSize = fz(6.5); cb.TickDirection = 'out';
cb.Label.String = 'Foresight minus myopic first-year increment (pp)'; cb.Label.Color = S.INK; cb.Label.FontSize = fz(8); try; cb.Box = 'off'; catch; end
savefig_(f, fd, 'N10_foresight_correction', false);
end

function N12(D, ~, S, ~, fd)
% 绿电去向运行变量相关结构(第5年 vs 末年, 逐小时): 下三角散点 | 对角核密度 | 上三角 Pearson r(末年) | 顶部平均联结聚类树
NY = D.NY; YB = NY; YA = min(5, NY - 1); if YA < 1; YA = 1; end
nm0 = {{'Western', 'green output'}, {'Training', 'load'}, {'HVDC', 'export'}, {'Cross-regional', 'service'}, {'Western', 'price'}, {'Eastern', 'price'}}; n = 6;   % 两行标注
VA = hvars(D, YA); VB = hvars(D, YB);
R = corrcoef(VB); R(~isfinite(R)) = 0;
[od, LK] = upgma(1 - abs(R)); nm = nm0(od);
cA = hex2rgb('#2E5A87'); cB = hex2rgb('#D0805F'); cc = hex2rgb('#F2F3F3');
RC = cmapn({'#C9714F', '#E7B9A2', '#F4F0EB', '#A9CFCB', '#3A8F8F'});
f = newfig(S, 16, 19); x0 = 0.26; y0 = 0.19; cw = 0.104; gp = 0.006;
st = RandStream('mt19937ar', 'Seed', 7); ia = randperm(st, size(VA, 1), min(600, size(VA, 1))); ib = randperm(st, size(VB, 1), min(600, size(VB, 1)));
axL = axes(f, 'Position', [0 0 1 1], 'Visible', 'off', 'XLim', [0 1], 'YLim', [0 1]); hold(axL, 'on');
for i = 1:n
    for j = 1:n
        ax = axes(f, 'Position', [x0 + (j-1)*(cw+gp), y0 + (n-i)*(cw+gp), cw, cw]); hold(ax, 'on');
        set(ax, 'XTick', [], 'YTick', [], 'XColor', 'none', 'YColor', 'none', 'Box', 'off', 'Color', cc);
        vi = od(i); vj = od(j);
        if i > j
            scatter(ax, VA(ia, vj), VA(ia, vi), 2, cA, 'filled', 'MarkerFaceAlpha', 0.55, 'MarkerEdgeColor', 'none');
            scatter(ax, VB(ib, vj), VB(ib, vi), 2, cB, 'filled', 'MarkerFaceAlpha', 0.55, 'MarkerEdgeColor', 'none');
            set(ax, 'XLim', padlim([VA(:, vj); VB(:, vj)]), 'YLim', padlim([VA(:, vi); VB(:, vi)]));
        elseif i == j
            g = linspace(min([VA(:, vi); VB(:, vi)]), max([VA(:, vi); VB(:, vi)]) + eps, 200); dm = 0;
            for q = 1:2
                if q == 1; V = VA; c = cA; else; V = VB; c = cB; end
                d = kde1(V(:, vi), g, 0.25); dm = max(dm, max(d));
                patch(ax, [g fliplr(g)], [d zeros(size(d))], c, 'FaceAlpha', 0.30, 'EdgeColor', 'none'); plot(ax, g, d, '-', 'Color', c, 'LineWidth', 1.0);
            end
            set(ax, 'XLim', [g(1) g(end)], 'YLim', [0 max(dm, eps) * 1.05]);
        else
            r = R(vi, vj); set(ax, 'Color', cmap_rgb(RC, (r + 1) / 2), 'XLim', [0 1], 'YLim', [0 1]);
            tc = S.INK; if abs(r) > 0.6; tc = [1 1 1]; end
            text(ax, 0.5, 0.5, sprintf('%.2f', r), 'HorizontalAlignment', 'center', 'FontSize', fz(8.5), 'Color', tc);
        end
    end
    text(axL, x0 - 0.012, y0 + (n-i)*(cw+gp) + cw/2, nm{i}, 'HorizontalAlignment', 'right', 'FontSize', fz(7.5), 'Color', S.SOFT);
    text(axL, x0 + (i-1)*(cw+gp) + cw/2, y0 - 0.012, nm{i}, 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'Rotation', 35, 'FontSize', fz(7.5), 'Color', S.SOFT);
end
% 聚类树(平均联结, 距离 = 1 − |r|)
axd = axes(f, 'Position', [x0, y0 + n*(cw+gp) + 0.01, n*(cw+gp) - gp, 0.11]); hold(axd, 'on'); axis(axd, 'off');
px = zeros(1, 2*n - 1); ph = zeros(1, 2*n - 1); px(od) = 1:n;
for m = 1:n-1
    a = LK(m,1); b = LK(m,2); h = LK(m,3); c = n + m; px(c) = (px(a) + px(b)) / 2; ph(c) = h;
    plot(axd, [px(a) px(a) px(b) px(b)], [ph(a) h h ph(b)], '-', 'Color', hex2rgb('#2F8A8C'), 'LineWidth', 1.4);
end
set(axd, 'XLim', [0.5 n + 0.5], 'YLim', [0 max(max(LK(:,3)), eps) * 1.05]);
% 色条与图例
cax = axes(f, 'Position', [0.24 0.045 0.30 0.012]);
image(cax, linspace(-1, 1, 256), [0 1], repmat(reshape(RC, 1, [], 3), 2, 1, 1));
set(cax, 'YTick', [], 'XLim', [-1 1], 'YDir', 'normal', 'XTick', -1:0.5:1, 'TickLength', [0 0], 'FontSize', fz(6.5), 'XColor', S.SOFT, 'YColor', 'none', 'Box', 'off', 'FontName', S.font);
xlabel(cax, sprintf('Pearson r (year %d)', YB), 'FontSize', fz(7), 'Color', S.INK);
scatter(axL, 0.645, 0.052, 40, cA, 'filled'); text(axL, 0.66, 0.052, sprintf('Year %d', YA), 'FontSize', fz(8), 'Color', S.INK);
scatter(axL, 0.785, 0.052, 40, cB, 'filled'); text(axL, 0.80, 0.052, sprintf('Year %d', YB), 'FontSize', fz(8), 'Color', S.INK);
setappdata(f, 'pf_nofit', true); savefig_(f, fd, 'N12_green_flow_correlation_matrix', true);
end

function V = hvars(D, y)
% 逐小时: 西部绿电出力 / 训练负荷 / HVDC外送 / 跨域服务承接(GW) / 西部电价 / 东部电价(元/MWh)
V = [[D.h_green(:,y), D.h_train(:,y), D.h_hv(:,y), D.h_mig(:,y) + D.h_boff(:,y)] / 1e3, D.h_pw(:,y), D.h_pe(:,y)];
end

function L = padlim(v)
v = v(isfinite(v)); if isempty(v); L = [0 1]; return; end
lo = min(v); hi = max(v); d = max(hi - lo, eps); L = [lo - 0.04*d, hi + 0.04*d];
end

function [order, LK] = upgma(Dm)
% 平均联结层次聚类(UPGMA): LK(m,:) = [簇a 簇b 高度 新簇号], 叶序与 scipy dendrogram 一致(左子在前)
n = size(Dm, 1); D2 = inf(2*n - 1); D2(1:n, 1:n) = Dm; D2(1:2*n:end) = inf;
sz = [ones(1, n) zeros(1, n - 1)]; act = [true(1, n) false(1, n - 1)]; mem = cell(1, 2*n - 1);
for k = 1:n; mem{k} = k; end
LK = zeros(n - 1, 4);
for m = 1:n-1
    idx = find(act); sub = D2(idx, idx); sub(1:numel(idx)+1:end) = inf;
    [h, p] = min(sub(:)); [ia, ib] = ind2sub(size(sub), p); a = idx(min(ia, ib)); b = idx(max(ia, ib)); c = n + m;
    LK(m,:) = [a b h c]; mem{c} = [mem{a} mem{b}]; sz(c) = sz(a) + sz(b); act([a b]) = false; act(c) = true;
    for q = find(act)
        if q == c; continue; end
        dq = (sz(a) * D2(a, q) + sz(b) * D2(b, q)) / sz(c); D2(c, q) = dq; D2(q, c) = dq;
    end
end
order = mem{2*n - 1};
end

function N13(D, ~, S, ~, fd)
% Benders 收敛曲面: x 迭代轮次, y 规划年份, z 上下界间隙(对数), 颜色 = 间隙; 各年终止后保持末轮间隙
NY = D.NY; nt = cellfun(@numel, D.gap); NI = max(nt); if NI < 2; error('无 gap_history'); end
G = nan(NY, NI);
for y = 1:NY
    g = max(D.gap{y}(:), 1e-4) * 100; n = numel(g); if n == 0; continue; end
    G(y, 1:n) = log10(g); G(y, n+1:end) = log10(g(end));
end
yy = find(all(isfinite(G), 2)); if numel(yy) < 2; error('有效年份不足'); end
xi = linspace(1, NI, 117); yi = linspace(min(yy), max(yy), 57);
A1 = interp1((1:NI)', G(yy, :)', xi')';                      % 年份×细分轮次
Gs = pchip(yy', A1', yi)'; [XX, YY] = meshgrid(xi, yi);        % 细分年份×细分轮次
[f, ax] = fig3(S, 16, 12.5); lim = [min(Gs(:)) max(Gs(:))];
surf(ax, XX, YY, Gs, Gs, 'FaceColor', 'interp', 'EdgeColor', [0.10 0.10 0.15], 'EdgeAlpha', 0.22, 'LineWidth', 0.12);
cb = cbar_(ax, S, S.VIR, lim, 'Bound gap (%)');
tk = log10([1 3 10 30 100 300]); tk = tk(tk >= lim(1) & tk <= lim(2));
if ~isempty(tk); cb.Ticks = tk; cb.TickLabels = arrayfun(@(t) sprintf('%g', 10^t), tk, 'Uni', 0); end
zlo = min(log10(0.5), lim(1) - 0.05); zhi = max(log10(400), lim(2) + 0.05);
zt = log10([0.1 1 10 100 1000]); zt = zt(zt >= zlo & zt <= zhi);
set(ax, 'XLim', [1 NI], 'YLim', [min(yy) max(yy)], 'ZLim', [zlo zhi], 'ZTick', zt, 'ZTickLabel', arrayfun(@(t) sprintf('%g', 10^t), zt, 'Uni', 0));
xlabel(ax, 'Iteration', 'Color', S.INK); ylabel(ax, 'Planning year', 'Color', S.INK); zlabel(ax, 'Bound gap (%)', 'Color', S.INK);
view(ax, 125, 26); shrink_cb(cb, 0.6);
savefig_(f, fd, 'N13_benders_convergence_surface', true);
end

%% ═══════════════════════════════ 国家地图仿真图 ═══════════════════════════════
function M1(D, ~, S, MP, fd)
% 算力任务流网络: 东部推理节点 → 西部训练节点(B+C类, 百万token), 每条流线 = 一个规划年份
if ~MP.ok; error('无底图数据(map_data)'); end
TK = merge_edges([edge_layer(D.edge, 'task_B', 9); edge_layer(D.edge, 'task_C', 9)]);
if isempty(TK); error('ahm_graph_edges.csv 无任务流'); end
[f, ax] = mapfig(S, MP, 17, 13.5);
CM = edge_layer(D.edge, 'comm', 8); hl = gobjects(0); tl = {};
if ~isempty(CM)
    yl = max(CM(:,1)); CM = CM(CM(:,1) == yl & CM(:,4) >= 1, :);
    for q = 1:size(CM, 1)
        p0 = MP.nxy(CM(q,2), :); p1 = MP.nxy(CM(q,3), :);
        plot(ax, [p0(1) p1(1)], [p0(2) p1(2)], ':', 'Color', S.GRAY, 'LineWidth', 0.7);
    end
    hl(end+1) = plot(ax, NaN, NaN, ':', 'Color', S.GRAY, 'LineWidth', 0.7); tl{end+1} = sprintf('Direct fibre routes, year %d', yl);
end
lim = flowlines(ax, S, MP, TK, true, []);
map_nodes(ax, S, MP, [D.WT(end,:) D.WI(end,:)], 'MW');
level_legend(ax, S, MP, 'Computing capacity (MW)'); nanhai_inset(ax, S, MP); gs_note(ax, S, MP);
hl(end+1) = plot(ax, NaN, NaN, '-', 'Color', cmap_rgb(S.FLOW, 0.8), 'LineWidth', 0.8);
tl{end+1} = 'One arc per planning year';
legend(ax, hl, tl, 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(6.5));
hbar_(f, ax, S, S.FLOW, lim, {'Task flow', '(million tokens)'}, true);
setappdata(f, 'pf_nofit', true); savefig_(f, fd, 'M1_compute_task_flow_map', true);
end

function M2(D, ~, S, MP, fd)
% 西电东送通道网络: HVDC 逐年通道容量流线, 节点 = 外送/受入通道总容量
if ~MP.ok; error('无底图数据(map_data)'); end
HV = merge_edges(edge_layer(D.edge, 'hvdc', 8)); if isempty(HV); error('ahm_graph_edges.csv 无HVDC边'); end
[f, ax] = mapfig(S, MP, 17, 13.5);
lim = flowlines(ax, S, MP, HV, false, 0);
yl = max(HV(:,1)); cap = zeros(1, 7);
for k = 1:7; m = HV(:,1) == yl & (HV(:,2) == k | HV(:,3) == k); cap(k) = sum(HV(m, 4)); end
map_nodes(ax, S, MP, cap, 'MW');
level_legend(ax, S, MP, 'HVDC capacity (MW)'); nanhai_inset(ax, S, MP); gs_note(ax, S, MP);
hl = plot(ax, NaN, NaN, '-', 'Color', cmap_rgb(S.FLOW, 0.8), 'LineWidth', 0.8);
legend(ax, hl, 'One arc per planning year', 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(6.5));
hbar_(f, ax, S, S.FLOW, lim, {'HVDC corridor', 'capacity (MW)'}, false);
setappdata(f, 'pf_nofit', true); savefig_(f, fd, 'M2_hvdc_corridor_map', true);
end

function M3(D, ~, S, MP, fd)
% 跨网价值流网络: 西部训练 → 东部推理(万元), 每条流线 = 一个规划年份
if ~MP.ok; error('无底图数据(map_data)'); end
VL = merge_edges(edge_layer(D.edge, 'value', 9)); if isempty(VL); error('ahm_graph_edges.csv 无价值流'); end
[f, ax] = mapfig(S, MP, 17, 13.5);
lim = flowlines(ax, S, MP, VL, true, []);
map_nodes(ax, S, MP, [D.WT(end,:) D.WI(end,:)], 'MW');
level_legend(ax, S, MP, 'Computing capacity (MW)'); nanhai_inset(ax, S, MP); gs_note(ax, S, MP);
hl = plot(ax, NaN, NaN, '-', 'Color', cmap_rgb(S.FLOW, 0.8), 'LineWidth', 0.8);
legend(ax, hl, 'One arc per planning year', 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(6.5));
hbar_(f, ax, S, S.FLOW, lim, {'Cross-network value', 'flow (10^4 CNY)'}, true);
setappdata(f, 'pf_nofit', true); savefig_(f, fd, 'M3_cross_grid_value_map', true);
end

function M4(D, ~, S, MP, fd)
% 算力流时空立方体: x,y = 地图(东数西算区域), z = 规划年份, 颜色 = 任务流强度; 竖柱点大小 = 当年节点容量
if ~MP.ok; error('无底图数据(map_data)'); end
TK = merge_edges([edge_layer(D.edge, 'task_B', 9); edge_layer(D.edge, 'task_C', 9)]); TK = TK(TK(:,4) > 0, :);
if isempty(TK); error('ahm_graph_edges.csv 无任务流'); end
nx = MP.nxy; e = MP.ext; c0 = [e(1) e(3)] - 80; c1 = [MP.xr e(4)] + 80; NY = D.NY;   % 底面 = 全国地图(含南海诸岛框)
[f, ax] = fig3(S, 17, 15);
patch_polys(ax, MP.pxy, S.LAND, MP.pedge, 0.5, 0); draw_bnd(ax, MP, 0); nanhai_inset(ax, S, MP, 0);
plot3(ax, [c0(1) c1(1) c1(1) c0(1) c0(1)], [c0(2) c0(2) c1(2) c1(2) c0(2)], zeros(1, 5), '-', 'Color', [0.80 0.83 0.85], 'LineWidth', 0.45);
v = log10(TK(:,4)); lo = qtile(v, 0.02); hi = max(v); [~, o] = sort(v); t = linspace(0, 1, 80)';
for q = o'
    a = TK(q,2); b = TK(q,3); Q = bez(nx(a,:), nx(b,:), 0.14 * (2*(a <= 4) - 1), 80);
    s = min(max((v(q) - lo) / max(hi - lo, eps), 0), 1);
    plot3(ax, Q(:,1), Q(:,2), TK(q,1) + 0.42 * sin(pi * t), '-', 'Color', [cmap_rgb(S.FLOW, s) 0.9], 'LineWidth', 0.25 + 1.5 * s^1.5);
end
for k = 1:7
    if k <= 4; cap = D.WT(:,k); col = S.LEVEL(4,:); else; cap = D.WI(:,k-4); col = S.LEVEL(2,:); end
    x = nx(k,1); y = nx(k,2);
    plot3(ax, [x x], [y y], [0 NY + 0.4], '-', 'Color', [S.SOFT 0.7], 'LineWidth', 0.5);
    scatter3(ax, x * ones(NY, 1), y * ones(NY, 1), (1:NY)', 3 + 55 * max(cap, 0) / 3300, col, 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.4);
    scatter3(ax, x, y, 0, 14, S.INK, 'filled');
    ha = {'center', 'right', 'center', 'center', 'left', 'center', 'center'};                     % 甘肃左、京津冀右, 避免与宁夏/内蒙古重叠
    text(ax, x, y, NY + 1.0, MP.nabbr{k}, 'FontSize', fz(6.5), 'Color', S.INK, 'HorizontalAlignment', ha{k});
end
h1 = scatter3(ax, NaN, NaN, NaN, 30, S.LEVEL(4,:), 'filled', 'MarkerEdgeColor', [1 1 1]);
h2 = scatter3(ax, NaN, NaN, NaN, 30, S.LEVEL(2,:), 'filled', 'MarkerEdgeColor', [1 1 1]);
lg = legend(ax, [h1 h2], {'Western training hubs', 'Eastern inference hubs'}, 'Location', 'northwest', 'Box', 'off', 'FontSize', fz(6.5));
lg.Title.String = 'Marker size: capacity'; lg.Title.FontWeight = 'normal'; lg.Title.FontSize = fz(6.5);
cb = cbar_(ax, S, S.FLOW, [lo hi], 'Task flow (million tokens)');
tk = ceil(lo):floor(hi); if ~isempty(tk); cb.Ticks = tk; cb.TickLabels = arrayfun(@(u) sprintf('10^{%d}', u), tk, 'Uni', 0); end
set(ax, 'XLim', [c0(1) c1(1)], 'YLim', [c0(2) c1(2)], 'ZLim', [0 NY + 2.2], 'XTick', [], 'YTick', [], ...
    'ZTick', unique([1 5:5:NY NY]), 'XGrid', 'off', 'YGrid', 'off', 'ZGrid', 'on', 'XColor', 'none', 'YColor', 'none');
pbaspect(ax, [c1(1) - c0(1), c1(2) - c0(2), 0.45 * (c1(1) - c0(1))]);
if ~isempty(MP.gs); annotation(f, 'textbox', [0.50 0.005 0.48 0.04], 'String', ['Map approval No. ' MP.gs], 'EdgeColor', 'none', ...
        'HorizontalAlignment', 'right', 'FontSize', fz(6, true), 'Color', S.SOFT, 'FontName', S.font); end
zlabel(ax, 'Planning year', 'Color', S.INK); view(ax, -8, 24);                                % 该方位角下7根竖柱在屏幕上两两相距 ≥ 160 km, 互不遮挡 shrink_cb(cb, 0.5);
savefig_(f, fd, 'M4_space_time_flow_cube', true);
end

%% ═══════════════════════════════ 数据读取 ═══════════════════════════════
function D = load_all(out_dir)
D = struct('NY', 0);
[D.CF, D.NPVa] = read_recovery(fullfile(out_dir, 'asset_recovery.csv'));
D.cfm  = rdcell(fullfile(out_dir, 'counterfactual_marginal.csv'));
D.inv  = rdcell(fullfile(out_dir, 'investment_force_law.csv'));
D.edge = rdcell(fullfile(out_dir, 'ahm_graph_edges.csv'));
D.wmb = []; fn = fullfile(out_dir, 'wm_buffer.mat');
if exist(fn, 'file'); t = load(fn, 'wmb'); D.wmb = t.wmb; end
fn = fullfile(out_dir, 'checkpoint', 'ckpt_latest.mat'); if ~exist(fn, 'file'); return; end
t = load(fn, 'results_yearly'); RY = t.results_yearly; if ~iscell(RY); RY = num2cell(RY); end
RY = RY(~cellfun(@isempty, RY)); NY = numel(RY); D.NY = NY;
z4 = zeros(NY, 4); z3 = zeros(NY, 3); z1 = zeros(NY, 1); H = zeros(8760, NY);
D.WT = z4; D.WI = z3; D.G = z4; D.Ew = z4; D.Ee = z3; D.dL = z1; D.dem = z4;
D.pR = z1; D.pB = z1; D.pT = z1; D.eta = z1; D.LB = cell(NY, 1); D.gap = cell(NY, 1);
D.av = z1; D.rn = z1; D.hv = z1; D.curt = z1; D.mig = z1; D.pboff = z1;
D.nAv = z4; D.nLoc = z4; D.nHv = z4; D.nMig = z4;                     % 西部分节点: 可发绿电/本地训练消纳/HVDC外送/承接迁移
D.h_train = H; D.h_green = H; D.h_pw = H; D.h_pe = H; D.h_mig = H; D.h_boff = H; D.h_hv = H;
for y = 1:NY
    R = RY{y}; st = R.state; a = R.actual; b = R.ben_info;
    D.WT(y,:) = st.W_T_cum(:)'; D.WI(y,:) = st.W_I_cum(:)'; D.G(y,:) = st.G_cum(:)';
    D.Ew(y,:) = st.E_w_cum(:)'; D.Ee(y,:) = st.E_e_cum(:)'; D.dL(y) = sum(st.dL_cum(:));
    if isfield(R, 'demand_y') && ~isempty(R.demand_y)
        dy = R.demand_y; if size(dy, 1) ~= 4 && size(dy, 2) == 4; dy = dy'; end
        D.dem(y,:) = mean(dy, 2)';
    end
    if isfield(b, 'SKU')
        k = b.SKU; D.pR(y) = mean(getf(k, 'p_R', NaN)); D.pB(y) = mean(getf(k, 'p_B', NaN));
        D.pT(y) = mean(getf(k, 'p_T', NaN)); D.eta(y) = getf(k, 'eta_token', NaN);
    end
    D.LB{y} = getf(b, 'LB_history', []); D.gap{y} = getf(b, 'gap_history', []);
    n = min(8760, size(a.P_train, 1)); G = st.G_cum(:)';
    gr = sum((a.cf_wind(1:n, 1:4) + a.cf_pv(1:n, 1:4)) / 2 .* G, 2);
    D.h_train(1:n, y) = sum(a.P_train(1:n, :), 2); D.h_green(1:n, y) = gr;
    D.h_pw(1:n, y) = mean(a.price(1:n, 1:4), 2); D.h_pe(1:n, y) = mean(a.price(1:n, 5:end), 2);
    D.h_mig(1:n, y) = sum(a.P_mig_run(1:n, :), 2); D.h_boff(1:n, y) = sum(a.P_Boff(1:n, :), 2); D.h_hv(1:n, y) = sum(a.P_hvdc(1:n, :), 2);
    D.av(y) = sum(gr); D.rn(y) = sum(a.P_renew(:)); D.hv(y) = sum(a.P_hvdc(:)); D.curt(y) = sum(a.P_curt(:));
    D.mig(y) = sum(a.P_mig_run(:)); D.pboff(y) = sum(a.P_Boff(:));
    D.nAv(y,:) = sum((a.cf_wind(1:n, 1:4) + a.cf_pv(1:n, 1:4)) / 2 .* G, 1); D.nLoc(y,:) = sum(a.P_renew(1:n, 1:4), 1);
    D.nHv(y,:) = sum(a.P_hvdc(1:n, 1:4), 1); D.nMig(y,:) = sum(a.P_mig_run(1:n, 1:4), 1) + sum(a.P_Boff(1:n, 1:4), 1);
end
end

function [CF, NPVa] = read_recovery(fn)
CF = nan(0, 7); NPVa = nan(1, 7); C = rdcell(fn); if isempty(C); return; end
for r = 2:size(C, 1)
    s = cstr(C{r,1}); v = nan(1, 7); m = min(8, size(C, 2));
    for c = 2:m; v(c-1) = tonum(C{r,c}); end
    if startsWith(s, 'Y'); y = ynum(s); if isfinite(y) && y >= 1; CF(y,:) = v; end
    elseif startsWith(s, 'NPV'); NPVa = v; end
end
end

function L = edge_layer(E, typ, col)
% 异质图边 → [年份, 起点, 终点, 值]; 节点序: 1–4 西部(NM GS NX GZ), 5–7 东部(BJ SH GZh)
L = zeros(0, 4); if isempty(E); return; end
for r = 2:size(E, 1)
    if ~strcmp(cstr(E{r,2}), typ); continue; end
    y = ynum(E{r,1}); a = node_id(E{r,4}); b = node_id(E{r,6}); v = tonum(E{r,col});
    if ~isfinite(y) || isempty(a) || isempty(b) || ~isfinite(v); continue; end
    L(end+1, :) = [y a b v]; %#ok<AGROW>
end
end

function L = merge_edges(L)
if isempty(L); L = zeros(0, 4); return; end
[u, ~, ic] = unique(L(:, 1:3), 'rows'); L = [u accumarray(ic, L(:,4))];
end

function k = node_id(s)
s = string(cstr(s)); names = ["NM","GS","NX","GZ","BJ","SH","GZh"]; bus = ["5","12","23","38","81","95","107"];
k = find(names == s, 1); if isempty(k); k = find(bus == s, 1); end
end

%% ═══════════════════════════════ 地图工具 ═══════════════════════════════
function MP = map_load(root)
% 底图优先级(map_data/ 下):
%   1) 中国_省.geojson 或 tianditu_province.geojson —— 天地图“行政区划可视化”省级数据, 审图号 GS(2024)0650号(投稿用)
%      数据自带南海诸岛与断续线: 主图绘至海南岛最南端, 南海诸岛与断续线按真实数据(同一投影)缩绘入“南海诸岛”附图, 图中标注审图号
%   2) china_provinces.geojson + china_outline.geojson —— ECharts 4.9 简化数据(无审图号, 仅供预览), 附图为示意
% 经纬度 → Albers 等积圆锥投影(中央经线 105°E, 标准纬线 25°N/47°N, km); 边界坐标不做任何简化或改动
MP = struct('ok', false); d = fullfile(root, 'map_data');
ft = {fullfile(d, '中国_省.geojson'), fullfile(d, 'tianditu_province.geojson')};
f1 = fullfile(d, 'china_provinces.geojson'); f2 = fullfile(d, 'china_outline.geojson');
it = find(cellfun(@(q) exist(q, 'file') > 0, ft), 1); ol = {}; L = {}; B = {};
if ~isempty(it)
    [pr, L, B] = geo_rings_file(ft{it}); MP.src = 'tianditu'; MP.gs = 'GS(2024)0650';
    fprintf('[地图] 底图: %s (天地图, 审图号 %s)\n', ft{it}, MP.gs);
elseif exist(f1, 'file')
    pr = geo_rings_file(f1); if exist(f2, 'file'); ol = geo_rings_file(f2); end
    MP.src = 'echarts'; MP.gs = '';
    fprintf('[地图] 未找到 map_data/中国_省.geojson, 使用 ECharts 简化底图(仅供预览, 投稿前请换成天地图数据)\n');
else
    fprintf('[地图] map_data 下无底图数据, 跳过地图仿真图\n'); return;
end
LATC = 17.5;                                                          % 主图南界: 含海南岛最南端(约 18.1°N)
mainf = @(C) C(cellfun(@(p) max(p(:,2)) >= LATC, C));
MP.real = any(cellfun(@(p) max(p(:,2)) < LATC, [B, L]));              % 数据自带断续线(境界线要素) → 附图用真实数据, 否则用示意
prm = mainf(pr); if isempty(prm); fprintf('[地图] 底图中未解析到多边形, 跳过地图仿真图\n'); return; end
latS = min(cellfun(@(p) min(p(:,2)), prm));                           % 主图陆地最南端(海南岛南端)
mainl = @(C) C(cellfun(@(p) min(p(:,2)) >= latS - 0.05, C));          % 主图只画完全位于其北的界线段, 其余(南海断续线)进附图
MP.pxy = cellfun(@prj_ring, prm, 'Uni', 0); MP.bxy = cellfun(@prj_ring, mainl(B), 'Uni', 0);
MP.lxy = cellfun(@prj_line, mainl(L), 'Uni', 0); MP.oxy = cellfun(@prj_ring, ol, 'Uni', 0); MP.pedge = [1 1 1];
ne = @(C) C(~cellfun(@isempty, C));
MP.pxy = ne(MP.pxy); MP.bxy = ne(MP.bxy); MP.lxy = ne(MP.lxy); MP.oxy = ne(MP.oxy);
if isempty(MP.pxy); fprintf('[地图] 底图中未解析到多边形, 跳过地图仿真图\n'); return; end
if isempty(ol)                                                        % 无单独轮廓文件: 只属于一个省的边 = 国界/海岸线
    [MP.oxy, fr] = outline_edges(MP.pxy);
    if fr < 0.3; MP.oxy = {}; MP.pedge = [0.78 0.81 0.83]; end         % 省界顶点不共用时无法提取外轮廓: 省界与海岸线统一用浅灰
end
A = vertcat(MP.pxy{:}, MP.bxy{:}, MP.lxy{:}); MP.ext = [min(A(:,1)) max(A(:,1)) min(A(:,2)) max(A(:,2))];
MP.nanhai = true;   % 横版 + “南海诸岛”附图; 改为竖版(南海诸岛画在主图中)时设为 false 并把上面 LATC 改为 0
W = MP.ext(2) - MP.ext(1); H = MP.ext(4) - MP.ext(3); Bd = A(A(:,2) <= MP.ext(3) + 0.21 * H, :);   % 南部条带(含海南、台湾、界线)
MP.nh = [max(Bd(:,1)) + 0.02 * W, MP.ext(3) + 0.01 * H, 0.12 * W, 0.19 * H];   % 附图框 [x0 y0 w h]: 台湾以东, 不压盖任何陆地与界线
MP.xr = MP.ext(2); if MP.nanhai; MP.xr = max(MP.ext(2), MP.nh(1) + MP.nh(3)); end
MP.ipoly = {}; MP.ibnd = {}; MP.iline = {}; MP.iwin = [];
if MP.real                                                            % 附图范围 105.5–126.5°E, 2.5–24.5°N(含曾母暗沙、黄岩岛、东沙群岛; 东南留白放名称与比例尺)
    WIN = [105.5 126.5 2.5 24.5]; t = linspace(0, 1, 60); o = ones(1, 60);
    [wx, wy] = albers([WIN(1) + (WIN(2) - WIN(1)) * t, WIN(2) * o, WIN(2) - (WIN(2) - WIN(1)) * t, WIN(1) * o], ...
                      [WIN(3) * o, WIN(3) + (WIN(4) - WIN(3)) * t, WIN(4) * o, WIN(4) - (WIN(4) - WIN(3)) * t]);
    R0 = [min(wx) max(wx) min(wy) max(wy)];
    a = MP.nh(4) / MP.nh(3); rx = R0(2) - R0(1); ry = R0(4) - R0(3);    % 扩展到与附图框同宽高比, 裁剪边恰好落在框线上
    if ry / rx < a; dy = (a * rx - ry) / 2; R0(3:4) = R0(3:4) + [-dy dy]; else; dx = (ry / a - rx) / 2; R0(1:2) = R0(1:2) + [-dx dx]; end
    MP.iwin = R0; inr = @(q) ~isempty(q) && any(q(:,1) >= R0(1) & q(:,1) <= R0(2) & q(:,2) >= R0(3) & q(:,2) <= R0(4));
    for k = 1:numel(pr)
        q = prj_ring(pr{k}); if inr(q); q = clip_rect(q, R0(1), R0(2), R0(3), R0(4)); if ~isempty(q); MP.ipoly{end+1} = q; end; end
    end
    for k = 1:numel(B)
        q = prj_ring(B{k}); if inr(q); q = clip_rect(q, R0(1), R0(2), R0(3), R0(4)); if ~isempty(q); MP.ibnd{end+1} = q; end; end
    end
    for k = 1:numel(L)
        q = prj_line(L{k}); if inr(q); MP.iline = [MP.iline, clip_line(q, R0)]; end
    end
end
MP.nname = {'Inner Mongolia', 'Gansu', 'Ningxia', 'Guizhou', 'Beijing-Tianjin-Hebei', 'Yangtze River Delta', 'Greater Bay Area'};
MP.nabbr = {'IM', 'GS', 'NX', 'GZ', 'BTH', 'YRD', 'GBA'};                % 图上标注用缩写, 全称见图注
% 节点坐标取省会/区域中心城市: 呼和浩特 兰州 银川 贵阳 | 北京 上海 广州
ll = [111.75 40.84; 103.83 36.06; 106.23 38.49; 106.63 26.65; 116.40 39.90; 121.47 31.23; 113.26 23.13];
[x, y] = albers(ll(:,1), ll(:,2)); MP.nxy = [x y];
MP.loff = [-1 1; -1 -1; -1 1; -1 -1; 1 1; 1 0; 1 -1];    % 标注方向
MP.ok = true;
end

function [R, L, B] = geo_rings_file(fn)
% GeoJSON → 面 R(省级行政区, 含岛屿)、线 L(LineString 要素, 如天地图“境界线”)、境界面 B(名为“境界线”或 adchar=JD 的面要素)
R = {}; L = {}; B = {}; J = jsondecode(fileread(fn)); F = J.features; if ~iscell(F); F = num2cell(F); end
for k = 1:numel(F)
    if ~isfield(F{k}, 'geometry') || isempty(F{k}.geometry); continue; end
    g = F{k}.geometry; ty = ''; if isfield(g, 'type'); ty = char(string(g.type)); end
    nm = '';
    if isfield(F{k}, 'properties') && isstruct(F{k}.properties)
        p = F{k}.properties;
        if isfield(p, 'name') && ~isempty(p.name); nm = char(string(p.name)); end
        if isfield(p, 'adchar') && ~isempty(p.adchar) && strcmpi(char(string(p.adchar)), 'JD'); nm = '境界线'; end
    end
    if contains(ty, 'LineString')
        L = [L, rings_of(g.coordinates, 2)]; %#ok<AGROW>
    elseif contains(nm, '境界线')
        B = [B, rings_of(g.coordinates, 3)]; %#ok<AGROW>
    else
        R = [R, rings_of(g.coordinates, 3)]; %#ok<AGROW>
    end
end
end

function R = rings_of(c, nmin)
if nargin < 2; nmin = 3; end
R = {};
if iscell(c)
    for k = 1:numel(c); R = [R, rings_of(c{k}, nmin)]; end %#ok<AGROW>
elseif isnumeric(c) && ~isempty(c)
    s = size(c);
    if numel(s) == 2 && s(2) >= 2                               % N×2 或 N×3(含高程)
        if s(1) >= nmin; R = {double(c(:, 1:2))}; end
    elseif s(end) >= 2
        n = s(end-1); A = reshape(double(c), [], n, s(end)); A = A(:, :, 1:2);
        for k = 1:size(A, 1); if n >= nmin; R{end+1} = [reshape(A(k,:,1), [], 1) reshape(A(k,:,2), [], 1)]; end; end %#ok<AGROW>
    end
end
end

function q = prj_ring(p)
[x, y] = albers(p(:,1), p(:,2)); q = [x y]; q = q(all(isfinite(q), 2), :); if size(q, 1) < 3; q = []; end
end

function q = prj_line(p)
[x, y] = albers(p(:,1), p(:,2)); q = [x y]; q = q(all(isfinite(q), 2), :); if size(q, 1) < 2; q = []; end
end

function [O, fr] = outline_edges(P)
% 国界/海岸线: 相邻省份共用的边出现两次, 只出现一次的边即外轮廓; 返回 NaN 分隔的折线
n = sum(cellfun(@(p) size(p, 1), P)); E = zeros(n, 4); m = 0;
for k = 1:numel(P)
    p = P{k}; if any(p(1,:) ~= p(end,:)); p(end+1,:) = p(1,:); end %#ok<AGROW>
    r = size(p, 1) - 1; E(m+1:m+r, :) = [p(1:end-1,:) p(2:end,:)]; m = m + r;
end
E = E(1:m, :); a = round(E(:,1:2) * 1e3); b = round(E(:,3:4) * 1e3);          % 量化到 1 m
sw = a(:,1) > b(:,1) | (a(:,1) == b(:,1) & a(:,2) > b(:,2)); K = [a b]; K(sw,:) = [b(sw,:) a(sw,:)];
[~, ~, ic] = unique(K, 'rows'); cnt = accumarray(ic, 1); S = E(cnt(ic) == 1, :); fr = mean(cnt(ic) >= 2);
X = [S(:,1) S(:,3) nan(size(S, 1), 1)]'; Y = [S(:,2) S(:,4) nan(size(S, 1), 1)]'; O = {[X(:) Y(:)]};
end

function P = clip_line(q, R0)
% 折线按矩形裁剪: 保留落在矩形内的连续顶点段
P = {}; if isempty(q); return; end
in = q(:,1) >= R0(1) & q(:,1) <= R0(2) & q(:,2) >= R0(3) & q(:,2) <= R0(4);
dd = diff([0; in; 0]); s = find(dd == 1); e = find(dd == -1) - 1;
for k = 1:numel(s); if e(k) > s(k); P{end+1} = q(s(k):e(k), :); end; end %#ok<AGROW>
end

function [x, y] = albers(lon, lat)
% Albers 等积圆锥投影: 中央经线 105°E, 标准纬线 25°N/47°N, 单位 km
R = 6371; d = pi/180; l0 = 105*d; p1 = 25*d; p2 = 47*d;
n = (sin(p1) + sin(p2)) / 2; C = cos(p1)^2 + 2*n*sin(p1); rho0 = R * sqrt(C) / n;
rho = R * sqrt(C - 2*n*sin(lat*d)) / n; th = n * (lon*d - l0);
x = rho .* sin(th); y = rho0 - rho .* cos(th);
end

function [f, ax] = mapfig(S, MP, w, h)
f = newfig(S, w, h); ax = axes(f, 'Position', [0.01 0.01 0.98 0.98]); hold(ax, 'on');
set(ax, 'SortMethod', 'childorder');                                   % 按绘制顺序叠放: 南海附图最后画, 位于最上层
patch_polys(ax, MP.pxy, S.LAND, MP.pedge, 0.55);
for k = 1:numel(MP.oxy); plot(ax, MP.oxy{k}(:,1), MP.oxy{k}(:,2), '-', 'Color', S.COAST, 'LineWidth', 0.7); end
draw_bnd(ax, MP, []);
e = MP.ext; W = e(2) - e(1); yb = 60 + 110 * ~isempty(MP.gs);          % 有审图号时底部留出标注位置
axis(ax, 'equal'); axis(ax, 'off'); set(ax, 'XLim', [e(1) MP.xr] + [-60 60], 'YLim', [e(3) - yb, e(4) + 60]);
S.halo_ = 0.0018 * W; setappdata(ax, 'halo', S.halo_);
end

function draw_bnd(ax, MP, z)
% 境界线要素(国界、断续线): 面要素填充, 线要素描线; z 给定时绘于三维底面
BC = [0.42 0.47 0.51];
if isempty(z); patch_polys(ax, MP.bxy, BC, BC, 0.4); else; patch_polys(ax, MP.bxy, BC, BC, 0.4, z); end
for k = 1:numel(MP.lxy); line_z(ax, MP.lxy{k}(:,1), MP.lxy{k}(:,2), z, BC, 0.8); end
end

function gs_note(ax, S, MP)
% 审图号(右下角, 附图下方)
if isempty(MP.gs); return; end
text(ax, MP.xr + 55, MP.ext(3) - 155, sprintf('Map approval No. %s', MP.gs), 'HorizontalAlignment', 'right', ...
    'VerticalAlignment', 'bottom', 'FontSize', fz(5.5, true), 'Color', S.SOFT);
end

function nanhai_inset(ax, S, MP, z)
% “南海诸岛”附图: 位于台湾以东空白海域; 数据自带南海诸岛/断续线时按真实数据(同一投影)缩绘并加比例尺, 否则为示意
% 二维图在最后调用, 保证附图不被流线/节点/标注压盖; z 给定时绘于三维底面 z 上(M4)
if ~MP.nanhai; return; end
if nargin < 4; z = []; end
x0 = MP.nh(1); y0 = MP.nh(2); w = MP.nh(3); h = MP.nh(4); c = [0.42 0.47 0.51];
patch_z(ax, [x0 x0+w x0+w x0]', [y0 y0 y0+h y0+h]', z, [1 1 1], S.COAST, 0.6);
if MP.real
    R0 = MP.iwin; s = w / (R0(2) - R0(1)); ox = x0; oy = y0;              % 附图窗口与框同宽高比, 按框宽缩放
    for k = 1:numel(MP.ipoly); q = MP.ipoly{k}; patch_z(ax, ox + s * (q(:,1) - R0(1)), oy + s * (q(:,2) - R0(3)), z, S.LAND, S.COAST, 0.3); end
    for k = 1:numel(MP.ibnd);  q = MP.ibnd{k};  patch_z(ax, ox + s * (q(:,1) - R0(1)), oy + s * (q(:,2) - R0(3)), z, c, c, 0.3); end
    for k = 1:numel(MP.iline); q = MP.iline{k}; line_z(ax, ox + s * (q(:,1) - R0(1)), oy + s * (q(:,2) - R0(3)), z, c, 0.7); end
    if isempty(z)                                                     % 附图比例尺 500 km(名称上方, 右对齐; 三维底面上省略)
        sb = 500 * s; xb = x0 + 0.96 * w - sb; yb = y0 + 0.16 * h;
        line_z(ax, [xb xb xb+sb xb+sb]', [yb+0.012*h yb yb yb+0.012*h]', z, S.SOFT, 0.5);
        text_z(ax, x0 + 0.96 * w, yb + 0.018*h, z, '500 km', 'right', 4.5, S.SOFT);
    end
else
    NH = nanhai_polys();
    for k = 1:numel(NH)
        p = NH{k}; patch_z(ax, x0 + w*0.06 + w*0.88*p(:,1)/64, y0 + h*0.04 + h*0.90*(1 - p(:,2)/93.1), z, c, c, 0.4);   % 局部 y 向下 → 翻转
    end
end
if isempty(z); text_z(ax, x0 + 0.96*w, y0 + 0.035*h, z, 'South China Sea Islands', 'right', 5.5, S.SOFT);   % 附图名称(右下角空白海域)
else; text(ax, x0 + w, y0 - 0.03*h, z, 'South China Sea Islands', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', fz(5.5, true), 'Color', S.SOFT); end   % 三维: 框外下方
end

function patch_z(ax, px, py, z, fc, ec, lw)
if isempty(z); patch(ax, px, py, fc, 'EdgeColor', ec, 'LineWidth', lw);
else; patch(ax, px, py, z * ones(size(px)), fc, 'EdgeColor', ec, 'LineWidth', lw); end
end

function line_z(ax, px, py, z, c, lw)
if isempty(z); plot(ax, px, py, '-', 'Color', c, 'LineWidth', lw);
else; plot3(ax, px, py, z * ones(size(px)), '-', 'Color', c, 'LineWidth', lw); end
end

function text_z(ax, x, y, z, s, ha, fs, c)
if isempty(z); text(ax, x, y, s, 'HorizontalAlignment', ha, 'VerticalAlignment', 'bottom', 'FontSize', fz(fs, true), 'Color', c);
else; text(ax, x, y, z, s, 'HorizontalAlignment', ha, 'VerticalAlignment', 'bottom', 'FontSize', fz(fs, true), 'Color', c); end
end

function NH = nanhai_polys()
% 南海诸岛示意几何(ECharts 4.x geo/fix/nanhai.js, Apache-2.0), 局部坐标 x∈[0,64], y∈[0,93.1](向下)
NH = {[0 3.5; 7 11.2; 15 11.9; 30 7; 42 0.7; 52 0.7; 56 7.7; 59 0.7; 64 0.7; 64 0; 5 0; 0 3.5], ...
      [13 16.1; 19 14.7; 16 21.7; 11 23.1; 13 16.1], [12 32.2; 14 38.5; 15 38.5; 13 32.2; 12 32.2], ...
      [16 47.6; 12 53.2; 13 53.2; 18 47.6; 16 47.6], [6 64.4; 8 70; 9 70; 8 64.4; 6 64.4], ...
      [23 82.6; 29 79.8; 30 79.8; 25 82.6; 23 82.6], [37 70.7; 43 62.3; 44 62.3; 39 70.7; 37 70.7], ...
      [48 51.1; 51 45.5; 53 45.5; 50 51.1; 48 51.1], [51 35; 51 28.7; 53 28.7; 53 35; 51 35], ...
      [52 22.4; 55 17.5; 56 17.5; 53 22.4; 52 22.4], [58 12.6; 62 7; 63 7; 60 12.6; 58 12.6]};
end

function lim = flowlines(ax, S, MP, F, islog, cmin)
% 逐年流线: 每条 = (年份, 起点, 终点) 一次流动; 弧度随年份递增, 颜色/线宽随强度, 透明度随年份
F = F(F(:,4) > 0, :); [~, o] = sort(F(:,4)); F = F(o, :);
v = F(:,4); if islog; v = log10(v); end
lo = qtile(v, 0.02); if ~isempty(cmin); lo = cmin; end; hi = max(v); if hi <= lo; hi = lo + 1; end
lim = [lo hi]; NYm = max(F(:,1));
for q = 1:size(F, 1)
    y = F(q,1); a = F(q,2); b = F(q,3);
    [p0, p1] = shrink_(MP.nxy(a,:), MP.nxy(b,:), 30, 30);
    Q = bez(p0, p1, (0.10 + 0.017 * (y - 1)) * (2*(a <= 4) - 1), 90);
    s = min(max((v(q) - lo) / (hi - lo), 0), 1);
    line(ax, Q(:,1), Q(:,2), 'Color', [cmap_rgb(S.FLOW, s) 0.30 + 0.65 * y / NYm], 'LineWidth', 0.28 + 1.45 * s^1.6);
end
end

function map_nodes(ax, S, MP, cap, unit)
lo = min(cap); hi = max(cap); qs = qtile(cap, [0.2 0.4 0.6 0.8]); hd = getappdata(ax, 'halo'); u = data_per_pt(ax);
for k = 1:7
    s = 60 + 460 * (cap(k) - lo) / max(hi - lo, 1e-9); lev = 1 + sum(qs < cap(k)); c = S.LEVEL(lev, :);
    x = MP.nxy(k,1); y = MP.nxy(k,2);
    scatter(ax, x, y, s * 2.2, c, 'filled', 'MarkerFaceAlpha', 0.18, 'MarkerEdgeColor', 'none');
    scatter(ax, x, y, s, c, 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 1.0);
    scatter(ax, x, y, 6, [1 1 1], 'filled');
    dx = MP.loff(k,1); dy = MP.loff(k,2); rm = sqrt(s) / 2; off = sqrt(2.2 * s) / 2 + 5;   % 点单位: 标记半径 / 外晕外 5pt
    if dx ~= 0 && dy ~= 0; ux = 0.72 * dx; uy = 0.72 * dy; else; ux = dx; uy = dy; end
    tx = x + ux * off * u; ty = y + uy * off * u; a0 = [x y] + [ux uy] / norm([ux uy]) * (rm + 0.5) * u;
    plot(ax, [a0(1) tx], [a0(2) ty], '-', 'Color', S.SOFT, 'LineWidth', 0.5);       % 引线: 节点边缘 → 标注
    if dx > 0; hal = 'left'; elseif dx < 0; hal = 'right'; else; hal = 'center'; end
    if dy > 0; val = 'bottom'; elseif dy < 0; val = 'top'; else; val = 'middle'; end
    htext(ax, S, hd, tx, ty, {MP.nabbr{k}, commas(cap(k))}, ...                 % 单位(MW)见等级图例标题
        'FontSize', fz(6.5), 'HorizontalAlignment', hal, 'VerticalAlignment', val);
end
end

function u = data_per_pt(ax)
% axis equal 地图上 1 pt 对应的数据长度(km), 用于把点单位偏移换算为数据坐标
un = ax.Units; ax.Units = 'points'; p = ax.Position; ax.Units = un;
u = max(diff(ax.XLim) / p(3), diff(ax.YLim) / p(4));
end

function level_legend(ax, S, MP, ttl)
% 节点等级图例(单列), 行距按字号换算为数据长度, 自动放在主图左侧不压盖陆地与界线的空位
u = data_per_pt(ax); f1 = fz(6.5); dy = 1.45 * f1 * u; top = 1.6 * fz(7) * u;
[x0, y0] = legend_spot(ax, MP, 1500, dy, top);
text(ax, x0, y0, ttl, 'FontSize', fz(7), 'Color', S.INK, 'VerticalAlignment', 'bottom');
lb = {'Very high', 'High', 'Medium', 'Low', 'Very low'};
for i = 1:5
    yy = y0 - dy * (i - 0.4);
    scatter(ax, x0 + 0.55 * f1 * u, yy, 46 * (f1 / 6.5), S.LEVEL(6 - i, :), 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.6);
    text(ax, x0 + 1.4 * f1 * u, yy, lb{i}, 'FontSize', f1, 'Color', S.SOFT, 'VerticalAlignment', 'middle');
end
end

function [x0, y0] = legend_spot(ax, MP, wl, dy, top)
% 在主图左侧(宽 wl km)自上而下寻找不压盖陆地的空位, 下限为左下角色条及其标题之上; 找不到时退回原位置
e = MP.ext; H = e(4) - e(3); x0 = e(1) + 40; yl = ax.YLim; ybot = yl(1) + 0.24 * diff(yl);
hl = top + 5 * dy + 50; ytop0 = e(3) + 0.62 * H;
gxv = linspace(x0, x0 + wl, 31); gyv = ybot : 15 : ytop0 + top; [GX, GY] = meshgrid(gxv, gyv); occ = false(size(GX));
for k = 1:numel(MP.pxy)
    p = MP.pxy{k};
    if max(p(:,1)) < x0 || min(p(:,1)) > x0 + wl || max(p(:,2)) < ybot || min(p(:,2)) > ytop0 + top; continue; end
    occ = occ | reshape(inpolygon(GX(:), GY(:), p(:,1), p(:,2)), size(GX));
end
rowocc = any(occ, 2);                                                  % 各高度是否有陆地
for yt = ytop0 : -10 : ybot + hl - top
    if ~any(rowocc(gyv >= yt - (hl - top) & gyv <= yt + top)); y0 = yt; return; end
end
y0 = ytop0;
end

function hbar_(f, ax, S, cmap, lim, label, islog)
% 地图内嵌横向色条(左下角)
p = ax.Position; cax = axes(f, 'Position', [p(1) + 0.035*p(3), p(2) + 0.06*p(4), 0.26*p(3), 0.022*p(4)]);
image(cax, linspace(lim(1), lim(2), 256), [0 1], repmat(reshape(cmap, 1, [], 3), 2, 1, 1));
set(cax, 'YTick', [], 'XLim', lim, 'YLim', [-0.5 1.5], 'YDir', 'normal', 'TickDir', 'out', 'FontSize', fz(6.5), 'FontName', S.font, ...
    'XColor', S.SOFT, 'YColor', 'none', 'Box', 'off', 'TickLength', [0.03 0.03]);
if islog
    t = ceil(lim(1)):floor(lim(2));
    if ~isempty(t); set(cax, 'XTick', t, 'XTickLabel', arrayfun(@(v) sprintf('10^{%d}', v), t, 'Uni', 0)); end
end
text(cax, lim(1), 2.0, label, 'VerticalAlignment', 'bottom', 'FontSize', fz(7), 'Color', S.INK);
end

function htext(ax, S, d, x, y, s, varargin)
% 白色描边文字(地图标注)
if isempty(d); d = 8; end
for a = 0:45:315; text(ax, x + d*cosd(a), y + d*sind(a), s, 'Color', [1 1 1], varargin{:}); end
text(ax, x, y, s, 'Color', S.INK, varargin{:});
end

function s = commas(v)
s = regexprep(sprintf('%.0f', v), '(\d)(?=(\d{3})+$)', '$1,');
end

function [a, b] = shrink_(p0, p1, r0, r1)
d = p1 - p0; L = max(norm(d), eps); u = d / L; a = p0 + u * r0; b = p1 - u * r1;
end

function Q = bez(p0, p1, c, n)
d = p1 - p0; m = (p0 + p1) / 2 + c * [-d(2) d(1)]; t = linspace(0, 1, n)';
Q = (1 - t).^2 .* p0 + 2 * (1 - t) .* t .* m + t.^2 .* p1;
end

function patch_polys(ax, polys, fc, ec, lw, z)
% 多个多边形按顶点数分组合并为少量 patch(Faces 以 NaN 补齐), z 给定时绘于三维平面 z
if isempty(polys); return; end
nn = cellfun(@(p) size(p, 1), polys); ed = [0 64 512 4096 inf];
for g = 1:numel(ed) - 1
    id = find(nn > ed(g) & nn <= ed(g+1)); if isempty(id); continue; end
    V = vertcat(polys{id}); F = nan(numel(id), max(nn(id))); o = 0;
    for j = 1:numel(id); F(j, 1:nn(id(j))) = o + (1:nn(id(j))); o = o + nn(id(j)); end
    if nargin > 5; V = [V, z * ones(size(V, 1), 1)]; end %#ok<AGROW>
    patch(ax, 'Faces', F, 'Vertices', V, 'FaceColor', fc, 'EdgeColor', ec, 'LineWidth', lw);
end
end

function Q = clip_rect(P, x0, x1, y0, y1)
% Sutherland–Hodgman 多边形矩形裁剪
Q = P;
Q = clip_edge(Q, @(q) q(:,1) >= x0, @(a, b) [x0, a(2) + (b(2) - a(2)) * (x0 - a(1)) / (b(1) - a(1))]);
Q = clip_edge(Q, @(q) q(:,1) <= x1, @(a, b) [x1, a(2) + (b(2) - a(2)) * (x1 - a(1)) / (b(1) - a(1))]);
Q = clip_edge(Q, @(q) q(:,2) >= y0, @(a, b) [a(1) + (b(1) - a(1)) * (y0 - a(2)) / (b(2) - a(2)), y0]);
Q = clip_edge(Q, @(q) q(:,2) <= y1, @(a, b) [a(1) + (b(1) - a(1)) * (y1 - a(2)) / (b(2) - a(2)), y1]);
if size(Q, 1) < 3; Q = []; end
end

function out = clip_edge(P, inside, inter)
out = zeros(0, 2); if isempty(P); return; end
n = size(P, 1); ins = inside(P); out = zeros(2*n, 2); m = 0;
for i = 1:n
    j = i - 1; if j == 0; j = n; end
    a = P(j,:); b = P(i,:);
    if ins(i)
        if ~ins(j); m = m + 1; out(m,:) = inter(a, b); end
        m = m + 1; out(m,:) = b;
    elseif ins(j)
        m = m + 1; out(m,:) = inter(a, b);
    end
end
out = out(1:m, :);
end

%% ═══════════════════════════════ 绘图工具 ═══════════════════════════════
function S = sty()
fl = listfonts; cand = {'Arial', 'Helvetica', 'Liberation Sans'};
S.font = get(groot, 'defaultAxesFontName');
for k = 1:numel(cand); if any(strcmpi(fl, cand{k})); S.font = cand{k}; break; end; end
h = @hex2rgb;
S.INK = h('#2B3A44'); S.SOFT = h('#6B7780'); S.LINE = h('#B9C0C4'); S.GRID = h('#ECEFEC');
S.NAVY = h('#24425F'); S.BLUE = h('#3B6E8F'); S.TEAL = h('#4E9A92'); S.SAGE = h('#9DBF9E'); S.SAND = h('#E3CF9A');
S.OCHRE = h('#D9A35F'); S.TERRA = h('#C2674A'); S.BRICK = h('#9E3D2F'); S.GRAY = h('#8A949C');
S.LAND = h('#EDF0F1'); S.COAST = h('#AEB8BD');
S.SEQ  = cmapn({'#F4F1E6','#D6E6DA','#9BC7BB','#5FA39A','#2F6E80','#1E3F5A'});
S.TER  = cmapn({'#1E3F5A','#2F6E80','#5FA39A','#BFD8C4','#EFE6C8','#E3C27E','#D08A5B','#B4533A'});
S.DIV  = cmapn({'#2F6E80','#7FB3AE','#F4F1E6','#E3A07E','#B4533A'});
S.FLOW = cmapn({'#3F6F9A','#7FAFC8','#CFE0E3','#F1DDB0','#E8A06A','#C8553D','#8E2B22'});
S.VIR  = cmapn({'#440154','#482878','#3E4A89','#31688E','#26828E','#1F9E89','#35B779','#6DCD59','#B4DE2C','#FDE725'});
S.LEVEL = cell2mat(cellfun(h, {'#DCE6EE';'#9CC0D8';'#F0C979';'#E2774E';'#A8322A'}, 'Uni', 0));
S.ASSETS = {'Training','Inference','Green power','W. storage','E. storage','HVDC'};
S.CA = [S.NAVY; S.TERRA; S.TEAL; h('#7FA7C4'); h('#C994B3'); S.OCHRE];
try
    set(groot, 'defaultAxesFontName', S.font, 'defaultTextFontName', S.font, 'defaultLegendFontName', S.font, ...
        'defaultAxesFontSize', fz(8), 'defaultTextFontSize', fz(8));
catch
end
end

function c = hex2rgb(s)
c = sscanf(s(2:end), '%2x%2x%2x', [1 3]) / 255;
end

function M = cmapn(hexes, n)
if nargin < 2; n = 256; end
C = cell2mat(cellfun(@hex2rgb, hexes(:), 'Uni', 0)); M = interp1(linspace(0, 1, size(C, 1)), C, linspace(0, 1, n)');
end

function c = cmap_rgb(M, s)
s = min(max(s(:), 0), 1); s(~isfinite(s)) = 0; c = M(1 + round(s * (size(M, 1) - 1)), :);
end

function f = newfig(S, w, h)
vis = 'off'; if isappdata(0, 'pf_show') && getappdata(0, 'pf_show'); vis = 'on'; end
f = figure('Visible', vis, 'Color', 'w', 'Units', 'centimeters', 'Position', [2 2 w h]);
set(f, 'DefaultAxesFontName', S.font, 'DefaultTextFontName', S.font);
end

function [f, ax] = fig3(S, w, h)
f = newfig(S, w, h); ax = axes(f); style3(ax, S);
end

function style2(ax, S, gridy)
set(ax, 'FontName', S.font, 'FontSize', fz(8), 'XColor', S.SOFT, 'YColor', S.SOFT, 'LineWidth', lz(0.6), 'TickDir', 'out', ...
    'Box', 'off', 'TickLength', [0.008 0.008], 'Layer', 'bottom', 'GridColor', 0.94 * [1 1 1], 'GridAlpha', 1);
if gridy; ax.YGrid = 'on'; end
hold(ax, 'on');
end

function style3(ax, S)
set(ax, 'FontName', S.font, 'FontSize', fz(7), 'Color', 'none', 'XColor', S.SOFT, 'YColor', S.SOFT, 'ZColor', S.SOFT, ...
    'GridColor', [0.80 0.82 0.83], 'GridAlpha', 0.55, 'LineWidth', lz(0.5), 'TickDir', 'out', 'Box', 'off');
grid(ax, 'on'); hold(ax, 'on');
end

function cb = cbar_(ax, S, cmap, lim, label)
colormap(ax, cmap); if lim(2) <= lim(1); lim(2) = lim(1) + 1; end; clim_(ax, lim);
cb = colorbar(ax); cb.Color = S.SOFT; cb.FontSize = fz(6.5); cb.TickDirection = 'out'; cb.LineWidth = lz(0.4);
cb.Label.String = label; cb.Label.Color = S.INK; cb.Label.FontSize = fz(8); try; cb.Box = 'off'; catch; end
end

function shrink_cb(cb, fr)
p = cb.Position; cb.Position = [p(1) + 0.02, p(2) + p(4) * (1 - fr) / 2, p(3) * 0.8, p(4) * fr];
end

function slice3(ax, S, x, yk, z, h, z0)
% 三维切片: y = yk 平面上由 z0 到平滑曲线的填充面, 颜色随 h 渐变, 顶边白线
xf = linspace(min(x), max(x), 200); zf = sm(x, z, xf); hf = sm(x, h, xf);
ok = isfinite(zf) & isfinite(hf); xf = xf(ok); zf = zf(ok); hf = hf(ok); n = numel(xf);
if n < 2; return; end
surf(ax, [xf; xf], yk * ones(2, n), [z0 * ones(1, n); zf], [hf; hf], 'FaceColor', 'interp', 'EdgeColor', 'none');
dz = 0.004 * max(abs(zf));
plot3(ax, xf, yk * ones(1, n), zf + dz, '-', 'Color', [1 1 1], 'LineWidth', 1.1);
plot3(ax, xf, yk * ones(1, n), zf + dz, '-', 'Color', [S.INK 0.6], 'LineWidth', 0.35);
end

function savefig_(f, fd, name, img)
try; set(findall(f, 'Type', 'axes'), 'Toolbar', []); catch; end
set(f, 'Name', name, 'NumberTitle', 'off'); drawnow;
fit_figure_text(f);                                                   % 放大字号后的折行、收缩与防裁切
exportgraphics(f, fullfile(fd, [name '.png']), 'Resolution', 600);
try
    if img; exportgraphics(f, fullfile(fd, [name '.pdf']), 'ContentType', 'image', 'Resolution', 600);
    else;   exportgraphics(f, fullfile(fd, [name '.pdf']), 'ContentType', 'vector'); end
catch
end
if ~(isappdata(0, 'pf_show') && getappdata(0, 'pf_show')); close(f); end
end

function clim_(ax, lim)
try; clim(ax, lim); catch; caxis(ax, lim); end %#ok<CAXIS>
end

%% ═══════════════════════════════ 数值工具 ═══════════════════════════════
function v = sm(x, y, xf)
% 保形分段三次(PCHIP)平滑插值, 不外推
x = double(x(:)); y = double(y(:)); ok = isfinite(x) & isfinite(y);
if nnz(ok) < 2; v = nan(size(xf)); return; end
v = pchip(x(ok), y(ok), xf); v(xf < min(x(ok)) | xf > max(x(ok))) = NaN;
end

function d = kde1(x, g, bw)
% 一维高斯核密度(带宽 = bw×标准差, 对近常数数据稳健)
if nargin < 3 || isempty(bw); bw = 0.25; end
x = double(x(:)); x = x(isfinite(x)); g = double(g(:)');
if isempty(x); d = zeros(size(g)); return; end
if numel(x) > 4000; s = RandStream('mt19937ar', 'Seed', 1); x = x(randperm(s, numel(x), 4000)); end
span = max(g) - min(g); sd = std(x); if sd <= 0; sd = span; end
h = max(bw * sd, 0.012 * span); z = (g - x) / h;
d = sum(exp(-0.5 * z.^2), 1) / (numel(x) * h * sqrt(2*pi));
end

function Z = kde2(x, y, gx, gy, bw)
% 二维高斯核密度(可分离核), 返回 numel(gy)×numel(gx)
x = double(x(:)); y = double(y(:)); hx = max(bw * std(x), 1e-6); hy = max(bw * std(y), 1e-6);
Ax = exp(-0.5 * ((gx(:)' - x) / hx).^2); Ay = exp(-0.5 * ((gy(:)' - y) / hy).^2);
Z = (Ay' * Ax) / (numel(x) * 2 * pi * hx * hy);
end

function q = qtile(v, p)
v = sort(double(v(isfinite(v)))); v = v(:); n = numel(v);
if n == 0; q = nan(size(p)); return; end
if n == 1; q = v * ones(size(p)); return; end
q = interp1(linspace(0, 1, n)', v, p);
end

function r = range_(v)
r = max(v(:)) - min(v(:));
end

function A = gsmooth(A, sr, sc)
% 二维高斯平滑: 行(月份)边界复制, 列(时刻)周期延拓
r = ceil(4 * sr); k = exp(-0.5 * ((-r:r)' / sr).^2); k = k / sum(k);
A = conv2([repmat(A(1,:), r, 1); A; repmat(A(end,:), r, 1)], k, 'valid');
c = ceil(4 * sc); k = exp(-0.5 * ((-c:c) / sc).^2); k = k / sum(k);
A = conv2([A(:, end-c+1:end), A, A(:, 1:c)], k, 'valid');
end

function T = grid_interp(A, hh, mm)
% 12×24 月-时矩阵 → 细网格(时刻线性, 月份 PCHIP)
A1 = interp1((0:23)', A', hh(:))';               % 12×numel(hh)
T = pchip(0:11, A1', mm)';                       % numel(mm)×numel(hh)
end

function cnt = hexbin_(ax, x, y, nx, xl, yl)
% 六边形分箱(与 matplotlib hexbin 同构), 颜色 = log10(计数)
x = x(:); y = y(:); ny = max(1, floor(nx / sqrt(3)));
sx = max(xl(2) - xl(1), eps) / nx; sy = max(yl(2) - yl(1), eps) / ny;
u = (x - xl(1)) / sx; v = (y - yl(1)) / sy;
i1 = round(u); j1 = round(v); i2 = floor(u); j2 = floor(v);
d1 = (u - i1).^2 + 3 * (v - j1).^2; d2 = (u - i2 - 0.5).^2 + 3 * (v - j2 - 0.5).^2; b = d1 < d2;
cx = [i1(b); i2(~b) + 0.5]; cy = [j1(b); j2(~b) + 0.5];
[key, ~, ic] = unique([cx cy], 'rows'); cnt = accumarray(ic, 1);
X = xl(1) + key(:,1) * sx; Y = yl(1) + key(:,2) * sy; nh = numel(cnt);
ox = sx * [0.5 0.5 0 -0.5 -0.5 0]; oy = sy / 3 * [-0.5 0.5 1 0.5 -0.5 -1];
VX = X + ox; VY = Y + oy; V = [reshape(VX', [], 1) reshape(VY', [], 1)]; F = reshape(1:6*nh, 6, nh)';
patch(ax, 'Faces', F, 'Vertices', V, 'FaceVertexCData', log10(cnt), 'FaceColor', 'flat', 'EdgeColor', [1 1 1], 'LineWidth', 0.2);
end

function fill_contour(ax, gx, gy, Z, lev, col, alpha)
% 填充高于 lev 的等值区域(半透明)
C = contourc(gx, gy, Z, [lev lev]); k = 1;
while k < size(C, 2)
    n = C(2, k); xy = C(:, k+1:k+n); k = k + n + 1;
    patch(ax, xy(1,:), xy(2,:), col, 'FaceAlpha', alpha, 'EdgeColor', 'none');
end
end

%% ═══════════════════════════════ 通用读取工具 ═══════════════════════════════
function s = cstr(x)
if isa(x, 'missing') || (isstring(x) && any(ismissing(x))); s = ''; return; end
if isnumeric(x) || islogical(x); s = num2str(x); return; end
s = strtrim(char(string(x)));
end

function y = ynum(s)
if isnumeric(s); y = double(s); return; end
y = str2double(regexprep(cstr(s), '[^0-9]', ''));
end

function v = tonum(x)
if isnumeric(x) || islogical(x); v = double(x); elseif isa(x, 'missing'); v = NaN; else; v = str2double(string(x)); end
if isempty(v) || ~isscalar(v); v = NaN; end
end

function C = rdcell(fn)
C = {}; if ~exist(fn, 'file'); return; end
try; C = readcell(fn, 'Delimiter', ',', 'Encoding', 'UTF-8');
catch; try; C = readcell(fn, 'Delimiter', ','); catch; end; end
end

function v = getp(P, f, d)
if isstruct(P) && isfield(P, f) && ~isempty(P.(f)); v = P.(f); else; v = d; end
end

function v = getf(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)); v = double(s.(f)); else; v = d; end
end
