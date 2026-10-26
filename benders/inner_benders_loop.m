%% =========================================================================
%  inner_benders_loop.m  —  单年内Benders迭代主循环
%  
%  在给定年份内, 执行规划层(VAIC)与运行层(DACS)的迭代直至收敛
%  
%  关键步骤(参照AI指令):
%    Step 0: 用初始可行方案先求一次子问题, 得到非退化的第一个VAIC割
%    Step 1: 求解VAIC主问题(MIP, 含state累计下界约束)
%    Step 2: BSASP情景精度分级 + DACS子问题并行求解
%    Step 3: 生成VAIC加权强化割
%    Step 4: 收敛判定与早停
%% =========================================================================
function [x_new, info] = inner_benders_loop(P, AEMF, demand_y, state, year)

NI = P.N_west; NJ = P.N_east;
scenarios = AEMF.scenarios;
N_s = scenarios.N_scen;

% SKU定价
P.D_peak_hint = max(sum(demand_y, 1));   % 需求峰值提示(L_glob锚定+现货上限用)
if ~isfield(P,'comm_delay_base'); P.comm_delay_base = P.comm_delay; end
SKU = compute_SKU_pricing(P, year);

% 准备每情景的(lam_w, lam_e, CF_renew, lam_token, Lambda_A/B/C, mean_B/C)
scen_data = cell(N_s, 1);
for s = 1:N_s
    scen_data{s} = prepare_scenario_data(scenarios, s, demand_y, SKU, P);
end

%% ── Step 0: 初始方案 + 第一次子问题 ──────────────────────────────────
fprintf('  [Init] 初始可行方案 + 第一次DACS子问题...\n');

% 初始方案: 主问题第0轮（空割集）自主求解
% 核心设计: 主问题第0轮纯粹最小化F1（宁夏CF高→F1最低→被选）
% 但F1主导不考虑运营收益Q（内蒙kappa高→Q更好），需多起点弥补
% 策略: 同时评估 [最低F1节点] 和 [最高w节点]，取Q+F1综合最优

% 初始方案：双候选启发式多起点
% 不调用solve_master_problem作初始化——避免YALMIP变量累积导致Y12+以后infeasible
% 候选1：CF最高节点（宁夏，F1最低）| 候选2：kappa最高节点（内蒙，市场价值最高）
x_init_f1 = make_init_solution(state, P, demand_y);
x_init_w  = make_init_solution_high_w(state, P, demand_y, SKU, AEMF);

try
    [Q_f1, ~, ~] = solve_subproblem(x_init_f1, scen_data{1}, P, SKU, [], 'low');
    [Q_w,  ~, ~] = solve_subproblem(x_init_w,  scen_data{1}, P, SKU, [], 'low');
    f1_ann = @(x) (x.F1_total - P.C_stor*1000*(sum(x.E_w)+sum(x.E_e)))/P.T_life ...
                   + P.C_stor*1000*(sum(x.E_w)+sum(x.E_e))/P.T_stor_life;
    if ~isfield(P,'capex_crf') || P.capex_crf; f1_ann = @(x) capex_annual(x, state, P, year); end
    score_f1 = f1_ann(x_init_f1) + Q_f1;
    score_w  = f1_ann(x_init_w)  + Q_w;
    if score_w < score_f1
        x_init = x_init_w;
        fprintf('  [Init] 高价值节点z=[%s] 综合得分更优(%.1f < %.1f 亿)\n', ...
            num2str(find(x_init_w.z==1)'), score_w/1e4, score_f1/1e4);
    else
        x_init = x_init_f1;
        fprintf('  [Init] CF优先节点z=[%s] 综合得分更优(%.1f < %.1f 亿)\n', ...
            num2str(find(x_init_f1.z==1)'), score_f1/1e4, score_w/1e4);
    end
catch ME
    x_init = x_init_f1;
    fprintf('  [Init] 多起点评估失败(%s)，使用CF优先方案\n', ME.message);
end

x_init = project_to_master(x_init, P, AEMF, demand_y, state, year);   % 启发式初解投影到主问题可行域
Q_init_scen = zeros(N_s, 1);
mu_init_scen = cell(N_s, 1);
info_init_scen = cell(N_s, 1);
for s = 1:N_s
    [Qs, mus, infos] = solve_subproblem(x_init, scen_data{s}, P, SKU, [], 'high');
    Q_init_scen(s) = Qs;
    mu_init_scen{s} = mus;
    info_init_scen{s} = infos;
end
% 规划Q分解诊断(亿元/年, 情景均值): 用于核对规划侧与实际运行层量级是否一致
try
    qw = mean(cellfun(@(z) z.Q_west,  info_init_scen)) / 1e4;
    qe = mean(cellfun(@(z) z.Q_east,  info_init_scen)) / 1e4;
    qr = mean(cellfun(@(z) z.Q_route, info_init_scen)) / 1e4;
    fprintf('  [Q分解] 西部%.1f 东部%.1f 迁移%.1f 亿(负=盈利)', qw, qe, qr);
    if isfield(info_init_scen{1},'east_dbg')
        ed = info_init_scen{1}.east_dbg / 1e4;
        fprintf(' | 东部: A%.0f B%.0f C%.0f 调峰%.0f B跨域%.0f 电费%.0f', ed(1:6));
    end
    fprintf('\n');
catch
end
% DRO最坏分布: 在嵌套模糊集B_total内寻找使期望成本最大的概率分布(论文式4)
% 替换原普通期望sum(pi_s.*Q_scen), 实现真正的分布鲁棒, 非随机规划SP
% 情景特征(综合CF均值)用于矩约束检验
scen_feat = mean(scenarios.cf_combined, 2);
% ── 消融M3：w/o DRO → 用名义分布(期望值)替代最坏分布 ─────────────────
if isfield(P,'ablation') && strcmp(P.ablation,'M3')
    P_worst_init = scenarios.pi_s(:);
    Q_init = sum(P_worst_init .* Q_init_scen(:));
else
    [P_worst_init, Q_init] = compute_worst_case_distribution(Q_init_scen, ...
        scenarios.pi_s, AEMF.epsilon_1, scen_feat);
end
fprintf('  [DRO] 初始最坏分布: 最大权重情景=%d(权重%.3f), 名义=%.3f, eps_1=%.4f\n', ...
    find(P_worst_init==max(P_worst_init),1), max(P_worst_init), ...
    max(scenarios.pi_s), AEMF.epsilon_1);

% UB基准与主问题objective一致: F1年化(÷T_life) + 年度Q_total
% x_best由纯UB竞争决定: MCF供给修复后P2迁移收益充足,大容量方案UB自然优于907
F1_stor_init = P.C_stor*1000*(sum(x_init.E_w) + sum(x_init.E_e));
UB_raw = (x_init.F1_total - F1_stor_init)/P.T_life + F1_stor_init/P.T_stor_life + Q_init;
if ~isfield(P,'capex_crf') || P.capex_crf; UB_raw = capex_annual(x_init, state, P, year) + Q_init; end
UB_raw = UB_raw + extra_obj_terms(x_init, state, P, year);   % 与主问题目标同口径
LB = -inf;
x_best = x_init;
UB_best = UB_raw;
Q_best = Q_init;   % 现任解的运行成本(局部模型中心值)

% 第一个VAIC割(用DRO最坏分布加权μ, 而非名义概率)
cut0 = generate_VAIC_cut(x_init, Q_init, mu_init_scen, P_worst_init, P, SKU, AEMF, year, scen_data);
cuts = {cut0};

fprintf('  [Init] Q_init=%.2f亿, UB_init=%.2f亿\n', Q_init/1e4, UB_raw/1e4);

%% ── 价值规划工具的候选检验(创新三→决策): 世界模型 / 近视 / 力流(规划力学) / 零扩容 ──
% 各候选=叠加在可行初解上的首年动作, 经DRO加权真实子问题 + 与主问题同口径的一阶段项评估;
% 最优者若优于初始解则成为现任解; 每个候选都生成割。同时记录"世界模型预测排序 vs 真实排序"(决策一致性)
info_wm = [NaN NaN 0]; cand_eval = []; cand_src = 0;
if (~isfield(P,'enable_world_model') || P.enable_world_model) && (~isfield(P,'wm_inject') || P.wm_inject) ...
        && isfield(P,'wm') && isstruct(P.wm) && isfield(P.wm,'active') && P.wm.active ...
        && isfield(P.wm,'cand_u') && ~isempty(P.wm.cand_u)
    CU = P.wm.cand_u; nC = size(CU,1); UBc = nan(1,nC); Xc = cell(1,nC); Qc_list = nan(1,nC);
    cnm = {'世界模型','近视','力流','零扩容'};
    for k = 1:nC
        try
            if all(CU(k,1:6) < 1e-9); UBc(k) = UB_raw; Xc{k} = x_init; continue; end
            x_c = build_candidate_x(x_init, state, CU(k,:), demand_y, P, year);
            x_c = project_to_master(x_c, P, AEMF, demand_y, state, year);
            Qs_c = zeros(N_s,1); mus_c = cell(N_s,1);
            for s = 1:N_s; [Qs_c(s), mus_c{s}] = solve_subproblem(x_c, scen_data{s}, P, SKU, [], 'high'); end
            [pwc_, Q_c] = dro_value(Qs_c, scenarios, AEMF, scen_feat, P); Qc_list(k) = Q_c;
            [ex_c, x_c.net_ov] = extra_obj_terms(x_c, state, P, year);
            UBc(k) = capex_annual(x_c, state, P, year) + Q_c + ex_c;
            cuts{end+1} = generate_VAIC_cut(x_c, Q_c, mus_c, pwc_, P, SKU, AEMF, year, scen_data); %#ok<AGROW>
            Xc{k} = x_c;
        catch ME_c
            fprintf('  [候选检验] %s 评估跳过: %s\n', cnm{min(k,4)}, ME_c.message);
        end
    end
    % 同一候选在8760h实际运行层的年化净成本(论文所称"真实运行校验"; 实际层单次约数秒)
    UBa = nan(1,nC);
    for k = 1:nC
        if isempty(Xc{k}); continue; end
        try
            xk = Xc{k}; st_c = state;
            st_c.W_T_cum = reshape(xk.W_T, size(state.W_T_cum)); st_c.W_I_cum = reshape(xk.W_I, size(state.W_I_cum));
            st_c.G_cum   = reshape(xk.G,   size(state.G_cum));   st_c.E_w_cum = reshape(xk.E_w, size(state.E_w_cum));
            st_c.E_e_cum = reshape(xk.E_e, size(state.E_e_cum));
            if isfield(xk,'z'); st_c.z_cum = reshape(xk.z, size(state.z_cum)); end
            if isfield(xk,'dL') && isequal(size(xk.dL), size(state.dL_cum)); st_c.dL_cum = xk.dL; end
            Pq = P; Pq.quiet_actual = true;
            act_c = simulate_actual_operation(st_c, AEMF, Pq, demand_y, year, SKU);
            dep_ = 0; if isfield(act_c,'cost_depr'); dep_ = act_c.cost_depr; end
            UBa(k) = capex_annual(xk, state, P, year) - (act_c.revenue_total - (act_c.cost_total - dep_)) ...
                     + extra_obj_terms(xk, state, P, year);
        catch
        end
    end
    fprintf('  [候选检验] 规划: %s | 初始UB=%.1f亿\n', strjoin(arrayfun(@(k) sprintf('%s %.1f', cnm{min(k,4)}, UBc(k)/1e4), ...
        1:nC, 'Uni', 0), ' / '), UB_raw/1e4);
    fprintf('  [候选检验] 实际: %s\n', strjoin(arrayfun(@(k) sprintf('%s %.1f', cnm{min(k,4)}, UBa(k)/1e4), 1:nC, 'Uni', 0), ' / '));
    [ubm, kb] = min(UBc);
    if isfinite(ubm) && ubm < UB_best - 1e-6 && ~isempty(Xc{kb})
        x_best = Xc{kb}; UB_best = ubm; cand_src = kb; if isfinite(Qc_list(kb)); Q_best = Qc_list(kb); end
        fprintf('  [候选检验] 采纳"%s"为现任解, UB改善%.1f亿\n', cnm{min(kb,4)}, (UB_raw - ubm)/1e4);
    end
    Jp = nan(1,nC); if isfield(P.wm,'cand_J'); Jp = P.wm.cand_J; end
    cand_eval = [Jp; UBc; UBa];   % [世界模型预测; 规划子问题UB; 实际运行年化净成本]
    info_wm = [UBc(1), UB_raw, cand_src == 1];
end

%% ── Step 1-4: 主循环 ──────────────────────────────────────────────────
fprintf('  %5s %10s %10s %8s\n', 'Iter', 'LB(亿)', 'UB(亿)', 'Gap(%)');

LB_history = [];
gap_history = [];
early_stop_cnt = 0;
current_gap = 1.0;   % 初始gap=100%（第1轮未知，默认全精度）

UB_hist = inf(P.max_iter,1); gap_hist = inf(P.max_iter,1);
%% ── 下界预热: 上角点与中点割(仅LP子问题) ──
% 首轮主问题只有初始点的一张割, 线性外推使"大幅扩容"看似收益无限, 首轮gap因此极大。
% 在"需求可利用容量上界"处与其中点各评估一次: 运行成本对容量凸且在饱和后不再下降,
% 上角点的割把主问题对扩容收益的想象限制在真实水平, 首轮下界即接近最终值。只加割, 不作为现任解
if (~isfield(P,'recourse_lp') || P.recourse_lp) && (~isfield(P,'enable_warm_corners') || P.enable_warm_corners)
    try
        xu_ = corner_point(x_init, state, P, demand_y);
        xm_ = blend_point(x_init, xu_, 0.5);
        qq_ = zeros(1,2); pts_ = {xu_, xm_};
        for q_ = 1:2
            Qs_w = zeros(N_s,1); mus_w = cell(N_s,1);
            for s = 1:N_s; [Qs_w(s), mus_w{s}] = solve_subproblem(pts_{q_}, scen_data{s}, P, SKU, [], 'high'); end
            [pww_, qq_(q_)] = dro_value(Qs_w, scenarios, AEMF, scen_feat, P);
            cuts{end+1} = generate_VAIC_cut(pts_{q_}, qq_(q_), mus_w, pww_, P, SKU, AEMF, year, scen_data); %#ok<AGROW>
        end
        fprintf('  [下界预热] 上角点Q=%.1f亿 / 中点Q=%.1f亿 / 初始点Q=%.1f亿\n', qq_(1)/1e4, qq_(2)/1e4, Q_init/1e4);
    catch ME_w
        fprintf('  [下界预热] 跳过: %s\n', ME_w.message);
    end
end

%% ── 选址枚举预热(日志v8.16: 未评估过的选址组合只能取全局下界L, 下界长期停在−900~−4500亿) ──
% 对"已锁定节点 + 至多新增2个节点"的每个组合, 按启发式容量做一次真实子问题评估并生成割;
% 每个组合的割使下界在该组合上立即抬升到其真实运行成本附近
if ~isfield(P,'enable_z_enum') || P.enable_z_enum
    zl_ = state.z_cum(:) > 0.5; fr_ = find(~zl_); combos_ = {};
    m0_ = 0; if ~any(zl_); m0_ = 1; end
    for m_ = m0_:min(2, numel(fr_))
        if m_ == 0; CC_ = zeros(1,0); else; CC_ = nchoosek(fr_(:)', m_); end
        for r_ = 1:size(CC_,1)
            zv_ = zl_; zv_(CC_(r_,:)) = true; if any(zv_); combos_{end+1} = zv_; end %#ok<AGROW>
        end
    end
    n_ev_ = 0; zb_ = [];
    for q_ = 1:numel(combos_)
        zv_ = combos_{q_};
        if isequal(zv_, x_init.z(:) > 0.5) || (isfield(x_best,'z') && isequal(zv_, x_best.z(:) > 0.5)); continue; end
        try
            x_z = init_for_z(zv_, x_init, state, P, demand_y, SKU, AEMF, year);
            x_z = project_to_master(x_z, P, AEMF, demand_y, state, year);
            Qs_z = zeros(N_s,1); mus_z = cell(N_s,1);
            for s = 1:N_s; [Qs_z(s), mus_z{s}] = solve_subproblem(x_z, scen_data{s}, P, SKU, [], 'high'); end
            [pwz_, Q_z] = dro_value(Qs_z, scenarios, AEMF, scen_feat, P);
            UB_z = capex_annual(x_z, state, P, year) + Q_z + extra_obj_terms(x_z, state, P, year);
            cuts{end+1} = generate_VAIC_cut(x_z, Q_z, mus_z, pwz_, P, SKU, AEMF, year, scen_data); %#ok<AGROW>
            n_ev_ = n_ev_ + 1;
            if UB_z < UB_best - 1e-6
                x_best = x_z; UB_best = UB_z; Q_best = Q_z; zb_ = find(zv_)';
            end
        catch ME_z
            fprintf('  [选址枚举] 组合评估跳过: %s\n', ME_z.message);
        end
    end
    if n_ev_ > 0
        if isempty(zb_)
            fprintf('  [选址枚举] 评估%d个选址组合, 现任解保持不变\n', n_ev_);
        else
            fprintf('  [选址枚举] 评估%d个选址组合, 现任解更新为z=[%s] UB=%.1f亿\n', n_ev_, num2str(zb_), UB_best/1e4);
        end
    end
end

tr_on = ~isfield(P,'enable_tr') || P.enable_tr;
tr_kappa = 0.3; if isfield(P,'tr_kappa0'); tr_kappa = P.tr_kappa0; end   % 近端罚权重(×单位年金)
tr_glob  = 5;    if isfield(P,'tr_global_every'); tr_glob = P.tr_global_every; end
tr_grad = []; if isfield(P,'tr_grad'); tr_grad = P.tr_grad; end      % 上一年反事实边际(万元/单位·年)
tr_fail  = 0; n_glob = 0; gap_prev = inf;
for iter = 1:P.max_iter
    iter_tic = tic;
    % 信赖域: 局部迭代围绕现任解开发; 每tr_glob轮做一次全局迭代以更新全局下界与探索选址
    gsw_ = 0.15; if isfield(P,'gap_glob_switch'); gsw_ = P.gap_glob_switch; end
    is_glob = ~tr_on || iter == 1 || mod(iter, tr_glob) == 0 || (gap_prev > gsw_ && mod(iter,2) == 1);
    if is_glob; n_glob = n_glob + 1; end
    if is_glob
        P.tr = struct('on', false);
    else
        P.tr = struct('on', true, 'x', x_best, 'kappa', tr_kappa, 'Qc', Q_best, 'grad', tr_grad);
    end
    
    % ── Step 1: VAIC主问题 ────────────────────────────────────────────
    [x_sol, LB_new] = solve_master_problem(P, AEMF, demand_y, state, cuts, year);
    if is_glob && LB_new > LB                         % 仅全局迭代更新全局下界(信赖域下界是局部的)
        LB = LB_new;
    end
    LB_history(end+1) = LB;
    
    % 候选通信路由临时生效(评估该候选下的迁移经济学, MCF/GAT/VUFP自动感知)
    if isfield(x_sol,'rt')
        P.comm_delay = route_delay_apply(P, x_sol.rt);
    end
    fprintf('  [VAIC] z=[%s] W_T=[%s]MW theta=%.2f亿\n', ...
        num2str(x_sol.z'), num2str(round(x_sol.W_T')), x_sol.theta/1e4);
    
    % ── Step 2: BSASP + DACS子问题 ───────────────────────────────────
    precisions = BSASP_precision_allocation(scenarios, iter, P, current_gap);
    
    Q_scen = zeros(N_s, 1);
    mu_scen = cell(N_s, 1);
    info_scen = cell(N_s, 1);
    for s = 1:N_s
        [Qs, mus, infos] = solve_subproblem(x_sol, scen_data{s}, P, SKU, [], precisions{s});
        Q_scen(s) = Qs;
        mu_scen{s} = mus;
        info_scen{s} = infos;
    end
    % DRO最坏分布(每轮基于当前情景Q重新求解, 论文式4)
    if isfield(P,'ablation') && strcmp(P.ablation,'M3')
        P_worst = scenarios.pi_s(:);
        Q_total = sum(P_worst .* Q_scen(:));
    else
        [P_worst, Q_total] = compute_worst_case_distribution(Q_scen, ...
            scenarios.pi_s, AEMF.epsilon_1, scen_feat);
    end
    
    % UB: 储能按T_stor_life(10年)折旧, 其余设备按T_life(20年)
    F1_stor_x = P.C_stor*1000*(sum(x_sol.E_w) + sum(x_sol.E_e));
    UB_new = (x_sol.F1_total - F1_stor_x)/P.T_life + F1_stor_x/P.T_stor_life + Q_total;
    if ~isfield(P,'capex_crf') || P.capex_crf; UB_new = capex_annual(x_sol, state, P, year) + Q_total; end
    UB_new = UB_new + extra_obj_terms(x_sol, state, P, year);   % 与主问题目标同口径
    % x_best由纯UB竞争决定(MCF修复后P2迁移收益充足,不需要额外筛选)
    if UB_new < UB_best
        UB_best = UB_new;
        x_best = x_sol; Q_best = Q_total;
        fprintf('     [UB更新] 来源=iter%d%s\n', iter, ifelse_tr(is_glob));
        if ~is_glob; tr_kappa = max(0.05, 0.5*tr_kappa); end; tr_fail = 0;
    elseif ~is_glob
        tr_kappa = min(8, 2*tr_kappa); tr_fail = tr_fail + 1;
    end

    % ── 选址安全守卫(过切检测→自动回退经典LL) ─────────────────────────
    % 不变式: 有效割体系下 LB ≤ 真最优 ≤ UB_best 恒成立。
    % wLL构造性有效使本守卫理论上永不触发; 作为不可逆投资的机械保险存在。
    if LB > UB_best + max(1, 0.01*abs(UB_best))
        warning('[VAIC-guard] LB(%.1f)>UB(%.1f): 检测到割过切, 后续割回退经典LL(w≡1)', LB, UB_best);
        P.vaic_force_classic = true;   % generate_VAIC_cut读取此旗标
    end
    
    % ── Step 3: 生成新VAIC割 ──────────────────────────────────────────
    % VAIC加权割(论文式36): μ加权用DRO最坏分布而非名义概率
    cut_new = generate_VAIC_cut(x_sol, Q_total, mu_scen, P_worst, P, SKU, AEMF, year, scen_data);
    cuts{end+1} = cut_new;
    % 注：不丢弃z*不同的旧割——Benders理论保证跨z割有效性，保留以维持选址比较信息
    
    % ── Step 4: 收敛判定（UB稳定性为主，LB-gap为辅）────────────────────
    % LB不变是MILP Benders的固有特性：z锁定后z梯度=0，LB天然冻结。
    % 这不是bug——它反映了"整数松弛gap"，是评价Benders割质量的指标，不影响解的最优性。
    % 真正的收敛信号是：UB_best（最好可行解）稳定不变。
    scale_ = max(1e4, capex_annual(x_best, state, P, year) + abs(Q_best));   % 目标量级: 年化投资+|运行成本|
    if LB > UB_best + 1e-3*scale_
        % 下界高于上界说明现任解不在主问题可行域或割无效: 不得据此判收敛
        fprintf('  [一致性告警] LB=%.1f亿 > UB=%.1f亿, 本轮不判收敛\n', LB/1e4, UB_best/1e4);
        gap = 1;
    else
        gap = max(0, UB_best - LB) / scale_;
    end
    gap_prev = gap;
    current_gap = gap;
    gap_history(end+1) = gap;

    fprintf('  %4d %10.2f %10.2f %7.3f  t=%.1fs\n', ...
        iter, LB/1e4, UB_best/1e4, gap*100, toc(iter_tic));

    % 收敛条件：gap真正收窄（LB与UB确实逼近，意味着割足够紧）
    if gap < P.tol_gap
        fprintf('  [收敛] gap=%.3f%% < %.1f%%, 终止\n', gap*100, P.tol_gap*100);
        break;
    end
    ga_ = 0.10; if isfield(P,'gap_accept'); ga_ = P.gap_accept; end
    mg_ = 8;    if isfield(P,'min_glob_iter'); mg_ = P.min_glob_iter; end
    if tr_on && tr_fail >= 4 && iter >= 2*tr_glob && (gap <= ga_ || n_glob >= mg_)
        fprintf('  [信赖域收敛] 近端权重增至%.1f且连续%d轮无改进; 相对初始方案改进%.1f亿, gap(全局割下界)=%.1f%%\n', ...
            tr_kappa, tr_fail, (UB_raw - UB_best)/1e4, gap*100);
        break;
    end
    UB_hist(iter) = UB_best; gap_hist(iter) = gap;
    ns_ = 8; if isfield(P,'benders_stall_iter'); ns_ = P.benders_stall_iter; end
    mi_ = 10; if isfield(P,'benders_min_iter'); mi_ = P.benders_min_iter; end
    tl_ = 0.005; if isfield(P,'benders_stall_tol'); tl_ = P.benders_stall_tol; end
    if iter >= max(mi_, ns_+1)
        imp_ = (UB_hist(iter-ns_) - UB_best) / max(1, abs(UB_best));
        gp_  = 0.02; if isfield(P,'benders_gap_progress'); gp_ = P.benders_gap_progress; end
        dgap = gap_hist(iter-ns_) - gap;                    % 窗口内gap收窄量(下界仍在上升则继续)
        sgm_ = 0.05; if isfield(P,'stall_gap_max'); sgm_ = P.stall_gap_max; end
        if imp_ < tl_ && dgap < gp_ && (gap <= sgm_ || iter >= 0.75*P.max_iter)
            fprintf('  [停滞终止] 近%d轮UB改进%.2f%%、gap收窄%.1f个百分点, 终止于gap=%.2f%%\n', ...
                ns_, 100*imp_, 100*dgap, gap*100);
            break;
        end
    end

    % 早停：UB连续N轮不改善（找到稳定可行解，整数松弛gap允许存在）
    % P.early_stop_dLB控制LB稳定阈值；这里同时监测UB稳定
    if iter > P.early_stop_win
        recent_dLB = abs(LB_history(end) - LB_history(end-P.early_stop_win)) ...
                     / max(abs(LB_history(end)), 1);
        if (recent_dLB < P.early_stop_dLB && gap < P.tol_gap_early)
            early_stop_cnt = early_stop_cnt + 1;
        else
            early_stop_cnt = 0;
        end
        if early_stop_cnt >= 2
            fprintf('  [早停] UB=%.2f亿稳定, gap=%.2f%% (整数松弛gap,正常)\n', ...
                    UB_best/1e4, gap*100);
            break;
        end
    end
end

x_new = x_best;
info.n_iter      = iter;
info.ub_gain     = (UB_raw - UB_best)/1e4;   % 相对初始方案的改进(亿元)
info.wm_cand     = info_wm;   % [世界模型候选UB, 初始UB, 是否采纳]
info.cand_eval   = cand_eval; % [世界模型预测值; 真实UB](各候选)
info.cand_src    = cand_src;  % 被采纳候选(0=无,1世界模型,2近视,3力流,4零扩容)
% 锁定方案在名义情景下的规划侧分解(供"实际运行→规划模型"校准)
try
    ed_ = 0; qw_ = 0; pin_ = scenarios.pi_s(:) / sum(scenarios.pi_s(:));
    for s = 1:N_s
        [~, ~, inf_b] = solve_subproblem(x_best, scen_data{s}, P, SKU, [], 'high');
        if isfield(inf_b,'east_dbg'); ed_ = ed_ + pin_(s) * inf_b.east_dbg; end
        if isfield(inf_b,'Q_west');   qw_ = qw_ + pin_(s) * inf_b.Q_west;   end
    end
    info.plan_east_dbg = ed_; info.plan_Q_west = qw_;   % 名义加权期望(与实际运行同为"期望"口径, 不含DRO悲观)
catch
end
info.final_gap   = gap;
info.SKU         = SKU;                   % 穿透给实际运行层(价值耦合单一价格源)
% ── GBR真实训练样本存档(D2b: 替代随机扰动伪样本, 消除循环论证) ─────────
NS_g = scenarios.N_scen;
gbr_X = zeros(NS_g, 5);
cfg_mean = mean(scenarios.cf_combined(:));
pw_mean  = mean(scenarios.price_west(:));
for s_g = 1:NS_g
    cfs = scenarios.cf_combined(s_g,:);
    gbr_X(s_g,1) = std(cfs);
    gbr_X(s_g,2) = abs(mean(cfs) - cfg_mean);
    gbr_X(s_g,3) = max(0, mean(scenarios.price_west(s_g,:),'all') - pw_mean) / max(1,pw_mean);
    if isfield(scenarios,'demand_factor')
        gbr_X(s_g,4) = abs(scenarios.demand_factor(s_g) - 1);
    end
    gbr_X(s_g,5) = sum(cfs < 0.08) / max(1,length(cfs));
end
info.gbr_X = gbr_X;
info.gbr_Y = Q_scen(:) / max(1, abs(Q_total));   % 归一化情景风险(真实Q)
% ── AEMF真实快照(图12数据源, 消除解析近似)─────────────────────────────
info.aemf_snap = struct();
info.aemf_snap.epsilon_1 = AEMF.epsilon_1;
if isfield(AEMF,'mu_rho_L'); info.aemf_snap.rho_L = AEMF.mu_rho_L; else; info.aemf_snap.rho_L = NaN; end
if isfield(AEMF,'mu_rho_U'); info.aemf_snap.rho_U = AEMF.mu_rho_U; else; info.aemf_snap.rho_U = NaN; end
if isfield(AEMF,'N_sparse'); info.aemf_snap.N_sparse = AEMF.N_sparse; else; info.aemf_snap.N_sparse = NaN; end
if isfield(AEMF,'sigma2_max'); info.aemf_snap.sigma2_max = AEMF.sigma2_max; else; info.aemf_snap.sigma2_max = NaN; end
info.n_cuts      = length(cuts);          % 整数割总数
if ~isempty(cuts) && isfield(cuts{end},'w')
    info.w_field = cuts{end}.w;           % OVT: 演化后价值场(供下年WGF)
end
info.master_status = (gap < P.benders_tol);  % 1=正常收敛 0=超轮次退出
info.sub_status    = all(cellfun(@(c) isfield(c,'Q_star'), cuts));
info.LB_history  = LB_history;
info.gap_history = gap_history;
info.cuts        = cuts;
info.UB_best     = UB_best;
info.Q_total     = Q_total;
info.mu_scen     = mu_scen;
info.info_scen   = info_scen;
info.scen_data   = scen_data;
end


%% ─── SKU定价计算 ──────────────────────────────────────────────────────
function SKU = compute_SKU_pricing(P, year)
if nargin < 2; year = 1; end
NI = P.N_west; NJ = P.N_east;

% ── GPU算力效率年度提升（Huang定律：~41%/年，每2年翻倍）───────────────
% Y1=8, Y5=28, Y10=79, Y15=222 百万tokens/MWh
% 意义：随GPU代际更替，同样1MW算力每年能处理更多tokens，单token成本持续下降
if isfield(P,'eta_token_Y1') && isfield(P,'eta_token_gr_schedule')
    % Huang定律分段衰减：累积增长 = Π(1+gr_y)
    gr = P.eta_token_gr_schedule;
    eta_token_y = P.eta_token_Y1 * prod(1 + gr(1:max(0,year-1)));
elseif isfield(P,'eta_token_Y1') && isfield(P,'eta_token_gr')
    eta_token_y = P.eta_token_Y1 * (1 + P.eta_token_gr)^(year-1);
else
    eta_token_y = P.eta_token;   % fallback固定值
end
% Wright本地运营学习(有界内生增益, 叠加于全球技术进步之上)
% 结构: η = Huang日历底座(外生权威,全球技术) × 本地学习乘子(内生,≤1.15)
% 修正双重计数: Huang已含全球learning-by-doing, 此处仅刻画系统内
% 调度/利用率优化的运营级学习, 上限15%(数据中心运营优化的现实量级)
if (~isfield(P,'enable_wright') || P.enable_wright) && isfield(P,'cum_tokens_hint')
    w_T0 = 2e9; w_beta = 0.10;
    if isfield(P,'wright_T0');   w_T0   = P.wright_T0;   end
    if isfield(P,'wright_beta'); w_beta = P.wright_beta; end
    wright_mult = min(1.15, (1 + P.cum_tokens_hint / w_T0)^w_beta);
    eta_token_y = eta_token_y * wright_mult;
end

% ── 西部节点差异化电价（影响gamma_econ和运营收益）─────────────────────
if isfield(P,'lam_w_west') && length(P.lam_w_west) >= NI
    lam_w_node = P.lam_w_west(:);
else
    lam_w_node = P.lambda_energy_west * ones(NI,1);
end

% ── 三条独立算力价格曲线（基于国际权威数据，非简单线性趋势）──────────
%
% 曲线1: 实时推理(A/B类) — 三段式加速衰减
%   依据: Epoch AI(2024)推理价格2021-2025年降9-10x; TokenCost(2026)GPT-4→GPT-4.1 300x/26月
%   中国市场因GPU出口限制比国际慢约1-2年，采用-28%/-15%/-7%三阶段
%   Y1-Y5:-28%/年  Y6-Y10:-15%/年  Y11-Y15:-7%/年
%
% 曲线2: 批量推理(C类迁移) — 比实时下降更快
%   依据: OpenAI Batch API比标准便宜50%且折扣逐年扩大
%         DeepSeek V3(2025)推理成本降36x，主要冲击批量市场
%         Epoch AI: 批量推理降幅约为实时推理1.3-1.5倍
%   Y1-Y5:-35%/年  Y6-Y10:-20%/年  Y11-Y15:-10%/年
%
% 曲线3: 训练合同(D类) — 先升后降（需求>效率 → 效率反超）
%   依据: Epoch AI前沿训练成本年增2.4x(需求驱动); McKinsey数据中心CAGR≈22%
%         Dario Amodei(2024): $1B→$10B单次训练需求持续上升
%         NVIDIA Rubin(2028)目标10x推理效率，届时价格开始回落
%   Y1-Y6:+8%/年  Y7-Y15:-5%/年
%
% AR(1)波动: 反映价格战突袭(Y3/Y8)和需求冲击，非iid白噪声
% 固定随机种子保证每次运行结果一致(可重现)

rs_saved_ = rng; rng(year * 137 + 42);   % 固定种子(局部), 结束后恢复外层随机状态
% P5: 市场波动项可开关(enable_price_ar=false→确定性单调衰减曲线)
if isfield(P,'enable_price_ar') && ~P.enable_price_ar
    ar_eps_infer = 0; ar_eps_batch = 0; ar_eps_train = 0;
else
    ar_eps_infer = randn() * 0.06;   % σ=6%(实时推理波动)
    ar_eps_batch = randn() * 0.08;   % σ=8%(批量市场更不稳定)
    ar_eps_train = randn() * 0.04;   % σ=4%(训练合同相对稳定)
end
rng(rs_saved_);   % 原为rng('shuffle'): 使整条仿真不可复现

% ── 价格下降曲线（基于国际权威报告重新标定）─────────────────────────────
%
% A/B实时推理：Gartner(2026)全球每年-37%，但中国专属云受芯片制裁支撑，降幅更慢
%   Y1-5: -20%/年（芯片短缺+需求爆发，慢于全球平均）
%   Y6-10: -12%/年（国产芯片规模化，价格逐步下行）
%   Y11-15: -6%/年（成熟高SLA服务市场，差异化维持定价权）
infer_annual_rates = [1, 0.80,0.80,0.80,0.80, 0.88,0.88,0.88,0.88,0.88, 0.94,0.94,0.94,0.94,0.94];
infer_base_factor  = prod(infer_annual_rates(1:year));
infer_floor        = 0.08;   % 最低保留8%基准价（高SLA专属服务底部）
ar_shock_infer = 0;
if year == 3; ar_shock_infer = -0.08; end   % Y3 DeepSeek式价格冲击（缩小，中国市场已涨价）
if year == 8; ar_shock_infer = -0.06; end   % Y8 新一代国产芯片量产冲击
infer_decay = max(infer_floor, infer_base_factor * (1 + ar_eps_infer + ar_shock_infer));

% C类批量推理：商品化程度高，降幅比实时快但中国也受制裁影响
%   Y1-5: -25%/年  Y6-10: -15%/年  Y11-15: -8%/年
batch_annual_rates = [1, 0.75,0.75,0.75,0.75, 0.85,0.85,0.85,0.85,0.85, 0.92,0.92,0.92,0.92,0.92];
batch_base_factor  = prod(batch_annual_rates(1:year));
batch_floor        = 0.05;
ar_shock_batch = ar_shock_infer * 1.3;
batch_decay = max(batch_floor, batch_base_factor * (1 + ar_eps_batch + ar_shock_batch));

% 训练合同(D类)年度倍率 — 先升后降
% D类训练价格：芯片制裁+需求暴增 → Y1-6涨价更快(+10%/年 vs 旧+8%)
%   Y7-15: -5%/年（国产GPU追上后逐步降价，Sam Altman预测每年-90%为生产成本）
%   底部支撑：0.80×基准（训练算力稀缺性维持溢价）
train_annual_rates = [1,1.10,1.10,1.10,1.10,1.10, 0.95,0.95,0.95,0.95,0.95,0.95,0.95,0.95,0.95];
train_base_factor  = prod(train_annual_rates(1:year));
train_floor        = 0.80;   % 训练价格不会低于Y1的80%（稀缺性保护）
train_growth = train_base_factor * (1 + ar_eps_train);
train_growth = max(train_floor, min(2.0, train_growth));   % 底部0.80，最高2.0×

fprintf('     [价格曲线] Y%d: A/B实时×%.3f | C批量×%.3f | D训练×%.3f\n', ...
    year, infer_decay, batch_decay, train_growth);

% 区域系数
kappa_region_west = [1.05, 1.00, 1.03, 0.95];
kappa_region_east = [1.15, 1.20, 1.18];

% 集群规模系数(西部大集群优势)
kappa_cluster_west = [1.50, 1.30, 1.40, 1.10];

% 通信效率系数
kappa_comm_west = P.delta_comm;

% SKU-T训练定价(西部): 合同价年增(专属算力溢价)
p_T = zeros(NI, 1);
for i = 1:NI
    p_T(i) = P.lambda_compute_base * (1 + P.pi_service_T) ...
           * kappa_region_west(i) * kappa_cluster_west(i) * kappa_comm_west(i) ...
           * 0.04 * train_growth;   % 训练价逐年上升
end

% ── 三层SKU定价体系(论文核心: 服务等级×博弈定价) ─────────────────────
% 层1: A/B实时推理(最高) | 层2: B降级+C迁移(中) | 层3: D训练(最低,合同)

% ── 层1: A/B实时推理 — 推理价年降(算力摩尔定律) ─────────────────────
p_R = zeros(NJ, 1);
for j = 1:NJ
    p_R(j) = P.lambda_compute_base * (1 + P.pi_service_R) * kappa_region_east(j) ...
             * 0.05 * infer_decay;
end

% ── 层2a: B降级定价(随推理价联动) ────────────────────────────────────
p_B_deg = zeros(NJ, 1);
for j = 1:NJ
    p_B_deg(j) = p_R(j) * 0.60;
end

% ── 层2b: C类迁移协商价（批量推理专用曲线，下降更快）─────────────────
% C类可延迟、可替代性强，使用batch_decay(比实时推理降幅大)
p_B = P.lambda_compute_base * (1 + P.pi_service_B) * 0.035 * batch_decay * ones(NI, 1);
p_B_s = P.lambda_compute_base * (1 + P.pi_service_B) * 0.035 * batch_decay;

% ── 层3: D类训练合同价 — 合同价年增(专属算力溢价) ─────────────────────
p_T = zeros(NI, 1);
for i = 1:NI
    p_T(i) = P.lambda_token_base * (1 + P.pi_service_T) * kappa_cluster_west(i) ...
           * 0.04 * train_growth;   % 训练价逐年上升
end   % for i

SKU.p_T   = p_T;
SKU.p_R   = p_R;
SKU.p_B_deg = p_B_deg;
SKU.p_B   = p_B;
SKU.p_B_s = p_B_s;

% ── 消融M6：w/o SKU分级定价 → 所有服务统一均价 ───────────────────────
% 移除R/B/T三层价值分级，全部服务按均价计费，验证SKU价值分层贡献
if isfield(P,'ablation') && strcmp(P.ablation,'M6')
    p_uni = mean([mean(p_R), mean(p_B), mean(p_T)]);
    SKU.p_R   = p_uni * ones(size(p_R));
    SKU.p_B   = p_uni * ones(size(p_B));
    SKU.p_B_s = p_uni * ones(size(p_B_s));
    SKU.p_B_deg = p_uni * ones(size(p_B_deg));
    SKU.p_T   = p_uni * ones(size(p_T));
end

% 关键：将年度GPU效率和节点电价存入SKU，供子问题使用
SKU.eta_token  = eta_token_y;         % 本年GPU效率（Huang定律年度增长）
SKU.lam_w_node = lam_w_node;         % 西部各节点差异化电价（NI×1）
SKU.year       = year;               % 年份（供子问题内部使用）
% 物理现实: 可抢占/现货市场深度有限, 吸纳量≤κ_spot×合同(D类)token流量
D_hint_ = 0; if isfield(P,'D_peak_hint'); D_hint_ = P.D_peak_hint; end
spot_mult_ = 1.5; if isfield(P,'spot_market_mult'); spot_mult_ = P.spot_market_mult; end
trD_ = 0.22; if isfield(P,'task_ratio') && numel(P.task_ratio) >= 4; trD_ = P.task_ratio(4); end
SKU.spot_cap_tok_h = spot_mult_ * trD_ * max(D_hint_, 1) * 0.95 ...
    * eta_token_y / mean(P.eta_PUE_west) / P.N_west;   % 百万tok/h/节点

% 多厂商分层锚定(v4): 各层按目标价/基准Y1值缩放, 保留年度演化曲线形状
% 目标价单位元/百万tok → /1000转元/千tok; ÷基准Y1值得到该层缩放系数
rc_ = 1; if isfield(P,'rev_calib'); rc_ = P.rev_calib; end
if isfield(P,'price_endo_mult'); rc_ = rc_ * P.price_endo_mult; end  % 内生市场出清
if isfield(P,'pM_train')
    f_T = (P.pM_train/1000) / P.sku_ref_Y1(1) * rc_;
    f_R = (P.pM_rt   /1000) / P.sku_ref_Y1(2) * rc_;
    f_B = (P.pM_batch/1000) / P.sku_ref_Y1(3) * rc_;
    f_S = (P.pM_mig  /1000) / P.sku_ref_Y1(4) * rc_;
    SKU.p_T     = SKU.p_T     * f_T;
    SKU.p_R     = SKU.p_R     * f_R;
    SKU.p_B     = SKU.p_B     * f_B;
    SKU.p_B_deg = SKU.p_B_deg * f_B;   % 降级档随批量档联动(保持内部比例)
    SKU.p_B_s   = SKU.p_B_s   * f_S;   % 现货/迁移档: C层价格的真实字段
end
% M6消融的均一价必须在分层缩放后重算(否则均一性被分层系数破坏)
if isfield(P,'ablation') && strcmp(P.ablation,'M6')
    p_uni2 = mean([mean(SKU.p_T), mean(SKU.p_R), mean(SKU.p_B), mean(SKU.p_B_s)]);
    SKU.p_T = p_uni2*ones(size(SKU.p_T));   SKU.p_R   = p_uni2*ones(size(SKU.p_R));
    SKU.p_B = p_uni2*ones(size(SKU.p_B));   SKU.p_B_s = p_uni2*ones(size(SKU.p_B_s));
    SKU.p_B_deg = p_uni2*ones(size(SKU.p_B_deg));
end
% η效率传导折价: 竞争将效率增益按κ传导至价格(密度p·η增速回归温和区间)
% 实证锚: DeepSeek价格战即η↑→p↓同步; 无此折价则密度15年×3-10致IRR撞顶
% 分类传导(修复双重通缩): A/B/C为按token计价的API服务, 其锚定年降曲线本身
% 就是效率传导的观测结果, 不再叠加η折价(κ_API=0); D类训练按算力时长(GPU-h)
% 计价, 曲线不含效率项, 效率增益全部传导为单token降价(κ_D=1, 单位电量价值≈平)
kD_ = 1.0; if isfield(P,'pt_kappa_D');   kD_ = P.pt_kappa_D;   end
kA_ = 0.0; if isfield(P,'pt_kappa_API'); kA_ = P.pt_kappa_API; end
dD_ = (P.eta_token_Y1 / eta_token_y)^kD_;
dA_ = (P.eta_token_Y1 / eta_token_y)^kA_;
SKU.p_T   = SKU.p_T  *dD_; SKU.p_R    = SKU.p_R   *dA_;
SKU.p_B   = SKU.p_B  *dA_; SKU.p_B_s  = SKU.p_B_s *dA_;
SKU.p_B_deg = SKU.p_B_deg*dA_;
SKU.density = [mean(SKU.p_T), mean(SKU.p_R), mean(SKU.p_B_s)] * 1000 * eta_token_y;  % 元/MWh(IT)
fprintf('  [SKU三层] 训练(D类)%.3f | B批量%.3f | C迁移/现货%.3f | A/B实时%.3f (元/百万tokens)\n', ...
    mean(SKU.p_T)*1000, mean(SKU.p_B)*1000, mean(SKU.p_B_s)*1000, mean(SKU.p_R)*1000);

end   % compute_SKU_pricing


%% ─── 准备情景数据 ────────────────────────────────────────────────────
function sd = prepare_scenario_data(scenarios, s, demand_y, SKU, P)
T = P.T;
NI = P.N_west; NJ = P.N_east;

% 综合CF(用于储能解析)
sd.CF_renew = squeeze((scenarios.cf_wind(s,:,:) + scenarios.cf_pv(s,:,:))/2);
if size(sd.CF_renew, 1) ~= NI
    sd.CF_renew = sd.CF_renew';
end
sd.CF_renew = max(0.01, sd.CF_renew);

% 西部电价(NI×T)
sd.lam_w = squeeze(scenarios.price_west(s,:,:));
if size(sd.lam_w, 1) ~= NI
    sd.lam_w = sd.lam_w';
end

% 东部电价
sd.lam_e = squeeze(scenarios.price_east(s,:,:));
if size(sd.lam_e, 1) ~= NJ
    sd.lam_e = sd.lam_e';
end

% Token价格(标量序列)
sd.lam_token = P.lambda_token_base * (0.9 + 0.2*rand(1, T));

% 算力需求时序(MW)
sd.Lambda_A = demand_y(1, :);
sd.Lambda_B = demand_y(2, :);
sd.Lambda_C = demand_y(3, :);
% 需求不确定性: 用情景的demand_factor对需求进行扰动(论文稀疏维度不确定)
if isfield(scenarios, 'demand_factor') && ~isempty(scenarios.demand_factor)
    df = scenarios.demand_factor(s);
    sd.Lambda_B = sd.Lambda_B * df;
    sd.Lambda_C = sd.Lambda_C * df;   % A类刚性需求扰动小, B/C类弹性大
end
sd.Lambda_D = demand_y(4, :);

% 平均到达率
sd.mean_B = mean(sd.Lambda_B);

% 初始SOC（从state传入，反映上一年末状态）
% 若state有E_soc_final字段，用上年末储能均值；否则保持缺省50%
if isfield(P, 'soc_init_frac') && length(P.soc_init_frac) >= NI
    sd.soc_init = P.soc_init_frac;   % NI×1，各节点初始SOC比例
else
    sd.soc_init = 0.5 * ones(NI, 1);
end
sd.mean_C = mean(sd.Lambda_C);
end


%% ─── 初始可行方案 ────────────────────────────────────────────────────
function x_init = make_init_solution(state, P, demand_y)
NI = P.N_west; NJ = P.N_east;
x_init = struct();

% ── 选址：完全自动，不硬编码任何节点 ─────────────────────────────────
% 逻辑与主问题第0轮一致：按CF→gamma_econ→F1从低到高排序，选最优单节点
% （此函数仅在主问题第0轮失败时作fallback，正常路径走solve_master_problem）
if all(state.z_cum == 0)
    % 首年fallback：自动选CF最高（gamma最小，F1最低）的节点
    if isfield(P,'CF_wind_west') && isfield(P,'CF_pv_west')
        CF_avg = (P.CF_wind_west + P.CF_pv_west) / 2;   % NI×1 各节点CF均值
    else
        CF_avg = 0.20 * ones(NI, 1);
    end
    [~, best_i] = max(CF_avg);   % CF最高→gamma最小→F1最低→自动选此节点
    x_init.z = zeros(NI, 1);
    x_init.z(best_i) = 1;
else
    % 后续年份：保持已有选址（主问题可在此基础上扩展）
    x_init.z = state.z_cum;
end

% 容量: 合同基线 + P2弹性(承接C类迁移), 与C20约束一致
% 否则x_init规模过小, 其UB最优会锁定x_best, 主问题的合理方案被丢弃
n_sel = max(1, sum(x_init.z));
D_peak_C = max(demand_y(3, :));
W_P2_elastic_per = 0.40 * D_peak_C / n_sel;   % P2弹性均分到选中节点
W_T_min_i = zeros(NI, 1);
for i = 1:NI
    % 各选中节点: 合同保障 + 均分的P2弹性
    W_T_min_i(i) = (P.W_contract_D(i)/P.eta_PUE_west(i) + W_P2_elastic_per);
    W_T_min_i(i) = max(P.W_train_min, min(P.W_train_max, W_T_min_i(i)));
end
x_init.W_T = max(state.W_T_cum, W_T_min_i .* x_init.z);

% 推理容量满足A类峰值
D_peak_A    = max(demand_y(1, :));
D_median_B  = median(demand_y(2, :)) * 0.8;
target_per_node = (1 + P.phi_reserve) * (D_peak_A + D_median_B) / NJ;
x_init.W_I = max(state.W_I_cum, target_per_node * ones(NJ, 1));

% 绿电
x_init.G = max(state.G_cum, 1.8 * x_init.W_T);   % 绿电超配下限1.8(与gamma_econ一致)

% 储能
x_init.E_w = max(state.E_w_cum, P.mu_min * x_init.G * P.dt_stor);
x_init.E_e = max(state.E_e_cum, P.ratio_A * x_init.W_I ./ P.eta_PUE_east' * P.T_backup);

% HVDC（dL_cum已是NI×NJ矩阵）
x_init.dL = state.dL_cum;   % NI×NJ

% F1计算（dL用sum(sum(...))处理NI×NJ）
x_init.F1_total = P.C_train_fix * sum(x_init.W_T) ...
                + P.C_renew_wind * 1000 * sum(x_init.G) * 0.5 ...
                + P.C_renew_pv   * 1000 * sum(x_init.G) * 0.5 ...
                + P.C_stor * 1000 * sum(x_init.E_w) ...
                + P.C_infer_fix  * sum(x_init.W_I) ...
                + P.C_stor * 1000 * sum(x_init.E_e) ...
                + sum(sum(P.C_trans_per_node .* x_init.dL));

F1_cum_state = P.C_train_fix * sum(state.W_T_cum) ...
             + P.C_renew_wind * 1000 * sum(state.G_cum) * 0.5 ...
             + P.C_renew_pv * 1000 * sum(state.G_cum) * 0.5 ...
             + P.C_stor * 1000 * sum(state.E_w_cum) ...
             + P.C_infer_fix * sum(state.W_I_cum) ...
             + P.C_stor * 1000 * sum(state.E_e_cum) ...
             + sum(sum(P.C_trans_per_node .* state.dL_cum));

x_init.F1_incremental = max(0, x_init.F1_total - F1_cum_state);
x_init.theta = 0;
end


%% 高价值密度候选方案（选w最高节点，供多起点评估用）
% 与make_init_solution使用完全相同的W_T/G/E计算，只改变z（节点选择）
% 确保两个候选的比较只反映节点价值差异，不被W_T规模差异污染
function x_init = make_init_solution_high_w(state, P, demand_y, SKU, AEMF)
NI = P.N_west; NJ = P.N_east;
x_init = struct();

if any(state.z_cum > 0)
    x_init.z = state.z_cum;
else
    % 选训练价格最高的节点（kappa最大=内蒙，体现价值感知）
    if isfield(SKU,'p_T') && length(SKU.p_T) >= NI
        [~, best_i] = max(SKU.p_T(:));
    elseif isfield(P,'kappa_cluster_west')
        [~, best_i] = max(P.kappa_cluster_west(:));
    else
        best_i = 1;
    end
    x_init.z = zeros(NI,1);
    x_init.z(best_i) = 1;
end

% W_T/G/E：与make_init_solution相同的计算逻辑（公平比较）
D_peak_total = max(sum(demand_y,1));
D_peak_train = D_peak_total * P.task_ratio(4);
n_sel = max(1, sum(x_init.z));
W_T_lb = min(max(0.8*D_peak_train, 0.15*D_peak_total), P.K_max*P.W_train_max*0.95);
W_T_per = W_T_lb / n_sel;

for i = 1:NI
    W_T_min_i = max(P.W_contract_D(i)/P.eta_PUE_west(i), W_T_per);
    W_T_min_i = max(P.W_train_min, min(P.W_train_max, W_T_min_i));
    x_init.W_T(i,1) = max(state.W_T_cum(i), W_T_min_i * x_init.z(i));
end
s_hub = 0.5; if isfield(P,'hub_share_max'); s_hub = P.hub_share_max; end
b_hub = 400; if isfield(P,'hub_base_MW');   b_hub = P.hub_base_MW;   end
if isfield(SKU,'p_T') && length(SKU.p_T) >= NI; sc_ = SKU.p_T(:);
elseif isfield(P,'kappa_cluster_west'); sc_ = P.kappa_cluster_west(:); else; sc_ = (NI:-1:1)'; end
for guard_ = 1:NI
    tot_ = sum(x_init.W_T);
    if all(x_init.W_T <= s_hub*tot_ + b_hub + 1e-6 | x_init.W_T <= state.W_T_cum(:) + 1e-6) || all(x_init.z > 0.5); break; end
    cand_ = find(x_init.z < 0.5); [~, k_] = max(sc_(cand_)); x_init.z(cand_(k_)) = 1;
    W_T_per = W_T_lb / sum(x_init.z);
    for i = 1:NI
        W_T_min_i = max(P.W_contract_D(i)/P.eta_PUE_west(i), W_T_per);
        W_T_min_i = max(P.W_train_min, min(P.W_train_max, W_T_min_i));
        x_init.W_T(i,1) = max(state.W_T_cum(i), W_T_min_i * x_init.z(i));
    end
end

D_peak_A_w    = max(demand_y(1,:));
D_median_B_w  = median(demand_y(2,:)) * 0.8;
D_infer_w     = D_peak_A_w + D_median_B_w;
x_init.W_I = max(state.W_I_cum, (1+P.phi_reserve)*D_infer_w/NJ * ones(NJ,1));

if isfield(AEMF,'gamma_econ') && length(AEMF.gamma_econ)>=NI
    g = AEMF.gamma_econ(:);
else
    g = 1.8*ones(NI,1);
end
for i = 1:NI
    x_init.G(i,1) = max(state.G_cum(i), g(i)*x_init.W_T(i));
end
x_init.E_w = max(state.E_w_cum, P.mu_min*x_init.G*P.dt_stor);
x_init.E_e = max(state.E_e_cum, P.ratio_A*x_init.W_I./P.eta_PUE_east'*P.T_backup);
x_init.dL  = state.dL_cum;
if ~isequal(size(x_init.dL),[NI,NJ]); x_init.dL=zeros(NI,NJ); end

x_init.F1_total = P.C_train_fix*sum(x_init.W_T) ...
    + (P.C_renew_wind+P.C_renew_pv)*1000*sum(x_init.G)*0.5 ...
    + P.C_stor*1000*(sum(x_init.E_w)+sum(x_init.E_e)) ...
    + P.C_infer_fix*sum(x_init.W_I) ...
    + sum(sum(P.C_trans_per_node.*x_init.dL));
x_init.F1_incremental = max(0, x_init.F1_total);
x_init.theta = 0;
end

function s = ifelse_tr(g)
if g; s = '(全局)'; else; s = '(信赖域)'; end
end

function x_z = init_for_z(zv, x_init, state, P, demand_y, SKU, AEMF, year)
% 给定选址z的启发式容量(与make_init_solution_high_w同一规则): 训练下界按所选节点均分, 绿电/储能随之配置
NI = P.N_west; x_z = x_init; x_z.z = double(zv(:));
D_peak_total = max(sum(demand_y,1)); D_peak_train = D_peak_total * P.task_ratio(4);
W_T_lb = min(max(0.8*D_peak_train, 0.15*D_peak_total), P.K_max*P.W_train_max*0.95);
W_T_per = W_T_lb / max(1, sum(x_z.z));
for i = 1:NI
    W_T_min_i = max(P.W_contract_D(i)/P.eta_PUE_west(i), W_T_per);
    W_T_min_i = max(P.W_train_min, min(P.W_train_max, W_T_min_i));
    x_z.W_T(i,1) = max(state.W_T_cum(i), W_T_min_i * x_z.z(i));
end
if isfield(AEMF,'gamma_econ') && numel(AEMF.gamma_econ) >= NI && all(isfinite(AEMF.gamma_econ(:)))
    g = AEMF.gamma_econ(:);
else
    g = 1.8*ones(NI,1);
end
for i = 1:NI; x_z.G(i,1) = max(state.G_cum(i), g(i)*x_z.W_T(i)); end
x_z.E_w = max(state.E_w_cum(:), P.mu_min*x_z.G*P.dt_stor);
if isfield(x_init,'rt') && ~isempty(x_init.rt); x_z.rt = x_init.rt .* (x_z.z(:) > 0.5); end
C_ie = P.C_infer_fix * max(0.65, (1 - 0.05*min(year-1, 8)));
x_z.F1_incremental = P.C_train_fix*sum(max(0, x_z.W_T(:) - state.W_T_cum(:))) ...
    + C_ie*sum(max(0, x_z.W_I(:) - state.W_I_cum(:))) ...
    + (P.C_renew_wind + P.C_renew_pv)*1000*sum(max(0, x_z.G(:) - state.G_cum(:)))*0.5 ...
    + P.C_stor*1000*(sum(max(0, x_z.E_w(:) - state.E_w_cum(:))) + sum(max(0, x_z.E_e(:) - state.E_e_cum(:))));
x_z.F1_total = x_z.F1_incremental;
x_z.theta = 0;
end

function xu = corner_point(x_init, state, P, demand_y)
% 需求可利用容量上界处的规划点(训练/推理/绿电/储能/HVDC/路由均取本年可达上限)
NI = P.N_west; NJ = P.N_east; xu = x_init; xu.z = ones(NI,1);
Dh = max(sum(demand_y,1)); tr = P.task_ratio;
kB = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
sm = 1.5;  if isfield(P,'spot_market_mult'); sm = P.spot_market_mult; end
U_T = 1.2*Dh*(tr(4) + tr(3) + kB*tr(2)) + sm*tr(4)*Dh;
U_I = 1.2*(1 + P.phi_reserve)*Dh*(tr(1) + tr(2) + tr(3));
xu.W_T = max(state.W_T_cum(:), U_T/NI*ones(NI,1));
wI0 = max(x_init.W_I(:), 1); xu.W_I = max(state.W_I_cum(:), U_I * wI0/sum(wI0));
ex = 0.5; if isfield(P,'expand_max_annual'); ex = P.expand_max_annual; end
dLc = zeros(NI,NJ); if isfield(state,'dL_cum') && isequal(size(state.dL_cum),[NI NJ]); dLc = state.dL_cum; end
xu.dL = dLc + ex*P.HVDC_cap_per_node;
ge = 1.5; if isfield(P,'green_export_ratio'); ge = P.green_export_ratio; end
xu.G = max(state.G_cum(:), P.gamma_max*xu.W_T + ge*(sum(P.HVDC_cap_per_node,2) + sum(xu.dL,2)));
xu.E_w = max(state.E_w_cum(:), 2*P.mu_min*xu.G*P.dt_stor);
xu.E_e = max(state.E_e_cum(:), 2*x_init.E_e(:));
xu.rt = ones(NI,NJ);
end

function xm = blend_point(xa, xb, w)
xm = xa; f = {'W_T','W_I','G','E_w','E_e','dL','rt'};
for k = 1:numel(f)
    if isfield(xa,f{k}) && isfield(xb,f{k}) && isequal(size(xa.(f{k})), size(xb.(f{k})))
        xm.(f{k}) = (1-w)*xa.(f{k}) + w*xb.(f{k});
    elseif isfield(xb,f{k})
        xm.(f{k}) = w*xb.(f{k});
    end
end
xm.z = max(xa.z(:), xb.z(:));
end

function [pw, Qd] = dro_value(Qv, scenarios, AEMF, scen_feat, P)
% 给定各情景运行成本, 返回该点处的最坏分布与DRO值(与主循环同一口径)
if isfield(P,'ablation') && strcmp(P.ablation,'M3')
    pw = scenarios.pi_s(:); Qd = sum(pw .* Qv(:)); return;
end
[pw, Qd] = compute_worst_case_distribution(Qv(:), scenarios.pi_s, AEMF.epsilon_1, scen_feat);
pw = pw(:);
end

function xp = project_to_master(xc, P, AEMF, demand_y, state, year)
% 在主问题全部约束下求离xc最近(年金加权L1)的可行方案; 失败时原样返回
Pp = P; Pp.proj_target = xc; Pp.tr = struct('on', false);
try
    [xp, ~] = solve_master_problem(Pp, AEMF, demand_y, state, {}, year);
    if ~isstruct(xp) || ~isfield(xp,'W_T') || isempty(xp.W_T); xp = xc; return; end
    if isfield(xc,'theta'); xp.theta = 0; end
catch
    xp = xc;
end
end
