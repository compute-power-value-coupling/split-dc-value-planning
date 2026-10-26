function plot_comparison_figures(root, show, fs)
%% 本文方法与五组单因素对比 —— 对比仿真图 K01–K05(期刊风格, 中文字体, 一图一幅), 读取已有结果, 无需重新仿真
%  plot_comparison_figures               % 自动弹出并保存到 simulation_output/paper_figs/K*.png/.pdf
%  plot_comparison_figures(root, false)  % 只保存不弹出
%  plot_comparison_figures([], true, 18)  % 指定图中字号(磅), 默认 14; 版面随字号自动调整(utils/fit_figure_text)
%  数据: simulation_output/ 与 cmp_<组名>/ 下的 summary.csv、asset_recovery.csv、checkpoint/ckpt_latest.mat
%  K01 末年训练算力利用率箱线图 | K02 核心指标平行坐标(中后期逐年) | K03 末年闲置训练算力山脊图 | K04 东部储能三维切片 | K05 资产级NPV差值矩阵
if nargin < 1 || isempty(root); root = fileparts(mfilename('fullpath')); end
if nargin < 2; show = true; end
if nargin < 3 || isempty(fs); fs = 14; end
setappdata(0, 'pf_show', show); setappdata(0, 'pf_fs', fs);
addpath(fullfile(fileparts(mfilename('fullpath')), 'utils'));
cases = {'simulation_output','cmp_S1_AHGF','cmp_S2_PO_VFS_FBR','cmp_S3_AFZ_VFS_SHAP','cmp_S4_MRP','cmp_S5_WM'};
lab   = {'Proposed','S1','S2','S3','S4','S5'};
S = sty(); col = [S.TERRA; S.NAVY; S.BLUE; S.TEAL; S.SAGE; S.GRAY];
ok = cellfun(@(d) exist(fullfile(root, d, 'summary.csv'), 'file') > 0, cases);
if ~ok(1) || sum(ok) < 2; fprintf('[对比图] 需本文结果及至少1组对比结果, 跳过\n'); return; end
cases = cases(ok); lab = lab(ok); col = col(ok, :); NG = numel(cases);
r = 0.08; NY = 15; disc = (1 + r) .^ -(1:NY)';
M = struct('npv', nan(NY,NG), 'inv', nan(NY,NG), 'Ee', nan(NY,NG), 'Bv', nan(NY,NG), 'Cm', nan(NY,NG), 'gap', nan(NY,NG), ...
           'WT', nan(NY,NG), 'loss', nan(NY,NG), 'irr', nan(1,NG), 'pb', nan(1,NG), 'cur', nan(1,NG), 'NPVa', nan(NG,7), ...
           'curY', nan(NY,NG), 'utY', nan(NY,NG));
idle = cell(1, NG); util = cell(1, NG);
fprintf('[对比图] 读取 %d 组结果...\n', NG);
for k = 1:NG
    d = fullfile(root, cases{k});
    Sx = readmatrix(fullfile(d, 'summary.csv'), 'NumHeaderLines', 1); n = min(NY, size(Sx, 1)); Sx = Sx(1:n, :);
    M.npv(1:n,k) = Sx(:,13); M.inv(1:n,k) = cumsum(Sx(:,7)); M.Ee(1:n,k) = Sx(:,6) / 1e3; M.WT(1:n,k) = Sx(:,2);
    M.Bv(1:n,k) = 100 * Sx(:,20); M.Cm(1:n,k) = 100 * Sx(:,21); M.gap(1:n,k) = 100 * Sx(:,27);
    M.irr(k) = 100 * Sx(n,15); M.pb(k) = Sx(n,16); M.cur(k) = 100 * Sx(n,25);
    [CF, NPVa] = read_recovery(fullfile(d, 'asset_recovery.csv')); CF(end+1:NY, :) = NaN; CF = CF(1:NY, :);
    M.NPVa(k,:) = NPVa; M.loss(:,k) = -sum(min(0, cumsum(CF .* disc, 1, 'omitnan')), 2);
    fn = fullfile(d, 'checkpoint', 'ckpt_latest.mat');
    if exist(fn, 'file')
        try
            t = load(fn, 'results_yearly'); RY = t.results_yearly; if ~iscell(RY); RY = num2cell(RY); end
            RY = RY(~cellfun(@isempty, RY)); R = RY{end}; a = R.actual; st = R.state;
            idle{k} = max(0, sum(st.W_T_cum(:)) - sum(a.P_train, 2)) / 1e3;                           % GW
            ut = sum(a.P_train, 2) / max(sum(st.W_T_cum(:)), eps); nd = floor(numel(ut) / 24);
            util{k} = 100 * mean(reshape(ut(1:24*nd), 24, nd), 1)';                                    % 末年逐日训练算力利用率(%)
            for yy = 1:min(NY, numel(RY))                                                             % 逐年弃电率与训练利用率
                ay = RY{yy}.actual; sy = RY{yy}.state; avy = sum(sum((ay.cf_wind(:, 1:4) + ay.cf_pv(:, 1:4)) / 2 .* sy.G_cum(:)', 1));
                M.curY(yy,k) = 100 * sum(ay.P_curt(:)) / max(avy, eps); M.utY(yy,k) = mean(sum(ay.P_train, 2)) / max(sum(sy.W_T_cum(:)), eps);
            end
            av = sum(sum((a.cf_wind(:, 1:4) + a.cf_pv(:, 1:4)) / 2 .* st.G_cum(:)', 1));
            if av > 0; M.cur(k) = 100 * sum(a.P_curt(:)) / av; end                                     % 末年弃电率(%)
        catch ME
            fprintf('  [对比图] %s 检查点读取失败: %s\n', cases{k}, ME.message);
        end
    end
end
M.npv = M.npv / 10; M.inv = M.inv / 10; M.loss = M.loss / 10; M.NPVa = M.NPVa / 10;   % 10^8 CNY -> billion CNY
fd = fullfile(root, 'simulation_output', 'paper_figs'); if ~exist(fd, 'dir'); mkdir(fd); end
old = [dir(fullfile(fd, 'Cmp*.*')); dir(fullfile(fd, 'K0*.*'))];
for q = 1:numel(old); try; delete(fullfile(fd, old(q).name)); catch; end; end
y = (1:NY)'; xs = linspace(1, NY, 281);

%% ── K01 末年逐日训练算力利用率: 箱线 + 抖动散点(365个日均值), 顶部标注年均值与名次 ──
try
    if all(cellfun(@isempty, util)); error('缺少检查点(逐小时训练负荷)'); end
    CLb = cell2mat(cellfun(@hex2rgb, {'#C2674A'; '#2E5A87'; '#4F86B0'; '#4E9A92'; '#8DAF7E'; '#8A949C'}, 'Uni', 0)); CLb = CLb(ok, :);
    mu = cellfun(@(u) mean(u, 'omitnan'), util); mu(cellfun(@isempty, util)) = NaN; [~, o] = sort(-mu); rk = zeros(1, NG); rk(o) = 1:NG;
    allu = vertcat(util{:}); ylo = max(0, floor(min(allu) / 10) * 10 - 10);
    f = newfig(S, 15, 9.5); ax = axes(f); style2(ax, S, false); ax.Position = [0.10 0.22 0.86 0.66];
    st = RandStream('mt19937ar', 'Seed', 11);
    for k = 1:NG
        u = util{k}; if isempty(u); continue; end
        xj = k + (rand(st, numel(u), 1) - 0.5) * 0.4;
        scatter(ax, xj, u, 5, CLb(k,:), 'filled', 'MarkerFaceAlpha', 0.22, 'MarkerEdgeColor', 'none');
        q = qtile(u, [0.25 0.5 0.75]); iq = q(3) - q(1); lo = max(min(u), q(1) - 1.5 * iq); hi = min(max(u), q(3) + 1.5 * iq);
        rectangle(ax, 'Position', [k - 0.28, q(1), 0.56, max(q(3) - q(1), eps)], 'EdgeColor', CLb(k,:), 'LineWidth', 1.5);
        plot(ax, [k - 0.28, k + 0.28], [q(2) q(2)], '-', 'Color', CLb(k,:), 'LineWidth', 1.8);
        plot(ax, [k k], [lo q(1)], '-', 'Color', CLb(k,:), 'LineWidth', 1.3); plot(ax, [k k], [q(3) hi], '-', 'Color', CLb(k,:), 'LineWidth', 1.3);
        text(ax, k, 104.5, sprintf('%.1f%%', mu(k)), 'HorizontalAlignment', 'center', 'FontSize', fz(7.5), 'FontWeight', 'bold', 'Color', CLb(k,:));
        text(ax, k, 101.2, sprintf('#%d', rk(k)), 'HorizontalAlignment', 'center', 'FontSize', fz(6.8), 'Color', CLb(k,:));
    end
    set(ax, 'XTick', 1:NG, 'XTickLabel', lab, 'XTickLabelRotation', 30, 'XLim', [0.4 NG + 0.6], 'YLim', [ylo 108], 'YTick', ylo:10:100);
    ylabel(ax, sprintf('Daily training utilisation in year %d (%%)', NY), 'Color', S.INK);
    savefig_(f, fd, 'K01_training_utilization_box', false);
catch ME; fprintf('  [对比图] K01 跳过: %s (行%d)\n', ME.message, ME.stack(1).line); end

%% ── K02 核心指标平行坐标(规划中后期逐年): 淡线 = 每种方法每一年, 粗线 = 本文 + 五个对比组各自均值, 阴影 = 四分位带; 下方先算期末名次供命令行输出 ──
mn  = {'Cumulative NPV','Capital efficiency','Investment','Eastern storage','Curtailment','IRR','Solution gap','Recovery gap','Payback','B-class violation'};
un  = {'billion CNY','','billion CNY','GWh','%','%','%','billion CNY','year','%'};
big = [1 1 0 0 0 1 0 0 0 0];
lossfin = arrayfun(@(k) -sum(M.NPVa(k, M.NPVa(k,:) < 0)), 1:NG);
V = [M.npv(end,:); M.npv(end,:) ./ max(M.inv(end,:), 1); M.inv(end,:); M.Ee(end,:); M.cur; M.irr; ...
     mean(M.gap, 1, 'omitnan'); lossfin; M.pb; mean(M.Bv, 1, 'omitnan')]';                      % NG×10
fmt = {'%.0f','%.3f','%.0f','%.1f','%.3f','%.1f','%.2f','%.0f','%.0f','%.2f'};
Sn = zeros(size(V)); Rk = zeros(size(V));
for m = 1:10
    v = V(:,m); lo = min(v); hi = max(v); dd = max(hi - lo, 1e-12);
    if big(m); s01 = (v - lo) / dd; else; s01 = (hi - v) / dd; end
    Sn(:,m) = 0.2 + 0.8 * s01; [~, o] = sort(-s01); Rk(o, m) = 1:NG;
end
try
    % 逐年指标(每种方法每一年一条线), 逐年在六种方法间 min–max 归一(最优 = 1)
    IND = {'Cumulative NPV', M.npv, 1; 'Capital efficiency', M.npv ./ max(M.inv, 1), 1; 'Training utilisation', M.utY, 1; 'Cumulative investment', M.inv, 0; 'Eastern storage', M.Ee, 0; ...
           'Curtailment rate', M.curY, 0; 'Recovery gap', M.loss, 0; 'Solution gap', M.gap, 0; 'B-class violation', M.Bv, 0};
    K = size(IND, 1); Sc = nan(NY, NG, K);
    for m = 1:K
        A = IND{m, 2};
        for t = 1:NY
            v = A(t, :); lo = min(v, [], 'omitnan'); hi = max(v, [], 'omitnan'); dd = hi - lo;
            if ~(dd > 1e-9 * max(1, abs(hi))); Sc(t, :, m) = 0.5; elseif IND{m, 3}; Sc(t, :, m) = (v - lo) / dd; else; Sc(t, :, m) = (hi - v) / dd; end
        end
    end
    T0 = min(8, NY); tt = T0:NY; xx = 1:K;                                   % 规划中后期
    cA = hex2rgb('#2E5A87'); cB = hex2rgb('#D0805F');
    f = newfig(S, 17, 10.5); ax = axes(f); style2(ax, S, false); ax.Position = [0.08 0.18 0.90 0.62];
    for m = 1:K; xline(ax, m, '-', 'Color', [0.90 0.914 0.922], 'LineWidth', 0.8); end
    for t = tt; for k = 2:NG; plot(ax, xx, squeeze(Sc(t, k, :))', '-', 'Color', [cA 0.20], 'LineWidth', 0.5); end; end
    for t = tt; plot(ax, xx, squeeze(Sc(t, 1, :))', '-', 'Color', [cB 0.35], 'LineWidth', 0.7); end
    G = {reshape(Sc(tt, 2:NG, :), [], K), reshape(Sc(tt, 1, :), [], K)}; cg = [cA; cB];
    for g = 1:2                                                             % 阴影: 蓝 = 五种对比方法合并四分位带, 红 = 本文方法
        q1 = zeros(1, K); q3 = q1;
        for m = 1:K; q = qtile(G{g}(:, m), [0.25 0.75]); q1(m) = q(1); q3(m) = q(2); end
        patch(ax, [xx fliplr(xx)], [q1 fliplr(q3)], cg(g,:), 'FaceAlpha', 0.20, 'EdgeColor', 'none');
    end
    % 粗线: 五个对比组各自均值(冷色系 + 不同线型/标记), 本文方法均值最后画
    CK = cell2mat(cellfun(@hex2rgb, {'#1F3B5C'; '#3E73A8'; '#2F8A8C'; '#6B5B95'; '#5F7A8C'}, 'Uni', 0)); CK = CK(ok(2:end), :);
    MK = {'s', '^', 'd', 'v', 'p'}; LK = {'-', '--', '-', '--', ':'}; MK = MK(ok(2:end)); LK = LK(ok(2:end));
    hg = gobjects(1, NG); MS = zeros(NG, K);
    for k = 1:NG; MS(k, :) = mean(reshape(Sc(tt, k, :), [], K), 1, 'omitnan'); end
    for k = 2:NG
        hg(k) = plot(ax, xx, MS(k,:), LK{k-1}, 'Color', CK(k-1,:), 'LineWidth', 1.6, 'Marker', MK{k-1}, 'MarkerSize', 4, ...
            'MarkerFaceColor', CK(k-1,:), 'MarkerEdgeColor', [1 1 1]);
    end
    hg(1) = plot(ax, xx, MS(1,:), '-o', 'Color', cB, 'LineWidth', 2.0, 'MarkerSize', 4, 'MarkerFaceColor', cB);
    set(ax, 'XTick', xx, 'XTickLabel', IND(:, 1), 'XTickLabelRotation', 35, 'XLim', [0.85 K + 0.15], 'YLim', [-0.03 1.05], 'YGrid', 'on');
    ylabel(ax, 'Score normalised within each year (best = 1)', 'Color', S.INK);
    lg = legend(ax, hg, lab, 'NumColumns', 3, 'Box', 'off', 'FontSize', fz(7.5));
    lg.Position(1:2) = [0.5 - lg.Position(3)/2, ax.Position(2) + ax.Position(4) + 0.065];
    fprintf('  [K02] 第%d–%d年各指标得分均值(最优=1):\n', T0, NY); for k = 1:NG; fprintf('  %-14s', lab{k}); fprintf('%6.2f', MS(k,:)); fprintf('\n'); end
    savefig_(f, fd, 'K02_core_indicator_parallel', false);
catch ME; fprintf('  [对比图] K02 跳过: %s (行%d)\n', ME.message, ME.stack(1).line); end

%% ── K03 末年小时闲置训练算力山脊图(竖线为均值, 右侧标注相对本文变化) ──
try
    if isempty(idle{1}); error('缺少本文检查点'); end
    gm = 3.2; for k = 1:NG; if ~isempty(idle{k}); gm = max(gm, qtile(idle{k}, 0.995) * 1.1); end; end
    gx = linspace(0, gm, 500); mu0 = mean(idle{1});
    f = newfig(S, 14, 10); ax = axes(f); style2(ax, S, false); ax.Position = [0.18 0.12 0.58 0.84];
    for k = NG:-1:1
        if isempty(idle{k}); continue; end
        b = (NG - k) * 1.0; dd = kde1(idle{k}, gx, 0.15); dd = dd / max(max(dd), eps) * 1.8; mu = mean(idle{k});
        patch(ax, [gx fliplr(gx)], [b + dd, b * ones(size(dd))], col(k,:), 'FaceAlpha', 0.55 + 0.30 * (k == 1), 'EdgeColor', 'none');
        plot(ax, gx, b + dd, '-', 'Color', [1 1 1], 'LineWidth', 1.0);
        plot(ax, [mu mu], [b, b + interp1(gx, dd, mu)], '-', 'Color', S.INK, 'LineWidth', 0.8);
        if k == 1; s = sprintf('%.2f', mu); else; s = sprintf('%.2f (%+.0f%%)', mu, 100 * (mu / max(mu0, eps) - 1)); end
        text(ax, gm * 1.01, b + 0.15, s, 'FontSize', fz(6.8), 'Color', col(k,:), 'VerticalAlignment', 'bottom');
        text(ax, -0.02 * gm, b + 0.1, lab{k}, 'HorizontalAlignment', 'right', 'FontSize', fz(7), 'Color', S.INK);
    end
    set(ax, 'YTick', [], 'YColor', 'none', 'XLim', [0 gm], 'YLim', [-0.1 NG + 0.9]);
    xlabel(ax, sprintf('Hourly idle training capacity in year %d (GW)', NY), 'Color', S.INK);
    savefig_(f, fd, 'K03_idle_training_ridges', false);
catch ME; fprintf('  [对比图] K03 跳过: %s (行%d)\n', ME.message, ME.stack(1).line); end

%% ── K04 东部储能逐年三维切片: x 年份, y 方法, z 东部储能, 颜色 h = 资产回收缺口 ──
try
    [f, ax] = fig3(S, 16.5, 11.5); [~, od] = sort(M.Ee(end,:));                 % 期末储能小者在前
    lim = [min(M.loss(:)) max(M.loss(:))];
    for k = 1:NG; slice3(ax, S, y, find(od == k) - 1, M.Ee(:,k), M.loss(:,k), 0); end
    cb = cbar_(ax, S, S.SEQ, lim, 'Asset recovery gap (billion CNY)');
    set(ax, 'XLim', [1 NY], 'YLim', [-0.4 NG - 0.6], 'ZLim', [0 max(M.Ee(:)) * 1.05], 'YTick', 0:NG-1, 'YTickLabel', lab(od), 'FontSize', fz(6.5));
    xlabel(ax, 'Planning year', 'Color', S.INK); zlabel(ax, 'Eastern storage (GWh)', 'Color', S.INK);
    view(ax, 30, 24); shrink_cb(cb, 0.6);
    savefig_(f, fd, 'K04_east_storage_slices', true);
catch ME; fprintf('  [对比图] K04 跳过: %s (行%d)\n', ME.message, ME.stack(1).line); end

%% ── K05 资产级NPV差值矩阵(对比方法 − 本文, 亿元) ──
try
    NA = M.NPVa(:, 1:6); dif = NA(2:end, :) - NA(1, :); lm = max(abs(dif(:))); if ~(lm > 0); lm = 1; end
    % 行 = 资产(括号内为本文方法该资产NPV), 列 = 对比方案; 格内为对比方案 − 本文方法
    f = newfig(S, 16, 10); ax = axes(f); hold(ax, 'on'); ax.Position = [0.30 0.06 0.48 0.80];
    for i = 1:6
        for j = 1:NG-1
            patch(ax, j + [-0.5 0.5 0.5 -0.5], i + [-0.5 -0.5 0.5 0.5], dif(j,i), 'EdgeColor', [1 1 1], 'LineWidth', 2);
            tc = S.INK; if abs(dif(j,i)) > 0.55 * lm; tc = [1 1 1]; end
            text(ax, j, i, sprintf('%+.1f', dif(j,i)), 'HorizontalAlignment', 'center', 'FontSize', fz(7.5), 'Color', tc);
        end
    end
    colormap(ax, S.DIV); clim_(ax, [-lm lm]);
    yt = arrayfun(@(i) sprintf('%s (%.1f)', S.ASSETS{i}, NA(1,i)), 1:6, 'Uni', 0);
    set(ax, 'XTick', 1:NG-1, 'XTickLabel', lab(2:end), 'XAxisLocation', 'top', 'YTick', 1:6, 'YTickLabel', yt, 'YDir', 'reverse', 'TickLength', [0 0], ...
        'XLim', [0.5 NG - 0.5], 'YLim', [0.5 6.5], 'FontName', S.font, 'FontSize', fz(7), 'XColor', S.INK, 'YColor', S.INK, 'Box', 'off');
    try; ax.XRuler.Axle.LineStyle = 'none'; ax.YRuler.Axle.LineStyle = 'none'; catch; end
    cb = colorbar(ax); cb.Color = S.SOFT; cb.FontSize = fz(6.5); cb.TickDirection = 'out';
    cb.Label.String = 'Asset NPV relative to proposed (billion CNY)'; cb.Label.Color = S.INK; cb.Label.FontSize = fz(8); try; cb.Box = 'off'; catch; end
    savefig_(f, fd, 'K05_asset_npv_gap_matrix', false);
catch ME; fprintf('  [对比图] K05 跳过: %s (行%d)\n', ME.message, ME.stack(1).line); end

%% ── 逐年对比数据表(长表) ──
fid = fopen(fullfile(root, 'simulation_output', 'comparison_yearly.csv'), 'w');
if fid > 0
    fprintf(fid, 'Scheme,Year,Cumulative NPV (billion CNY),Cumulative investment (billion CNY),Capital efficiency,Eastern storage (GWh),Training capacity (MW),B-class violation (%%),C-class migration (%%),Gap (%%),Asset recovery gap (billion CNY)\n');
    for k = 1:NG
        for q = 1:NY
            fprintf(fid, '%s,%d,%.2f,%.2f,%.4f,%.2f,%.1f,%.3f,%.2f,%.3f,%.2f\n', lab{k}, q, M.npv(q,k), M.inv(q,k), ...
                M.npv(q,k) / max(M.inv(q,k), 1), M.Ee(q,k), M.WT(q,k), M.Bv(q,k), M.Cm(q,k), M.gap(q,k), M.loss(q,k));
        end
    end
    fclose(fid);
end
fprintf('[对比图] K01–K05 已生成(%s), 逐年数据 comparison_yearly.csv\n', fd);
fprintf('[对比图] 期末名次(本文): %s\n', strjoin(arrayfun(@(m) sprintf('%s=%d', mn{m}, Rk(1,m)), 1:numel(mn), 'Uni', 0), ' | '));
end

% ═══════════════════════════════ 工具函数(与 plot_paper_figures 同一风格) ═══════════════════════════════
function S = sty()
fl = listfonts; cand = {'Arial', 'Helvetica', 'Liberation Sans'};
S.font = get(groot, 'defaultAxesFontName');
for k = 1:numel(cand); if any(strcmpi(fl, cand{k})); S.font = cand{k}; break; end; end
h = @hex2rgb;
S.INK = h('#2B3A44'); S.SOFT = h('#6B7780'); S.LINE = h('#B9C0C4'); S.GRID = h('#ECEFEC');
S.NAVY = h('#24425F'); S.BLUE = h('#3B6E8F'); S.TEAL = h('#4E9A92'); S.SAGE = h('#9DBF9E'); S.TERRA = h('#C2674A'); S.GRAY = h('#8A949C');
S.SEQ = cmapn({'#F4F1E6','#D6E6DA','#9BC7BB','#5FA39A','#2F6E80','#1E3F5A'});
S.DIV = cmapn({'#2F6E80','#7FB3AE','#F4F1E6','#E3A07E','#B4533A'});
S.TER = cmapn({'#1E3F5A','#2F6E80','#5FA39A','#BFD8C4','#EFE6C8','#E3C27E','#D08A5B','#B4533A'});
S.ASSETS = {'Training','Inference','Green power','W. storage','E. storage','HVDC'};
try; set(groot, 'defaultAxesFontName', S.font, 'defaultTextFontName', S.font, 'defaultLegendFontName', S.font); catch; end
end

function c = hex2rgb(s)
c = sscanf(s(2:end), '%2x%2x%2x', [1 3]) / 255;
end

function M = cmapn(hexes)
C = cell2mat(cellfun(@hex2rgb, hexes(:), 'Uni', 0)); M = interp1(linspace(0, 1, size(C, 1)), C, linspace(0, 1, 256)');
end

function f = newfig(S, w, h)
vis = 'off'; if isappdata(0, 'pf_show') && getappdata(0, 'pf_show'); vis = 'on'; end
f = figure('Visible', vis, 'Color', 'w', 'Units', 'centimeters', 'Position', [2 2 w h]);
set(f, 'DefaultAxesFontName', S.font, 'DefaultTextFontName', S.font);
end

function [f, ax] = fig3(S, w, h)
f = newfig(S, w, h); ax = axes(f);
set(ax, 'FontName', S.font, 'FontSize', fz(7), 'Color', 'none', 'XColor', S.SOFT, 'YColor', S.SOFT, 'ZColor', S.SOFT, ...
    'GridColor', [0.80 0.82 0.83], 'GridAlpha', 0.55, 'LineWidth', lz(0.5), 'TickDir', 'out', 'Box', 'off');
grid(ax, 'on'); hold(ax, 'on');
end

function style2(ax, S, gridy)
set(ax, 'FontName', S.font, 'FontSize', fz(8), 'XColor', S.SOFT, 'YColor', S.SOFT, 'LineWidth', lz(0.6), 'TickDir', 'out', ...
    'Box', 'off', 'TickLength', [0.008 0.008], 'Layer', 'bottom', 'GridColor', 0.94 * [1 1 1], 'GridAlpha', 1);
if gridy; ax.YGrid = 'on'; end
hold(ax, 'on');
end

function cb = cbar_(ax, S, cmap, lim, label)
colormap(ax, cmap); if ~(lim(2) > lim(1)); lim(2) = lim(1) + 1; end; clim_(ax, lim);
cb = colorbar(ax); cb.Color = S.SOFT; cb.FontSize = fz(6.5); cb.TickDirection = 'out'; cb.LineWidth = lz(0.4);
cb.Label.String = label; cb.Label.Color = S.INK; cb.Label.FontSize = fz(8); try; cb.Box = 'off'; catch; end
end

function shrink_cb(cb, fr)
p = cb.Position; cb.Position = [p(1) + 0.02, p(2) + p(4) * (1 - fr) / 2, p(3) * 0.8, p(4) * fr];
end

function slice3(ax, S, x, yk, z, h, z0)
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

function c = cmap_rgb(M, s)
s = min(max(s(:), 0), 1); s(~isfinite(s)) = 0; c = M(1 + round(s * (size(M, 1) - 1)), :);
end

function v = sm(x, y, xf)
x = double(x(:)); y = double(y(:)); ok = isfinite(x) & isfinite(y);
if nnz(ok) < 2; v = nan(size(xf)); return; end
v = pchip(x(ok), y(ok), xf); v(xf < min(x(ok)) | xf > max(x(ok))) = NaN;
end

function y = gauss1(x, sig)
% 一维高斯平滑(边界复制)
x = double(x(:)); ok = isfinite(x); if ~all(ok) && any(ok); x(~ok) = interp1(find(ok), x(ok), find(~ok), 'nearest', 'extrap'); end
r = ceil(4 * sig); k = exp(-0.5 * ((-r:r)' / sig).^2); k = k / sum(k);
y = conv([repmat(x(1), r, 1); x; repmat(x(end), r, 1)], k, 'valid');
end

function d = kde1(x, g, bw)
x = double(x(:)); x = x(isfinite(x)); g = double(g(:)');
if isempty(x); d = zeros(size(g)); return; end
if numel(x) > 4000; s = RandStream('mt19937ar', 'Seed', 1); x = x(randperm(s, numel(x), 4000)); end
span = max(g) - min(g); sd = std(x); if sd <= 0; sd = span; end
h = max(bw * sd, 0.012 * span); z = (g - x) / h;
d = sum(exp(-0.5 * z.^2), 1) / (numel(x) * h * sqrt(2*pi));
end

function q = qtile(v, p)
v = sort(double(v(isfinite(v)))); v = v(:); n = numel(v);
if n == 0; q = nan(size(p)); return; end
if n == 1; q = v * ones(size(p)); return; end
q = interp1(linspace(0, 1, n)', v, p);
end

function [CF, NPVa] = read_recovery(fn)
CF = nan(0, 7); NPVa = nan(1, 7); C = {};
if exist(fn, 'file'); try; C = readcell(fn, 'Delimiter', ',', 'Encoding', 'UTF-8'); catch; try; C = readcell(fn, 'Delimiter', ','); catch; end; end; end
for r = 2:size(C, 1)
    s = cstr(C{r,1}); v = nan(1, 7);
    for c = 2:min(8, size(C, 2)); v(c-1) = tonum(C{r,c}); end
    if startsWith(s, 'Y'); y = str2double(regexprep(s, '[^0-9]', '')); if isfinite(y) && y >= 1; CF(y,:) = v; end
    elseif startsWith(s, 'NPV'); NPVa = v; end
end
end

function s = cstr(x)
if isa(x, 'missing') || (isstring(x) && any(ismissing(x))); s = ''; return; end
if isnumeric(x) || islogical(x); s = num2str(x); return; end
s = strtrim(char(string(x)));
end

function v = tonum(x)
if isnumeric(x) || islogical(x); v = double(x); elseif isa(x, 'missing'); v = NaN; else; v = str2double(string(x)); end
if isempty(v) || ~isscalar(v); v = NaN; end
end
