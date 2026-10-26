function run_sensitivity(params, schemes)
%% 关键参数敏感性分析(事后评估, 不重跑仿真, 约几分钟)
%  规划方案与8760h运行结果保持不变, 读取各方案已有检查点, 在扰动参数下重新核算现金流、NPV与资产回收缺口
%  run_sensitivity                          % 4个参数 × 2个水平 × 6个方案, 全部读已有结果
%  run_sensitivity({'disc','stor'})         % 只算指定参数
%
%  参数(水平见 sens_params('expost')):
%    disc   折现率        6% / 10%
%    stor   储能投资成本  ×0.8 / ×1.2
%    comp   算力投资成本  ×0.8 / ×1.2  (训练中心与推理中心)
%    green  绿电投资成本  ×0.8 / ×1.2  (风电与光伏)
%
%  读取: simulation_output/checkpoint/ckpt_latest.mat 与 cmp_<组名>/checkpoint/ckpt_latest.mat
%  输出: sens_expost/<参数>_<水平>_<方案>/summary.csv, asset_recovery.csv
%        sens_expost/sensitivity.csv; 图 simulation_output/paper_figs/S01_sensitivity_matrix.png/.pdf
%  首先对各方案做一次基准复算, 并与原 summary.csv 的累计NPV对照, 确认口径一致
%  需要随参数重新规划的分析(需求增速、token效率增速)见 run_sensitivity_replan(需重跑仿真)
[root, pkg] = sens_root();
addpath(pkg);
addpath(root, fullfile(root, 'data_loader'), fullfile(root, 'output_module'), fullfile(root, 'utils'));
sens_install(root, pkg);
fprintf('[敏感性] 工程目录: %s\n', root);
SP = sens_params('expost');
if nargin < 1 || isempty(params); params = fieldnames(SP)'; end
if ischar(params); params = {params}; end
C = comparison_cases();
if nargin < 2 || isempty(schemes); schemes = [{'Proposed'}, fieldnames(C)']; end
if ischar(schemes); schemes = {schemes}; end
old = cd(root); P0 = init_parameters(); cd(old);
sd = fullfile(root, 'sens_expost'); if ~exist(sd, 'dir'); mkdir(sd); end

for is = 1:numel(schemes)
    s = schemes{is};
    if strcmp(s, 'Proposed'); d = fullfile(root, 'simulation_output'); else; d = fullfile(root, ['cmp_' s]); end
    ck = fullfile(d, 'checkpoint', 'ckpt_latest.mat');
    if exist(ck, 'file') ~= 2; fprintf('[敏感性] %s 缺少检查点 %s, 跳过\n', s, ck); continue; end
    t = load(ck, 'results_yearly'); RY = t.results_yearly; if ~iscell(RY); RY = num2cell(RY); end
    ny = nnz(~cellfun(@isempty, RY));
    if ny < P0.N_year; fprintf('[敏感性] %s 检查点只有%d年(需%d年), 跳过\n', s, ny, P0.N_year); continue; end
    Pb = P0;
    if ~strcmp(s, 'Proposed'); f = fieldnames(C.(s)); for k = 1:numel(f); Pb.(f{k}) = C.(s).(f{k}); end; end
    % 基准复算与原结果对照
    od = fullfile(sd, ['base_' s]);
    if evaluate_(RY, Pb, od)
        n0 = read_npv_(fullfile(d, 'summary.csv')); n1 = read_npv_(fullfile(od, 'summary.csv'));
        flag = ''; if abs(n1 - n0) > 0.5; flag = '  <-- 与原结果不一致, 请检查'; end
        fprintf('[敏感性] %-18s 基准复算: 原累计NPV %.1f亿, 复算 %.1f亿%s\n', s, n0, n1, flag);
    end
    % 扰动
    for ip = 1:numel(params)
        p = params{ip};
        if ~isfield(SP, p); error('sens:param', '未知参数: %s (可选: %s)', p, strjoin(fieldnames(SP)', ', ')); end
        for il = 1:numel(SP.(p).levels)
            lev = SP.(p).levels(il);
            P = Pb; ov = sens_override(p, lev, P0); f = fieldnames(ov);
            for k = 1:numel(f); P.(f{k}) = ov.(f{k}); end
            od = fullfile(sd, sens_tag(p, lev, s));
            if evaluate_(RY, P, od)
                fprintf('[敏感性] %-18s %-8s 累计NPV %.1f亿\n', s, sens_tag(p, lev, ''), read_npv_(fullfile(od, 'summary.csv')));
            end
        end
    end
end
collect_sensitivity(root, 'expost');
try
    plot_sensitivity_figure(root, true, 'expost');
catch ME
    fprintf('[敏感性] 绘图跳过: %s\n', ME.message);
end
end

% ─────────────────────────────────────────────────────────────────────────
function ok = evaluate_(RY, P, od)
%% 在给定参数下复算 summary.csv 与 asset_recovery.csv(与主程序后处理同一口径)
ok = false;
if ~exist(od, 'dir'); mkdir(od); end
P.out_dir = od;
try
    evalc('write_summary_csv(RY, P);');
    Pev = P; Pev.value_model = 'full';            % 与主程序一致: 期末评价统一按全口径价值
    evalc('compute_asset_attribution(RY, Pev);');
    ok = true;
catch ME
    fprintf('[敏感性] 复算失败(%s): %s\n', od, ME.message);
end
end

function v = read_npv_(f)
v = NaN; if exist(f, 'file') ~= 2; return; end
S = readmatrix(f, 'NumHeaderLines', 1); if ~isempty(S); v = S(end, 13); end
end
