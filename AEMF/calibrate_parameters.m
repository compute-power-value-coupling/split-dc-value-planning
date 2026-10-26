%% =========================================================================
%  calibrate_parameters.m — 关键参数贝叶斯优化校准
%
%  用MATLAB bayesopt对三个关键参数进行数据驱动校准：
%    1. P.DRO.C_0      — Wasserstein球半径系数（影响鲁棒性保守程度）
%    2. P.DRO.d_dim    — 特征维度（影响epsilon_1收缩速率）
%    3. P.alpha_g      — 绿电经济估算系数（影响dG方向VAIC割）
%
%  目标：最小化单年仿真的Benders最终gap（反映算法收敛质量）
%
%  数值依据：
%    C_0 ∈ [0.05, 0.50]：来源于Mohajerin Esfahani & Kuhn (2018)建议范围
%    d_dim ∈ [3, 15]：与特征向量维度(5)匹配，通常取d=5±2
%    alpha_g ∈ [0.02, 0.15]：替代绿电套利收益的经济系数
%% =========================================================================
function P_calibrated = calibrate_parameters(P, hist_data, n_trials)

if nargin < 3; n_trials = 20; end  % 贝叶斯优化试验次数

fprintf('[BayesOpt] 开始参数校准 (%d次试验)...\n', n_trials);

%% ── 定义搜索空间 ──────────────────────────────────────────────────────
params = [
    optimizableVariable('C_0',     [0.05, 0.50], 'Type','real')
    optimizableVariable('d_dim',   [3,   12],    'Type','integer')
    optimizableVariable('alpha_g', [0.02, 0.15], 'Type','real')
];

%% ── 目标函数：单年Benders gap ──────────────────────────────────────────
objective = @(x) eval_benders_gap(x, P, hist_data);

%% ── 贝叶斯优化 ────────────────────────────────────────────────────────
results = bayesopt(objective, params, ...
    'MaxObjectiveEvaluations', n_trials, ...
    'IsObjectiveDeterministic', false, ...
    'ExplorationRatio', 0.5, ...
    'Verbose', 1, ...
    'PlotFcn', {});   % 关闭绘图（仿真环境中）

%% ── 提取最优参数 ──────────────────────────────────────────────────────
best = bestPoint(results);
P_calibrated = P;
P_calibrated.DRO.C_0   = best.C_0;
P_calibrated.DRO.d_dim = best.d_dim;
P_calibrated.alpha_g   = best.alpha_g;

fprintf('[BayesOpt] 最优参数: C_0=%.3f, d_dim=%d, alpha_g=%.3f\n', ...
    best.C_0, best.d_dim, best.alpha_g);
fprintf('  最优目标值(gap): %.4f\n', min(results.ObjectiveTrace));
end


%% ── 内部目标函数：跑单年Benders返回gap ──────────────────────────────
function gap = eval_benders_gap(x, P, hist_data)
P_try = P;
P_try.DRO.C_0   = x.C_0;
P_try.DRO.d_dim = x.d_dim;
P_try.alpha_g   = x.alpha_g;

try
    % 只跑Y1（用于快速评估，不跑全15年）
    AEMF = update_AEMF(hist_data, 1, P_try, struct());
    task_template = load_task_template(P_try);
    demand_y = scale_demand_by_growth(task_template, 1.0, 1, P_try);
    state = struct('z_cum',zeros(P_try.N_west,1),'W_T_cum',zeros(P_try.N_west,1), ...
        'W_I_cum',zeros(P_try.N_east,1),'G_cum',zeros(P_try.N_west,1), ...
        'E_w_cum',zeros(P_try.N_west,1),'E_e_cum',zeros(P_try.N_east,1), ...
        'dL_cum',zeros(P_try.N_west,P_try.N_east));

    P_try.max_iter = 8;   % 快速评估用8轮
    [~, ben_info] = inner_benders_loop(P_try, AEMF, demand_y, state, 1);
    gap = ben_info.final_gap;
catch
    gap = 1.0;  % 失败时返回最大gap
end
end
