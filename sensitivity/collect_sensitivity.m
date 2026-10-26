function T = collect_sensitivity(root, mode)
%% 汇总敏感性结果 → sens_<mode>/sensitivity.csv (基准水平读取 simulation_output/ 与 cmp_<组名>/)
%  mode = 'expost'(默认, run_sensitivity) 或 'replan'(run_sensitivity_replan)
%  T: 结构体数组, 每个元素为一个(参数, 水平, 方案)组合的期末指标; 缺失结果记为NaN
if nargin < 1 || isempty(root); root = sens_root(); end
if nargin < 2 || isempty(mode); mode = 'expost'; end
sd = fullfile(root, ['sens_' mode]);
addpath(root);
SP = sens_params(mode); pn = fieldnames(SP)';
C = comparison_cases(); sn = [{'Proposed'}, fieldnames(C)'];
lab = containers.Map(sn, {'本文方法', 'S1 AHGF', 'S2 PO-VFS-FBR', 'S3 AFZ-VFS-SHAP', 'S4 MRP', 'S5 WM'});
T = struct('param', {}, 'pname', {}, 'level', {}, 'scheme', {}, 'npv', {}, 'inv', {}, 'eff', {}, 'irr', {}, ...
           'gap', {}, 'Ee', {}, 'Bv', {}, 'rel', {});
% 基准
for s = 1:numel(sn)
    if strcmp(sn{s}, 'Proposed'); d = fullfile(root, 'simulation_output'); else; d = fullfile(root, ['cmp_' sn{s}]); end
    T(end+1) = row_('base', '基准', NaN, sn{s}, sens_metrics(d, 0.08)); %#ok<AGROW>
end
% 扰动
for ip = 1:numel(pn)
    p = pn{ip};
    for il = 1:numel(SP.(p).levels)
        lev = SP.(p).levels(il); r = 0.08; if strcmp(p, 'disc'); r = lev; end
        for s = 1:numel(sn)
            d = fullfile(sd, sens_tag(p, lev, sn{s}));
            T(end+1) = row_(p, SP.(p).name, lev, sn{s}, sens_metrics(d, r)); %#ok<AGROW>
        end
    end
end
% 相对本文方法的累计NPV差值率(同一参数水平内比较)
for k = 1:numel(T)
    i0 = find(strcmp({T.param}, T(k).param) & strcmp({T.scheme}, 'Proposed') & ...
              (isnan([T.level]) & isnan(T(k).level) | [T.level] == T(k).level), 1);
    if ~isempty(i0) && isfinite(T(i0).npv) && T(i0).npv ~= 0
        T(k).rel = 100 * (T(k).npv - T(i0).npv) / abs(T(i0).npv);
    end
end
% 写CSV
if ~exist(sd, 'dir'); mkdir(sd); end
fid = fopen(fullfile(sd, 'sensitivity.csv'), 'w', 'n', 'UTF-8');
fprintf(fid, '参数,参数名,水平,方案,累计NPV_亿元,累计投资_亿元,资本效率,IRR_%%,资产回收缺口_亿元,东部储能_GWh,B类SLA违约率均值_%%,累计NPV相对本文_%%\n');
for k = 1:numel(T)
    fprintf(fid, '%s,%s,%s,%s,%.1f,%.1f,%.3f,%.2f,%.1f,%.1f,%.2f,%.1f\n', T(k).param, T(k).pname, lvstr(T(k)), lab(T(k).scheme), ...
        T(k).npv, T(k).inv, T(k).eff, T(k).irr, T(k).gap, T(k).Ee, T(k).Bv, T(k).rel);
end
fclose(fid);
% 控制台摘要
fprintf('\n[敏感性汇总] %s\n', fullfile(sd, 'sensitivity.csv'));
fprintf('  %-14s %-8s %-14s %9s %9s %7s %9s\n', '参数', '水平', '方案', 'NPV/亿', '投资/亿', '效率', '相对本文');
for k = 1:numel(T)
    if ~isfinite(T(k).npv); continue; end
    fprintf('  %-14s %-8s %-14s %9.1f %9.1f %7.3f %8.1f%%\n', T(k).pname, lvstr(T(k)), lab(T(k).scheme), ...
        T(k).npv, T(k).inv, T(k).eff, T(k).rel);
end
miss = arrayfun(@(t) ~isfinite(t.npv), T);
if any(miss); fprintf('  未完成组合: %d 个\n', nnz(miss)); end
end

% ─────────────────────────────────────────────────────────────────────────
function t = row_(p, pname, lev, s, m)
t = struct('param', p, 'pname', pname, 'level', lev, 'scheme', s, 'npv', m.npv, 'inv', m.inv, 'eff', m.eff, ...
           'irr', m.irr, 'gap', m.gap, 'Ee', m.Ee, 'Bv', m.Bv, 'rel', NaN);
end

function s = lvstr(t)
if ~isfinite(t.level); s = '基准'; return; end
if strcmp(t.param, 'disc'); s = sprintf('%.0f%%', 100 * t.level); else; s = sprintf('×%.1f', t.level); end
end

function m = sens_metrics(d, r)
%% 读取一次仿真的期末指标; 口径与表12一致(资产回收缺口 = 各亏损资产规划期内累计折现运营价值之和的绝对值, 含通信路由)
m = struct('npv', NaN, 'inv', NaN, 'eff', NaN, 'irr', NaN, 'gap', NaN, 'Ee', NaN, 'Bv', NaN);
f = fullfile(d, 'summary.csv'); if ~exist(f, 'file'); return; end
S = readmatrix(f, 'NumHeaderLines', 1); if isempty(S); return; end
m.npv = S(end, 13); m.inv = sum(S(:, 7), 'omitnan'); m.eff = m.npv / max(m.inv, eps);
m.irr = 100 * S(end, 15); m.Ee = S(end, 6) / 1e3; m.Bv = 100 * mean(S(:, 20), 'omitnan');
CF = read_cf(fullfile(d, 'asset_recovery.csv'));
if ~isempty(CF)
    disc = (1 + r) .^ -(1:size(CF, 1))';
    m.gap = -sum(min(0, sum(CF .* disc, 1, 'omitnan')));
end
end

function CF = read_cf(fn)
CF = zeros(0, 7); C = {};
if ~exist(fn, 'file'); return; end
try; C = readcell(fn, 'Delimiter', ',', 'Encoding', 'UTF-8'); catch; try; C = readcell(fn, 'Delimiter', ','); catch; end; end
for i = 2:size(C, 1)
    s = cstr(C{i, 1});
    if startsWith(s, 'Y')
        y = str2double(regexprep(s, '[^0-9]', ''));
        if isfinite(y) && y >= 1
            v = nan(1, 7);
            for c = 2:min(8, size(C, 2)); v(c-1) = tonum(C{i, c}); end
            CF(y, :) = v;
        end
    end
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
