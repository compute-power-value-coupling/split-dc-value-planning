%% =========================================================================

%  main_15year_simulation.m  —  15年长期仿真主循环
%  ----------------------------------------------------------------
%  完整执行论文SAIL-BD三层算法（AEMF+VAIC+DACS）的15年长期规划仿真
%  
%  核心特征:
%    1. 投资决策事前不可逆: x_cumulative = max(x_cumulative, x_new)
%    2. 环境认知事后可更新: AEMF逐年基于扩充数据重建模糊集
%    3. 三层算法严格按论文公式实现，不简化
%    4. 单位统一: 全部成本/收益以"万元"为单位，时间以"小时"
%
%  对应论文: 表3全部算法，公式(1)-(36)
%% =========================================================================
if ~exist('CMP_RUNNING','var'); clear; end; clc; close all;
fprintf('╔══════════════════════════════════════════════════════════╗\n');
fprintf('║ BUILD: v8.30 | 主程序+五组单因素对比           ║\n');
fprintf('║ 校验: C_var_om存在=%d (0=旧build, 请重新下载zip)           ║\n', ...
    exist('simulate_actual_operation','file')>0 && ...
    contains(fileread(which('simulate_actual_operation')),'C_var_om'));
fprintf('╚══════════════════════════════════════════════════════════╝\n');

% 添加子目录到路径
addpath('data_loader');
addpath('AEMF');
addpath('VAIC');
addpath('DACS');
addpath('benders');
addpath('output_module');
addpath('utils');

fprintf('================================================================\n');
fprintf('  算力-电力协同规划15年长期仿真 (AEMF+VAIC+DACS)\n');
fprintf('================================================================\n');
fprintf('  启动时间: %s\n', datestr(now,'yyyy-mm-dd HH:MM:SS'));

%% [1/4] 全局参数与数据加载
fprintf('\n[1/4] 加载参数与初始历史数据...\n');
P = init_parameters();
% 对比实验配置(由 run_comparison 设置; 单独运行主程序时为空, 即本文方法)
global CMP_CASE
if ~isempty(CMP_CASE) && isstruct(CMP_CASE)
    fo_ = fieldnames(CMP_CASE);
    for k_ = 1:numel(fo_); P.(fo_{k_}) = CMP_CASE.(fo_{k_}); end
    fprintf('[对比组] %s\n', strjoin(fo_', ', '));
end
hist_data = load_initial_history(P);
P.season = build_season_factors(hist_data, P);   % 规划运行模型12个月代表周的季节因子
growth_forecast = load_growth_forecast(P);
task_template = load_task_template(P);
comm_delay = load_comm_delay_matrix(P);
P.comm_delay = comm_delay;     % 注入到P, 供solve_minimum_cost_flow使用
fprintf('       初始历史数据: %d小时 风光+电价+%d年算力需求\n', ...
    size(hist_data.cf_wind,1), length(hist_data.demand_yearly));
fprintf('       15年增长预测: 已加载\n');

%% [2/4] 状态变量初始化
fprintf('\n[2/4] 初始化累计状态变量...\n');

% ── 贝叶斯参数校准（仿真开始前，基于初始历史数据优化关键参数）──────────
% 校准 DRO.C_0, DRO.d_dim, alpha_g 三个敏感参数
% n_trials=15：15次试验在工程上已足够，耗时约2-5分钟
if isfield(P,'run_calibration') && P.run_calibration
    fprintf('  [BayesOpt] 校准关键参数（%d次试验）...\n', P.calib_trials);
    addpath('AEMF');
    P = calibrate_parameters(P, hist_data, P.calib_trials);
    fprintf('  [BayesOpt] 完成: C_0=%.3f d_dim=%d alpha_g=%.3f\n', ...
        P.DRO.C_0, P.DRO.d_dim, P.alpha_g);
else
    fprintf('  [跳过校准] 使用 init_parameters 默认值 (run_calibration=false)\n');
end
% 累计状态(跨年保留, 已建容量不可拆除)
state.z_cum   = zeros(P.N_west, 1);     % 累计选址(0/1)
state.W_T_cum = zeros(P.N_west, 1);     % 累计训练容量(MW)
state.cum_tokens = 0;                   % 累计token产出(Wright学习曲线经验存量)
P.price_endo_mult = 1.0;                % 内生价格乘子(市场出清态)
state.W_I_cum = zeros(P.N_east, 1);     % 累计推理容量(MW)
state.G_cum   = zeros(P.N_west, 1);     % 累计绿电装机(MW)
state.E_w_cum = zeros(P.N_west, 1);     % 西部累计储能(MWh)
state.E_e_cum = zeros(P.N_east, 1);     % 东部累计储能(MWh)
state.dL_cum  = zeros(P.N_west, P.N_east);  % HVDC扩容(NI×NJ矩阵，与选址耦合)
state.rt_cum  = zeros(P.N_west, P.N_east);  % 通信路由升级(边界2: 时延投资)
state.net_reinf_cum = 0;                    % 规划越限对应的电网加强容量(MW)
P.comm_delay_base = P.comm_delay;           % 基准时延(路由升级的参照)

% 结果容器
results_yearly = cell(P.N_year, 1);
% 世界模型经验缓冲区(创新三): 样本/预测/检验/反事实边际
wmb = struct('samples',[], 'pred',{cell(P.N_year+1,1)}, 'eval',zeros(0,10), ...
             'pairs',zeros(0,3), 'kbar',[], 'cf',nan(P.N_year,7), ...
             'log',nan(P.N_year,4), 'law',[], 'invlaw',zeros(0,5), 'cand_eval',{cell(P.N_year,1)}, 'cand_src',zeros(P.N_year,1), 'cand',nan(P.N_year,3));
AEMF_prev = struct();  % 上一年AEMF(含RL Q表,供RL在线学习)

fprintf('       累计状态: z=[0,0,0,0], W_T=[0,0,0,0] MW\n');

%% [3/4] 15年主循环
fprintf('\n[3/4] 进入15年规划-运行迭代主循环...\n');
total_tic = tic;

% ── RL预训练模型检测 ────────────────────────────────────────────────────
% 若rl_agent_pretrained.mat不存在，自动运行离线预训练（约5-10分钟）
rl_on_ = isfield(P,'enable_RL_cut') && P.enable_RL_cut;
if rl_on_ && ~exist('rl_agent_pretrained.mat','file')
    fprintf('[RL预训练] 未找到预训练模型，开始离线训练200轮...\n');
    pretrain_RL_agent(P, 200);
elseif rl_on_
    fprintf('[RL预训练] 检测到预训练模型，将在首年自动加载(注意: Q修正前训练的旧模型已失配, 建议删除后重训)\n');
end

% ── 逐年检查点/续跑 ────────────────────────────────────────────────────
% 每年结束保存全部跨年状态; P.resume=true时从最近检查点继续(可先修改代码/参数再续跑)
demand_fac = [];
ck_dir  = fullfile(P.out_dir, 'checkpoint');
ck_file = fullfile(ck_dir, 'ckpt_latest.mat');
BUILD_TAG = 'v8.30';   % 模型版本: 检查点版本不同则不续跑
dyn_fields = {'wm','recovery_gap','price_endo_mult','u_ref_ema','comm_delay','comm_delay_base', ...
              'cum_tokens_hint','soc_init_frac','task_ratio','vaic_force_classic','calib_elec_east','calib_rev_west','lp_mig_share','lp_boff_share'};
start_year = 1;
if isfield(P,'resume') && P.resume && exist(ck_file,'file')
    ckv_ = load(ck_file);
    if ~isfield(ckv_,'build_tag') || ~strcmp(ckv_.build_tag, BUILD_TAG)
        bt_ = '旧版本'; if isfield(ckv_,'build_tag'); bt_ = ckv_.build_tag; end
        fprintf('[续跑] 检查点来自%s, 与当前%s不一致, 从Y1重新开始\n', bt_, BUILD_TAG);
        movefile(ck_file, fullfile(ck_dir, sprintf('ckpt_old_%s.mat', datestr(now,'yyyymmdd_HHMMSS'))));
    end
    clear ckv_
end
if isfield(P,'resume') && P.resume && exist(ck_file,'file')
    ck = load(ck_file);
    state = ck.state; results_yearly = ck.results_yearly; wmb = ck.wmb;
    AEMF_prev = ck.AEMF_prev; hist_data = ck.hist_data; demand_fac = ck.demand_fac;
    for k_ = 1:numel(dyn_fields)                      % 动态状态覆盖到当前(可能已修订的)参数上
        if isfield(ck.Pdyn, dyn_fields{k_}); P.(dyn_fields{k_}) = ck.Pdyn.(dyn_fields{k_}); end
    end
    if isfield(ck,'rng_state'); rng(ck.rng_state); end
    start_year = ck.year + 1;
    fprintf('[续跑] 从检查点恢复: 已完成Y%d, 从Y%d继续 (%s)\n', ck.year, start_year, ck_file);
    clear ck
end

sd0_ = 20260101; if isfield(P,'seed'); sd0_ = P.seed; end
global GRB_THREADS
GRB_THREADS = 0; if isfield(P,'gurobi_threads'); GRB_THREADS = P.gurobi_threads; end
for year = start_year:P.N_year
    rng(sd0_ + 1000*year, 'twister');   % 逐年固定种子: 一次跑完与断点续跑结果完全一致, 不同种子用于稳健性检验
    fprintf('\n=== Year %d/%d ===\n', year, P.N_year);
    year_tic = tic;
    
    % ── 步骤1: AEMF年度更新 ───────────────────────────────────────────
    AEMF = update_AEMF(hist_data, year, P, AEMF_prev);  % 传上一年AEMF含RL Q表
    % VUFP闭环: 上一年运行层真实迁移矩阵→本年图传播边权(价值场随迁移演化)
    if year > 1 && ~isempty(results_yearly{year-1}) ...
            && isfield(results_yearly{year-1}, 'actual') ...
            && isfield(results_yearly{year-1}.actual, 'migration_OD')
        AEMF.migration_OD_prev = results_yearly{year-1}.actual.migration_OD;
    end
    if year > 1 && ~isempty(results_yearly{year-1}) ...
            && isfield(results_yearly{year-1},'ben_info') ...
            && isfield(results_yearly{year-1}.ben_info,'w_field')
        AEMF.w_field_prev = results_yearly{year-1}.ben_info.w_field;  % WGF年际记忆
    end
    if ~isfield(hist_data, 'eps1_init') && isfield(AEMF, 'epsilon_1')
        hist_data.eps1_init = AEMF.epsilon_1;   % 首年记录基准(可选)
    end
    fprintf('  [AEMF] eps_1=%.4f (N_1=%d) | 矩区间: rho=[%.2f,%.2f]\n', ...
        AEMF.epsilon_1, AEMF.N_1, AEMF.mu_rho_L, AEMF.mu_rho_U);
    
    % ── 步骤2: 该年增长预测与算力需求时序 ─────────────────────────────
    % 年初: 已锁定路由生效(actual层与init评估的时延基准)
    P.comm_delay = route_delay_apply(P, state.rt_cum);
    if year == start_year && (~isfield(P,'enable_net_planning') || P.enable_net_planning) && ~isfield(P,'net')
        P.net = build_network_sens(P);                  % 电力层灵敏度(一次)
    end
    rho_growth = growth_forecast(year);
    % 内生需求: 增速对价格水平的弹性反馈(价格出清态偏高→采用放缓)
    if (~isfield(P,'enable_endo_demand') || P.enable_endo_demand) && year > 1
        d_mult = max(0.85, min(1.15, 1 + 0.5*(1 - P.price_endo_mult)));
        rho_growth = rho_growth * d_mult;   % 修正: 增速为率, 原式把率当倍数致符号反转(Y15出现-10%)
    end
    % Sinkhorn熵正则内生退火(系统成熟→探索性软路由→精确OT)
    eps0_ = 0.05; if isfield(P,'sinkhorn_eps0'); eps0_ = P.sinkhorn_eps0; end
    P.sinkhorn_eps = eps0_ * (0.35 + 0.65*exp(-0.18*(year-1)));
    P.task_ratio = task_ratio_at(year, P);      % 任务结构逐年演化(全部下游读取当年结构)
    [demand_y, demand_fac] = scale_demand_by_growth(task_template, rho_growth, year, P, demand_fac);
    fprintf('  [需求结构] A/B/C/D=%.2f/%.2f/%.2f/%.2f | 训练占比%.0f%%\n', ...
        P.task_ratio(1), P.task_ratio(2), P.task_ratio(3), P.task_ratio(4), 100*P.task_ratio(4));
    fprintf('  [需求] 增速=%.1f%% | 总峰值=%.0f MW\n', ...
        rho_growth*100, max(sum(demand_y,1)));
    
    % ── 步骤3-5: 内层Benders迭代 ──────────────────────────────────────
    if exist('wmb','var') && isfield(wmb,'cf') && year >= 2 && any(isfinite(wmb.cf(year-1,:)))
        P.tr_grad = wmb.cf(year-1,:);                       % 上一年真实运行的反事实边际 → 本年局部模型梯度
    end
    t_ben_ = tic;
    [x_new, ben_info] = inner_benders_loop(P, AEMF, demand_y, state, year);
    dt_ben_ = toc(t_ben_)/60;
    fprintf('  [Benders] 收敛于%d轮, gap=%.3f%%, F1_new=%.2f亿元\n', ...
        ben_info.n_iter, ben_info.final_gap*100, x_new.F1_incremental/1e4);
    if isfield(ben_info,'ub_gain'); fprintf('  [Benders] 相对初始方案改进%.1f亿/年(gap以全局割下界计, 仅作参考)\n', ben_info.ub_gain); end
    % 记录本年Benders结果到AEMF(供下一年RL奖励计算)
    AEMF.last_gap = ben_info.final_gap;
    AEMF.last_n_cuts = ben_info.n_iter;
    AEMF_prev = AEMF;
    
    % ── 步骤6: 锁定本年投资(已建容量不可撤销) ─────────────────────────
    state.z_cum   = max(state.z_cum,   x_new.z);
    state.W_T_cum = max(state.W_T_cum, x_new.W_T);
    if isfield(x_new,'net_ov') && isfield(state,'net_reinf_cum'); state.net_reinf_cum = max(state.net_reinf_cum, x_new.net_ov); end
    if isfield(x_new,'rt')
        rt_add = sum(x_new.rt(:)) - sum(state.rt_cum(:));
        state.rt_cum = max(state.rt_cum, round(x_new.rt));
        if rt_add > 0.5
            fprintf('  [路由] 本年新建直连路由 %d 对 (时延↓%.0f%%)\n', ...
                round(rt_add), 100*P.route_delay_reduction);
        end
    end
    state.W_I_cum = max(state.W_I_cum, x_new.W_I);
    state.G_cum   = max(state.G_cum,   x_new.G);
    state.E_w_cum = max(state.E_w_cum, x_new.E_w);
    state.E_e_cum = max(state.E_e_cum, x_new.E_e);
    % dL_cum：确保维度一致（dL现为NI×NJ矩阵）
    dL_new = x_new.dL;
    if ~isequal(size(dL_new), size(state.dL_cum))
        state.dL_cum = zeros(P.N_west, P.N_east);   % 维度不符时重置
    end
    assert(isequal(size(dL_new), [P.N_west, P.N_east]), ...
        'dL维度错误: 应为[%d×%d]，实为[%d×%d]', ...
        P.N_west, P.N_east, size(dL_new,1), size(dL_new,2));
    state.dL_cum = max(state.dL_cum, dL_new);
    fprintf('  [锁定] z_cum=[%s] | W_T_cum=[%s] MW\n', ...
        num2str(state.z_cum'), num2str(round(state.W_T_cum)'));
    
    % ── 步骤7: 该年实际运行模拟 ───────────────────────────────────────
    P.cum_tokens_hint = state.cum_tokens;   % Wright经验存量注入(SKU的η用)
    t_act_ = tic;
    actual_y = simulate_actual_operation(state, AEMF, P, demand_y, year, ben_info.SKU);
    dt_act_ = toc(t_act_)/60;
    % ── 闭环: 实际运行→规划模型校准(东部电费口径, 平滑更新, 有界[0.5,3]) ──
    if (~isfield(P,'enable_calib') || P.enable_calib) && isfield(ben_info,'plan_east_dbg') ...
            && isfield(actual_y,'cost_parts') && ben_info.plan_east_dbg(6) > 1
        fe_ = 1; if isfield(P,'calib_elec_east'); fe_ = P.calib_elec_east; end
        ideal_ = actual_y.cost_parts.east * fe_ / ben_info.plan_east_dbg(6);
        P.calib_elec_east = min(2, max(0.5, 0.5*fe_ + 0.5*ideal_));   % 迁移份额已由实际校准, 电价系数收窄
        fprintf('  [校准] 东部电费 实际%.0f亿/规划%.0f亿 → 规划系数%.2f\n', ...
            actual_y.cost_parts.east/1e4, ben_info.plan_east_dbg(6)/1e4, P.calib_elec_east);
    end
    % 西部价值校准: 实际西部利润(训练收入−西部电费) vs 规划LP西部利润, 平滑更新, 有界[0.3,1.5]
    if isfield(P,'enable_calib_west') && P.enable_calib_west && isfield(ben_info,'plan_Q_west') && ben_info.plan_Q_west < -1 ...
            && isfield(actual_y,'rev_parts') && isfield(actual_y.rev_parts,'west')
        pw_act = actual_y.rev_parts.west - actual_y.cost_parts.west;
        if isfield(actual_y.rev_parts,'hvdc'); pw_act = pw_act + actual_y.rev_parts.hvdc; end   % 与规划LP口径一致
        fw = 1; if isfield(P,'calib_rev_west'); fw = P.calib_rev_west; end
        P.calib_rev_west = min(1.5, max(0.3, 0.5*fw + 0.5*fw*pw_act/(-ben_info.plan_Q_west)));
        fprintf('  [校准] 西部利润 实际%.0f亿/规划%.0f亿 → 价值系数%.2f\n', pw_act/1e4, -ben_info.plan_Q_west/1e4, P.calib_rev_west);
    end
    if (~isfield(P,'enable_calib_west') || ~P.enable_calib_west) && isfield(ben_info,'plan_Q_west') && isfield(actual_y,'rev_parts')
        pw_a_ = actual_y.rev_parts.west - actual_y.cost_parts.west;
        if isfield(actual_y.rev_parts,'hvdc'); pw_a_ = pw_a_ + actual_y.rev_parts.hvdc; end
        fprintf('  [对照] 西部利润 实际%.0f亿 / 规划%.0f亿 (不校准, 仅报告)\n', pw_a_/1e4, -ben_info.plan_Q_west/1e4);
    end
    % 迁移/跨域份额校准: 规划LP的迁移与B跨域上限取实际运行实现的份额(×1.2裕度, 平滑)
    if ~isfield(P,'enable_calib') || P.enable_calib
        try
            Ce_ = sum(demand_y(3,:)) * 8760 / size(demand_y,2);
            if isfield(actual_y,'P_mig_run') && Ce_ > 0
                o_ = 0.3; if isfield(P,'lp_mig_share'); o_ = P.lp_mig_share; end
                P.lp_mig_share = min(1, max(0.02, 0.5*o_ + 0.5*1.2*sum(actual_y.P_mig_run(:))/Ce_));
            end
            if isfield(actual_y,'B_off') && isfield(actual_y,'S_B')
                o_ = 0.35; if isfield(P,'lp_boff_share'); o_ = P.lp_boff_share; end
                sb_ = sum(actual_y.B_off(:)) / max(1, sum(actual_y.B_off(:)) + sum(actual_y.S_B(:)));
                P.lp_boff_share = min(1, max(0.02, 0.5*o_ + 0.5*1.2*sb_));
            end
            fprintf('  [校准] 规划迁移/跨域上限 → C迁移%.0f%% | B跨域%.0f%%\n', 100*P.lp_mig_share, 100*P.lp_boff_share);
        catch
        end
    end
    % ── 内生演化更新: 经验存量(Wright) + 价格出清态(市场反馈) ──────────
    tok_y = 0;
    if isfield(actual_y,'T_gen');  tok_y = tok_y + sum(actual_y.T_gen(:));  end
    if isfield(actual_y,'S_B');    tok_y = tok_y + sum(actual_y.S_B(:));    end
    if isfield(actual_y,'S_C');    tok_y = tok_y + sum(actual_y.S_C(:));    end
    state.cum_tokens = state.cum_tokens + tok_y;
    if ~isfield(P,'enable_endo_price') || P.enable_endo_price
        u_tr = sum(actual_y.P_train(:)) / max(1, sum(state.W_T_cum)*size(actual_y.P_train,1));
        % 均值回归出清: 参考利用率=结构性EMA(原固定0.55与跟随绿电的结构利用率~0.4
        % 不相容→乘子单调贴底0.70), 偏离驱动+向1回归, 稳态乘子→1
        if ~isfield(P,'u_ref_ema'); P.u_ref_ema = u_tr; end
        P.price_endo_mult = min(1.30, max(0.70, ...
            1 + 0.7*(P.price_endo_mult - 1) + 0.35*(u_tr - P.u_ref_ema)));
        P.u_ref_ema = 0.7*P.u_ref_ema + 0.3*u_tr;
        fprintf('  [内生] 利用率=%.2f → 价格出清乘子=%.3f | 累计token=%.2e M\n', ...
            u_tr, P.price_endo_mult, state.cum_tokens);
    end
    fprintf('  [运行] 训练直接消纳率=%.1f%% | 三模式=[%.0f,%.0f,%.0f]%% | B违约=%.1f%%\n', ...
        actual_y.curtail_rate*100, actual_y.mode_freq(1)*100, ...
        actual_y.mode_freq(2)*100, actual_y.mode_freq(3)*100, ...
        actual_y.sla_B_viol_rate*100);
    
    % 年末SOC回写：下一年的初始SOC用本年末状态（而非固定0.5）
    if isfield(actual_y, 'E_soc_final_frac')
        P.soc_init_frac = actual_y.E_soc_final_frac;   % NI×1，各西部节点末尾SOC比例
    end
    
    % ── 步骤8: 追加实际数据至历史集 ───────────────────────────────────
    hist_data = append_actual_to_history(hist_data, actual_y, year);
    
    % ── 步骤9: 该年结果打包并输出 ─────────────────────────────────────
    results_yearly{year} = pack_year_results(year, state, x_new, ...
        ben_info, actual_y, AEMF, demand_y);
    export_yearly_data(year, results_yearly{year}, P);
    % 回收状态年度快照→下年规划传递(创新点三: 价值缺口跨年进入投资决策)
    t_val_ = tic;
    % 价值状态年度更新: 归因→流积递演(FBR)→世界模型(VLM-WM)→下年主问题
    try
        A_att = compute_asset_attribution(results_yearly(1:year), P, true);
        if ~isfield(P,'enable_recovery_feedback') || P.enable_recovery_feedback
            P.recovery_gap = A_att.NPV_a;   % 七资产累计NPV(亿), 负值=回收缺口
        end
        wm_prev = []; if isfield(P,'wm'); wm_prev = P.wm; end
        V_att = value_flow_stock_fbr(A_att, P, year, wm_prev, true);
        % 反事实边际(创新点二): 与是否启用世界模型无关, 保证C组只改变规划方法
        [S_new, cf_y] = wm_sample_generator(state, AEMF, P, demand_y, year, ben_info.SKU, actual_y, A_att);
        if isfield(P,'value_model') && strcmpi(P.value_model,'shapley')
            cf_y = shapley_marginal(state, AEMF, P, demand_y, year, ben_info.SKU);   % 对比组B-II
        end
        if isfield(P,'enable_world_model') && ~P.enable_world_model
            wmb.cf(year,:) = cf_y;
            AFv_ = arrayfun(@(L_) sum((1/(1+A_att.r)).^(0:L_-1)), A_att.life(:)');
            rmg_ = cf_y .* AFv_ ./ A_att.c_unit(:)' - 1;
            P.wm = struct('active', false, 'rho_mg', rmg_);    % 回收闭合仍用反事实边际
        end
        if ~isfield(P,'enable_world_model') || P.enable_world_model
            if isempty(wmb.samples); wmb.samples = S_new; else; wmb.samples = [wmb.samples, S_new]; end
            wmb.cf(year,:) = cf_y;
            if isfield(ben_info,'wm_cand'); wmb.cand(year,:) = ben_info.wm_cand; end
            if isfield(ben_info,'cand_eval'); wmb.cand_eval{year} = ben_info.cand_eval; wmb.cand_src(year) = ben_info.cand_src; end
            % 阶段B-F: 世界模型 → critic(协态锚) → CEM想象规划 → 前瞻修正 → 规划力学与可视化
            try
                [P.wm, wmb] = vlm_wm_rl(wmb, A_att, V_att, results_yearly(1:year), P, year, growth_forecast);
            catch ME_wm
                fprintf('  [VLM-WM] 世界模型RL异常, 回退结构化代理: %s\n', ME_wm.message);
                P.wm = vlm_world_model(A_att, V_att, results_yearly(1:year), P, year, growth_forecast);
            end
        end
    catch ME_v
        fprintf('  [价值状态] 年度更新跳过: %s\n', ME_v.message);
    end

    % ── 步骤10: RL在线微调（每3年一次）──────────────────────────────
    % 先积累足够真实Benders经验，再用BendersRLEnvironment做短程微调
    if isfield(P,'enable_RL_cut') && P.enable_RL_cut && mod(year,3)==0 && isfield(AEMF,'RL') && isfield(AEMF.RL,'agent') ...
            && ~isempty(AEMF.RL.agent)
        try
            env_rl = BendersRLEnvironment(P);
            tuneOpts = rlTrainingOptions(...
                'MaxEpisodes',          10,   ...   % 10轮短程微调
                'MaxStepsPerEpisode',   15,   ...
                'Verbose',              false, ...
                'Plots',                'none', ...
                'StopTrainingCriteria', 'EpisodeCount');
            train(AEMF.RL.agent, env_rl, tuneOpts);   % handle对象原地更新
            AEMF_prev.RL.agent = AEMF.RL.agent;        % 传入下一年
            fprintf('  [RL微调] Y%d 完成10轮微调, ε=%.3f\n', year, ...
                AEMF.RL.agent.AgentOptions.EpsilonGreedyExploration.Epsilon);
        catch ME
            fprintf('  [RL微调] 跳过(%s)\n', ME.message);
        end
    end

    % ── 步骤11: BSASP-GBR年度更新（每3年重训, D2b: 真实样本）─────────
    if mod(year, 3) == 0 && year >= 3
        X_gbr = []; Y_gbr = [];
        for yr_h = max(1,year-8):year
            R_h = results_yearly{yr_h};
            if ~isempty(R_h) && isfield(R_h,'ben_info') ...
                    && isfield(R_h.ben_info,'gbr_X')
                X_gbr = [X_gbr; R_h.ben_info.gbr_X];
                Y_gbr = [Y_gbr; R_h.ben_info.gbr_Y];
            end
        end
        if size(X_gbr,1) >= 10
            gbr_new = train_BSASP_GBR(X_gbr, Y_gbr);
            if ~isempty(gbr_new)
                AEMF_prev.gbr_model = gbr_new;
                fprintf('  [BSASP-GBR] Y%d 真实样本重训: %d条(φ_s,Q_s)对\n', ...
                    year, size(X_gbr,1));
            end
        end
    end

    dt_val_ = NaN; if exist('t_val_','var'); dt_val_ = toc(t_val_)/60; end
    fprintf('  [耗时] Benders(含候选检验)%.1f | 实际运行%.1f | 价值状态+样本+世界模型%.1f 分钟\n', dt_ben_, dt_act_, dt_val_);
    global LP_STATS
    if ~isempty(LP_STATS) && LP_STATS.n > 0
        fprintf('  [LP统计] 本年求解%d次(%s) | 平均%.3f秒/次 | 失败%d次 | 规模%d变量/%d非零元\n', ...
            LP_STATS.n, LP_STATS.solver, LP_STATS.t/LP_STATS.n, LP_STATS.fail, LP_STATS.nvar, LP_STATS.nnz);
        LP_STATS = [];
    end
    fprintf('  [完成] 本年耗时%.1f分钟\n', toc(year_tic)/60);

    % ── 逐年检查点 ─────────────────────────────────────────────────────
    if ~isfield(P,'checkpoint') || P.checkpoint
        try
            if ~exist(ck_dir,'dir'); mkdir(ck_dir); end
            Pdyn = struct();
            for k_ = 1:numel(dyn_fields)
                if isfield(P, dyn_fields{k_}); Pdyn.(dyn_fields{k_}) = P.(dyn_fields{k_}); end
            end
            rng_state = rng; ck_t = tic; build_tag = BUILD_TAG;
            try
                save(ck_file, 'year','state','results_yearly','wmb','AEMF_prev','hist_data', ...
                     'demand_fac','Pdyn','rng_state','build_tag','-v7');
            catch
                save(ck_file, 'year','state','results_yearly','wmb','AEMF_prev','hist_data', ...
                     'demand_fac','Pdyn','rng_state','build_tag','-v7.3');    % 超过2GB时
            end
            if isfield(P,'ckpt_keep_all') && P.ckpt_keep_all
                copyfile(ck_file, fullfile(ck_dir, sprintf('ckpt_Y%02d.mat', year)));
            end
            fprintf('  [检查点] Y%d已保存(%.0f秒)\n', year, toc(ck_t));
        catch ME_ck
            fprintf('  [检查点] 保存失败: %s\n', ME_ck.message);
        end
    end
    % ── 分阶段停止: 先跑前几年检查日志, 再以 P.resume=true 从检查点续跑(同一套参数, 结果连续) ──
    if isfield(P,'stop_after_year') && ~isempty(P.stop_after_year) && year >= P.stop_after_year && year < P.N_year
        fprintf('\n[分阶段停止] 已完成Y%d并保存检查点。检查日志无误后, 设 P.stop_after_year=[]、P.resume=true 续跑。\n', year);
        return;
    end
end

%% [4/4] 后处理: 图像+敏感性+汇总
fprintf('\n[4/4] 后处理: 生成图像与汇总报表...\n');
if isfield(P,'legacy_figs') && P.legacy_figs
    generate_all_figures(results_yearly, P);
end
% (原占位敏感性程序已移除; 论文敏感性检验见 Fig. 6f)
write_summary_csv(results_yearly, P);
% 资产级价值归因与回收闭合审计(创新点二实证)
try
    Pev_ = P; Pev_.value_model = 'full';            % 期末评价统一按真实(全口径)价值, 保证各对比组可比
    A_fin = compute_asset_attribution(results_yearly, Pev_);
    wm_last = []; if isfield(P,'wm'); wm_last = P.wm; end
    value_flow_stock_fbr(A_fin, P, numel(results_yearly), wm_last, false);   % 创新点二全量输出
    if ~isfield(P,'enable_world_model') || P.enable_world_model
        planning_mechanics_report(wmb, A_fin, P);                            % 创新点三证据汇总
        save(fullfile(P.out_dir,'wm_buffer.mat'), 'wmb');
    end
catch ME_attr
    warning('归因/流积递演异常(不影响主流程): %s', ME_attr.message);
end
% 电力层安全校验(创新一Ω_power): DC潮流+LODF N-1事后筛查(需MATPOWER)
try
    verify_dc_powerflow_n1(results_yearly, P);
catch ME_pf
    warning('潮流N-1校验异常(不影响主流程): %s', ME_pf.message);
end
try
    export_ahm_graph(results_yearly, P);        % 创新一: 多层图与Ω_srv逐年导出
catch ME_g
    warning('多层图导出异常(不影响主流程): %s', ME_g.message);
end
% 论文图系统(按规划结果与三个创新点组织; 也可仿真结束后单独运行 plot_paper_figures)
try
    shw_ = true; if isfield(P,'show_figs'); shw_ = P.show_figs; end
    plot_paper_figures(P.out_dir, shw_);
    % 本文方法运行时, 若已有五组对比结果, 接着绘制核心指标对比图(对比组运行时不绘制)
    if isempty(CMP_CASE)
        try
            plot_comparison_figures([], shw_);
        catch ME_cmp
            fprintf('  [对比图] 跳过: %s\n', ME_cmp.message);
        end
    end
catch ME_pp
    warning('论文图生成异常(不影响主流程): %s', ME_pp.message);
end

fprintf('\n================================================================\n');
fprintf('  仿真完成 | 总耗时: %.1f分钟\n', toc(total_tic)/60);
fprintf('  输出目录: simulation_output/\n');
fprintf('================================================================\n');
