%% =========================================================================
%  solve_master_problem.m  —  VAIC主问题(MIP, YALMIP+Gurobi)
%  对应论文式(4)(5)(37)(38) + 约束C1-C19
%  
%  输入: P, AEMF, demand_y, state(累计状态), cuts(VAIC割集), year
%  输出: x_sol(本年决策), LB
%% =========================================================================
function [x_sol, LB] = solve_master_problem(P, AEMF, demand_y, state, cuts, year)

NI = P.N_west; NJ = P.N_east;

%% ── 决策变量 ────────────────────────────────────────────────────────────
yalmip('clear');
z   = binvar(NI, 1);            % 本年选址(0/1)
W_T = sdpvar(NI, 1);            % 本年训练容量(MW)
W_I = sdpvar(NJ, 1);            % 本年推理容量
G   = sdpvar(NI, 1);            % 本年绿电装机(MW)
E_w = sdpvar(NI, 1);            % 西部储能(MWh)
E_e = sdpvar(NJ, 1);            % 东部储能(MWh)
dL  = sdpvar(NI, NJ);            % HVDC扩容(MW)：NI×NJ矩阵，西部节点i→东部节点j
theta = sdpvar(1, 1);           % Benders下界变量(万元)
% 通信路由升级变量(须先于F1定义; 原定义在引用之后, 首次启用即崩溃)
rt = []; rtc = zeros(NI, NJ);
if ~isfield(P,'enable_route_invest') || P.enable_route_invest
    rt = binvar(NI, NJ, 'full');
    if isfield(state,'rt_cum') && ~isempty(state.rt_cum); rtc = state.rt_cum; end
end

% dL_cum_mat：历史累计HVDC，提前定义供目标函数和约束共用
if numel(state.dL_cum) == NJ
    dL_cum_mat = zeros(NI, NJ);
elseif isequal(size(state.dL_cum), [NI, NJ])
    dL_cum_mat = state.dL_cum;
else
    dL_cum_mat = zeros(NI, NJ);
end

%% ── 目标函数: F1_本年新增 + theta ───────────────────────────────────────
% 第一阶段成本(万元): 本年新增投资（含HVDC路径差异化建设成本，同行避免YALMIP一元+警告）
% 规模经济修正：推理中心前8年每年降本5%（大规模集采+设计标准化）
% 依据：AWS/Azure数据中心建设成本每年降约5-8%（批量采购+模块化）
C_infer_eff = P.C_infer_fix * max(0.65, (1 - 0.05 * min(year-1, 8)));
hvdc_invest = sum(sum(P.C_trans_per_node .* (dL - dL_cum_mat)));
route_invest = 0;
if ~isempty(rt)
    route_invest = sum(sum(P.C_route_per_pair .* (rt - rtc)));
end
F1 = P.C_train_fix * sum(W_T) + P.C_renew_wind * 1000 * sum(G) * 0.5 + P.C_renew_pv * 1000 * sum(G) * 0.5 + P.C_stor * 1000 * sum(E_w) + C_infer_eff * sum(W_I) + P.C_stor * 1000 * sum(E_e) + hvdc_invest + route_invest;

% 目标: 年化投资 + 年度运营净成本(theta)
% 储能按T_stor_life(10年)年化折旧, 其余设备按T_life(20年)
% F1中储能部分=C_stor×E, 年化应÷T_stor_life而非T_life(电池寿命短于项目寿命)
F1_stor_w = P.C_stor * 1000 * sum(E_w);
F1_stor_e = P.C_stor * 1000 * sum(E_e);
F1_nonstor = F1 - F1_stor_w - F1_stor_e;
% epsilon_w的合理范围推导：
%   目标：w×epsilon_w×W_T_diff 能与 F1/T_life差异相抗衡（但不主导）
%   F1/T_life差异 ≈ C_renew×ΔG/T_life = 285×(gamma_diff)×W_T/T_life
%   典型值：285×0.15×260/20 = 554万（内蒙vs宁夏）
%   w差异：w_内蒙(10) - w_宁夏(9.06) = 0.94
%   epsilon_w ∈ [F1_diff_lower/w_diff/W_T_max, F1_diff_upper/w_diff/W_T_min]
%   = [554/(0.94×5000), 2000/(0.94×260)] = [0.00012, 0.0082]
%   取中间值0.001（可做敏感性分析验证）
epsilon_w = 0.0010;   % 万元/MW（理论范围[0.0001, 0.008]，取中间值）
if isfield(AEMF,'w_density') && ~any(isnan(AEMF.w_density)) && length(AEMF.w_density) >= NI
    w_safe = max(0.1, AEMF.w_density(:));
else
    w_safe = ones(NI, 1);  % fallback：等权（Y1首次调用时保护）
end
if ~isfield(P,'capex_crf') || P.capex_crf
    xs_ = struct('W_T',W_T,'W_I',W_I,'G',G,'E_w',E_w,'E_e',E_e,'dL',dL,'rt',rt);
    F1_ann_expr = capex_annual(xs_, state, P, year);
    F1_nonstor = F1_ann_expr * P.T_life; F1_stor_w = 0; F1_stor_e = 0;   % 使下式等于CRF年金
end
objective = F1_nonstor / P.T_life ...
          + F1_stor_w / P.T_stor_life ...
          + F1_stor_e / P.T_stor_life ...
          + theta ...
          - epsilon_w * sum(w_safe .* W_T);
% ── 创新三: VLM-WM前瞻修正(把"本年价值代表全寿命"改为推演的前瞻均值) ──
% 只进入一阶段目标(新增容量的线性项), 不改Benders割 → 割有效性不受影响
if (~isfield(P,'enable_world_model') || P.enable_world_model) && isfield(P,'wm') ...
        && isstruct(P.wm) && isfield(P.wm,'active') && P.wm.active && numel(P.wm.adj) == 7
    kw = 0.5; if isfield(P,'world_model_kappa'); kw = P.world_model_kappa; end
    adj = P.wm.adj(:);
    K_new = [sum(W_T) - sum(state.W_T_cum); sum(W_I) - sum(state.W_I_cum); ...
             sum(G) - sum(state.G_cum); sum(E_w) - sum(state.E_w_cum); ...
             sum(E_e) - sum(state.E_e_cum); sum(dL(:)) - sum(dL_cum_mat(:))];
    objective = objective - kw * (adj(1:6)' * K_new);
    if ~isempty(rt)
        objective = objective - kw * adj(7) * (sum(rt(:)) - sum(rtc(:)));
    end
end

%% ── 约束 ────────────────────────────────────────────────────────────────
cons = [];
cons_hub = [];   % 枢纽集中度约束(单独成组, 便于不可行时诊断与回退)

% C0: 已选址锁定为开放(state.z_cum=1的节点强制z=1)
for i = 1:NI
    if state.z_cum(i) >= 0.5
        cons = [cons, z(i) == 1];
    end
end

% C1: 容量边界(Big-M)
cons = [cons, W_T >= P.W_train_min * z];
cons = [cons, W_T <= P.W_train_max * z];

% 已建容量不可拆除: W_T >= W_T_cum
cons = [cons, W_T >= state.W_T_cum];

% C2: 训练节点数上限
cons = [cons, sum(z) <= P.K_max];

% C3: HVDC扩容 — 与选址强耦合（论文核心贡献：算力选址驱动输电网扩容）
% dL_cum_mat 已在函数顶部定义
BIG_M = 3000;
D_peak_C = max(demand_y(3, :));    % C类峰值需求(MW)
cons = [cons, dL >= 0];
cons = [cons, dL >= dL_cum_mat];   % 不可逆（已建HVDC不缩减）

for i = 1:NI
    for j = 1:NJ
        cap_ij = P.HVDC_cap_per_node(i, j);
        % 选址激活约束：只有z(i)=1时才能扩建第i条西部输电通道
        cons = [cons, dL(i,j) <= dL_cum_mat(i,j) + BIG_M * z(i)];
        % 工程上界：总扩容不超过现有容量的expand_max倍
        cons = [cons, dL(i,j) <= dL_cum_mat(i,j) + P.expand_max * cap_ij * z(i)];
        % 年度扩容速率限制（HVDC建设周期约3-5年）
        annual_inc_max = P.expand_max_annual * cap_ij;
        cons = [cons, dL(i,j) - dL_cum_mat(i,j) <= annual_inc_max * z(i)];
        % 迁移需求驱动：C类可迁移量的30%需HVDC承载（分摊给选中的通道）
        mig_need = 0.30 * D_peak_C / (NI * NJ);
        needed = max(0, mig_need - cap_ij * 0.7);
        % 可行性护栏: 需求驱动下界不得超过年度扩容上界(否则Y8级需求跳变致不可行)
        needed = min(needed, annual_inc_max * 0.95);
        % 默认关闭: 迁移任务经光纤传输、在西部就地用电, 不需要HVDC承载;
        % HVDC价值应来自电力外送套利(由子问题评估), 而非强制下界(P.hvdc_mig_coupling=true可恢复)
        if needed > 0 && isfield(P,'hvdc_mig_coupling') && P.hvdc_mig_coupling
            cons = [cons, dL(i,j) >= dL_cum_mat(i,j) + needed * z(i)];
        end
    end
end

% C4: 绿电覆盖率 — 使用节点差异化gamma_econ（高CF节点gamma小，低CF节点gamma大）
% 这是选址差异化的核心：内蒙CF高→gamma小→G少→F1低，主问题自然优先选内蒙
for i = 1:NI
    if length(AEMF.gamma_econ) >= NI
        gamma_i = AEMF.gamma_econ(i);   % 节点i专属配比（CF越低越大）
    else
        gamma_i = AEMF.gamma_econ(1);   % fallback: 标量
    end
    cons = [cons, G(i) >= gamma_i * W_T(i)];
    % 放宽为"本地算力消纳 + 外送通道配套"(HVDC容量×配套比), 让规划在"搬电子/搬token"间真正选择
    ge_ = 0; if isfield(P,'green_export_ratio'); ge_ = P.green_export_ratio; end
    if ge_ > 0
        hv_i  = sum(P.HVDC_cap_per_node(i,:)) + sum(dL(i,:));
        hv_c  = sum(P.HVDC_cap_per_node(i,:)) + sum(dL_cum_mat(i,:));
        exc_i = max(0, 1.02*state.G_cum(i) - (P.gamma_max*state.W_T_cum(i) + ge_*hv_c));   % 历史超额(保证可行)
        cons = [cons, G(i) <= P.gamma_max * W_T(i) + ge_ * hv_i + exc_i];
    else
        cons = [cons, G(i) <= max(P.gamma_max * W_T(i), state.G_cum(i) * 1.02)];
    end
end
cons = [cons, G >= state.G_cum];

% C5: 储能比例下界
cons = [cons, E_w >= P.mu_min * G * P.dt_stor];

% C16: 训练合同保障
for i = 1:NI
    Pc_min_i = P.W_contract_D(i) / P.eta_PUE_west(i);
    cons = [cons, W_T(i) >= Pc_min_i * z(i)];
end

% C17: 西部储能能量缺口下界
for i = 1:NI
    cons = [cons, E_w(i) >= AEMF.E_C17(i) * z(i)];
end

% C6: 推理峰值需求保障
% 软化保护: 目标覆盖A+B+C总峰值, 但不超过容量物理上界(缺口靠积压/C类迁移消化)
% 避免需求增长超过容量上界时主问题不可行
% W_I下界：A类必须全覆盖（刚性SLA≤10ms）+ B类按中位数覆盖（峰值时段会排队→产生违约）
% 正确逻辑：B类需求峰值约为均值的1.5-2倍，以均值配置容量后峰值会有10-20%违约率
D_peak_A    = max(demand_y(1, :));          % A类：100%覆盖（刚性）
D_median_B  = median(demand_y(2, :)) * 0.8; % B类：80%中位数（约15%的时段B类会排队）
D_peak_infer = D_peak_A + D_median_B;       % 不含C类（可迁移，不占推理容量）
W_I_target = min((1 + P.phi_reserve) * D_peak_infer, NJ * P.W_infer_max * 0.98);
% (W_I下界含B类可达减免, 见路由约束块之后)
cons = [cons, W_I >= state.W_I_cum];
cons = [cons, W_I >= P.W_infer_min];
cons = [cons, W_I <= P.W_infer_max];
% 对称训练侧: 推理总量≤需求峰值×裕度倍数, 防master把W_I堆满绝对上限
WI_ub_mult = 1.5; if isfield(P,'WI_ub_demand_mult'); WI_ub_mult = P.WI_ub_demand_mult; end
W_I_ub_demand = (1 + P.phi_reserve) * D_peak_infer * WI_ub_mult;
cons = [cons, sum(W_I) <= max(W_I_ub_demand, sum(state.W_I_cum))];
% 推理容量年度建设速率(首年豁免, 对称训练侧)
sum_cum_WI = sum(state.W_I_cum);
if sum_cum_WI > 1
    WI_add_min = 800; WI_add_frac = 0.6;
    if isfield(P,'WI_annual_add_min');  WI_add_min  = P.WI_annual_add_min;  end
    if isfield(P,'WI_annual_add_frac'); WI_add_frac = P.WI_annual_add_frac; end
    cons = [cons, sum(W_I) - sum_cum_WI <= max([WI_add_min, WI_add_frac * sum_cum_WI, W_I_target - sum_cum_WI])];
end

% C18-C19: 东部储能/可用容量(简化)
for j = 1:NJ
    cons = [cons, E_e(j) >= P.ratio_A * W_I(j) / P.eta_PUE_east(j) * P.T_backup];
end
cons = [cons, E_e >= state.E_e_cum];

% C20: 训练容量软约束(需求驱动, 不含P1节点强制)
% 选哪些节点、容量多少完全由VAIC价值密度+经济权衡决定
% 无强制节点组合, 贵州是否被选由边际收益>边际成本经济决定
D_peak_total = max(sum(demand_y, 1));
D_peak_train = max(demand_y(4, :));
W_T_lb_soft = min(max(0.8 * D_peak_train, 0.15 * D_peak_total), P.K_max * P.W_train_max * 0.95);
% W_T上界收紧：基于训练需求驱动，防止epsilon_w或其他因素推高到极端值
% 原2.5×D_peak_total=2813MW在Y1单节点时过松（Y1训练需求仅168MW）
% 合理上界：D_peak_train × 需求倍率 × 节点数
D_peak_train_y = max(demand_y(4,:));
W_T_ub_demand  = max(D_peak_train_y * 3.0, P.W_train_min * P.K_max);  % 需求的3倍上限(原8倍过松致超建)
W_T_ub_soft = min(W_T_ub_demand, P.K_max * P.W_train_max * 0.98);
cons = [cons, sum(W_T) >= W_T_lb_soft];
cons = [cons, sum(W_T) <= W_T_ub_soft];

% C21: 节点间训练容量平衡约束（防止宁夏CF优势导致单节点极度超配）
% 根因：CF_wind_west(宁夏)=0.24最高，G=gamma×W_T，优化器将所有W_T集中到宁夏
% 物理约束：各已选址节点的W_T之比不应超过kappa比值的2倍（商业价值限制极端集中）
% 约束形式：W_T(i) ≤ balance_factor × (sum(W_T)/n_selected) 对所有已选节点
% C21(v2): 增量份额约束——单节点本年新增 ≤ share_max × 总新增
% 修复P3: 原式cap=κ̃×(ub_soft/n)×1.5因ub_soft巨大而形同虚设(Y5-Y7宁夏独涨953)
% 祖父条款: 只约束增量不动已锁定存量, 天然兼容任何历史锁定(Y8+不可行嫌疑排除)
share_max = 0.45; if isfield(P,'share_max_WT'); share_max = P.share_max_WT; end
sum_cum_WT = sum(state.W_T_cum);
for i = 1:NI
    % 又受最小容量与合同下界约束, 叠加年度速率上限后, 当只有1个节点在役且需求下界要求扩容时无解。
    % 增加"需求所需增量+最小单节点容量"的免份额额度, 保证下界总能落在已选节点上
    % 改为存量集中度: 单枢纽训练容量 ≤ s_hub·全国训练容量 + 基础规模(早期允许单点起步, 后期必须多点布局);
    % 历史超额为常数, 保证续跑/历史锁定下可行
    s_hub = 0.5;  if isfield(P,'hub_share_max'); s_hub = P.hub_share_max; end
    b_hub = 400;  if isfield(P,'hub_base_MW');   b_hub = P.hub_base_MW;   end
    exc_h = max(0, state.W_T_cum(i) - (s_hub*sum_cum_WT + b_hub));
    cons_hub = [cons_hub, W_T(i) <= s_hub * sum(W_T) + b_hub + exc_h];
    cons = [cons, W_T(i) >= state.W_T_cum(i)];   % 锁定容量不可退
end
% ── 通信路由升级决策(边界2: 时延投资, token带宽极轻故杠杆在时延) ──────
if ~isempty(rt)
    cons = [cons, rt(:) >= rtc(:)];                     % 已建路由不可退
    rmax = 2; if isfield(P,'route_annual_max'); rmax = P.route_annual_max; end
    cons = [cons, sum(rt(:)) - sum(rtc(:)) <= rmax];    % 年度工程节奏
    for i = 1:NI
        cons = [cons, rt(i,:) <= z(i)];                 % 仅向已选址节点建直连
    end
end
% ── 创新一: B类时延门控可达 → 东部推理容量需求减免(双网替代的容量通道) ──
% reach_j ≤ Σ_i B0_ij·z_i + U_ij·rt_ij : 基准可达靠选址, 升级可达靠路由投资
WI_relief = 0;
if ~isfield(P,'enable_B_reach') || P.enable_B_reach
    Pr_ = P; if isfield(P,'plan_d_max_B') && ~isempty(P.plan_d_max_B); Pr_.d_max_B_mig = P.plan_d_max_B; end
    [B0r, Ur] = reach_potential(Pr_);
    reach = sdpvar(NJ, 1);
    cons = [cons, 0 <= reach <= 1];
    for j = 1:NJ
        rexpr = B0r(:,j)' * z;
        if ~isempty(rt); rexpr = rexpr + Ur(:,j)' * rt(:,j); end
        cons = [cons, reach(j) <= rexpr];
    end
    kB = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
    shB = P.east_B_share(:);
    WI_relief = (1 + P.phi_reserve) * kB * D_median_B * (shB' * reach);
end
cons = [cons, sum(W_I) >= W_I_target - WI_relief];
% C21c: 年度建设速率上限(GPU供给链+工程周期, 防单年爆量与松弛套利)
% 首年豁免: greenfield初建规模由合同下限/需求决定(2-3节点×~260MW合同≥523),
% 速率约束自Y2起管扩张(否则500上限与合同最小规模死锁→Y1不可行)
if sum_cum_WT > 1
    add_min_ = 500; add_frac_ = 0.6;
    if isfield(P,'WT_annual_add_min');  add_min_  = P.WT_annual_add_min;  end
    if isfield(P,'WT_annual_add_frac'); add_frac_ = P.WT_annual_add_frac; end
    cons = [cons, sum(W_T) - sum_cum_WT <= max([add_min_, add_frac_ * sum_cum_WT, W_T_lb_soft - sum_cum_WT])];
end

% Benders theta下界(必须足够低以容纳真实Q值, 否则卡死导致不收敛)
% Q*量级达-25000亿(-2.5e8万元), 故下界设-1e10万元(-100万亿)远低于任何Q
cons = [cons, theta >= -1e10];   % 物理下界(放宽以避免卡死theta)


%% ── VAIC割约束（原版格式：z离散 + G连续 + HVDC）───────────────────────
% 割形式: θ ≥ Q* + Σ w_i×dQ_i×(z_i*-z_i) + Σ dG_i×(G_i*-G_i) + dL项
for k = 1:length(cuts)
    cut = cuts{k};
    if ~isfield(cut,'Q_star'); continue; end
    if isfield(cut,'type') && strcmp(cut.type,'lp')          % 经典Benders最优性割(LP子问题对偶)
        xs = cut.x_star; g = cut.g;
        expr = cut.Q_star + g.W_T(:)'*(W_T - xs.W_T) + g.W_I(:)'*(W_I - xs.W_I) + g.G(:)'*(G - xs.G) ...
             + g.E_w(:)'*(E_w - xs.E_w) + g.E_e(:)'*(E_e - xs.E_e) + g.z(:)'*(z - xs.z) ...
             + sum(sum(g.dL .* (dL - xs.dL)));
        if ~isempty(rt) && isequal(size(rt), size(g.rt)); expr = expr + sum(sum(g.rt .* (rt - xs.rt))); end
        cons = [cons, theta >= expr];
        if isfield(cut,'L') && isfinite(cut.L); cons = [cons, theta >= cut.L]; end
        continue;
    end
    if isfield(cut,'type') && strcmp(cut.type,'wLL')
        % ── 加权Laporte–Louveaux整数割(构造性有效)──────────────────────
        % θ ≥ Q* − (Q*−L)·Σ w̃ᵢ·devᵢ,  devᵢ=zᵢ*(1−zᵢ)+(1−zᵢ*)zᵢ
        % 有效性: w̃ᵢ≥1 ⇒ z≠z*时Σw̃·dev≥1 ⇒ RHS≤L≤Q(z)✓; z=z*时=Q*✓
        dev_expr = 0;
        for i = 1:NI
            dev_expr = dev_expr + cut.w_tilde(i) * ...
                ( cut.z_star(i)*(1 - z(i)) + (1 - cut.z_star(i))*z(i) );
        end
        expr = cut.Q_star - cut.LLcoef * dev_expr;
        % 路由: 新增路由的Q改善上界U_ij(有效欠切); 拆除方向价值只降不升, 无需项
        if ~isempty(rt) && isfield(cut,'rt_star') && isfield(cut,'U_rt') ...
                && isequal(size(cut.U_rt), size(rt))
            expr = expr - sum(sum(cut.U_rt .* (1 - cut.rt_star) .* rt));
        end
        % 缺陷: 经典LL假设纯整数一阶段; 本问题z*下W_T/W_I连续可改善Q,
        %   原割在z*处θ≥Q(z*,x^k)过切更优连续配置(Y2/Y9/Y13 guard实证)
        % 修法: θ ≥ Q^k − dW·(x−x^k)₊ − LLcoef·dev
        %   (x−x^k)₊经大M+binvar精确线性化(u=max(0,Δ), 非上次的无界松弛)
        %   增侧: dW取收益密度上界斜率→欠切合法; 减侧: u=0零罚,Q升欠切合法
        if isfield(cut,'W_T_star') && isfield(cut,'dQ')
            uT = sdpvar(NI,1); bT = binvar(NI,1);
            dWT_ = W_T - cut.W_T_star(:);
            cons = [cons, uT >= 0, uT >= dWT_, ...
                    uT <= dWT_ + P.W_train_max*(1-bT), uT <= P.W_train_max*bT];
            if isfield(cut,'capT')                     % 饱和: 正部之和不超过可利用容量余量
                qT = sdpvar(NI,1); cons = [cons, qT >= 0, qT <= uT, sum(qT) <= cut.capT];
                expr = expr - cut.dQ(:)' * qT;
            else
                expr = expr - cut.dQ(:)' * uT;
            end
        end
        if isfield(cut,'W_I_star') && isfield(cut,'dW_I')
            uI = sdpvar(NJ,1); bI = binvar(NJ,1);
            dWI_ = W_I - cut.W_I_star(:);
            cons = [cons, uI >= 0, uI >= dWI_, ...
                    uI <= dWI_ + P.W_infer_max*(1-bI), uI <= P.W_infer_max*bI];
            if isfield(cut,'capI')
                qI = sdpvar(NJ,1); cons = [cons, qI >= 0, qI <= uI, sum(qI) <= cut.capI];
                expr = expr - cut.dW_I(:)' * qI;
            else
                expr = expr - cut.dW_I(:)' * uI;
            end
        end
    else
        % legacy路径(旧割结构兼容)
        expr = cut.Q_star;
        for i = 1:NI
            expr = expr + cut.w(i) * cut.dQ(i) * (cut.z_star(i) - z(i));
        end
    end
    % 连续方向引导(dG已保守化→欠切安全; dL收缩由dL≥dL_cum约束天然护栏)
    % 改为与训练/推理一致的精确正部: 只对增量给出收益上界
    if isfield(cut,'dG') && length(cut.dG) == NI && isfield(cut,'G_star')
        uG = sdpvar(NI,1); bG = binvar(NI,1); MG = 1e5;
        dGx = G - cut.G_star(:);
        cons = [cons, uG >= 0, uG >= dGx, uG <= dGx + MG*(1-bG), uG <= MG*bG];
        expr = expr - cut.dG(:)' * uG;
    end
    % HVDC方向（NI×NJ矩阵，用sum(sum(...))而非逐元素循环）
    if isfield(cut,'dL_grad') && isequal(size(cut.dL_grad), [NI, NJ]) ...
            && isfield(cut,'dL_star') && isequal(size(cut.dL_star), [NI, NJ])
        % 同理改为按西部节点聚合的正部: 斜率取该节点各通道的最大收益(只保留收益侧, 有效)
        sL_ = max(0, -min(cut.dL_grad, [], 2));
        if any(sL_ > 0)
            uL = sdpvar(NI,1); bL = binvar(NI,1); ML = 1e5;
            dLx = sum(dL,2) - sum(cut.dL_star,2);
            cons = [cons, uL >= 0, uL >= dLx, uL <= dLx + ML*(1-bL), uL <= ML*bL];
            expr = expr - sL_' * uL;
        end
    end
    cons = [cons, theta >= expr];
end


%% ── 求解 ────────────────────────────────────────────────────────────────
ops = sdpsettings('solver', P.solver, 'verbose', 0, ...
    'savesolveroutput', 1, ...
    'gurobi.MIPGap', P.gurobi_MIPGap, ...
    'gurobi.TimeLimit', P.gurobi_TimeLimit);
if isfield(P,'gurobi_threads') && P.gurobi_threads > 0; ops = sdpsettings(ops, 'gurobi.Threads', P.gurobi_threads); end

% 热启动: 上轮选址作为初值
% 保证LB在所有路径都有值（防止fallback时LB未赋值导致调用方报错）
LB = -1e8;

% ── 闭环: 资产回收闭合(创新二→投资) —— 边际学习力为负的资产, 新增投资承担回收缺口溢价 ──
%  ρ_mg来自真实运行的反事实边际(非规划模型自评), 故同时校正"规划模型高估的边际价值"
Kinc = [sum(W_T) - sum(state.W_T_cum); sum(W_I) - sum(state.W_I_cum); sum(G) - sum(state.G_cum); ...
        sum(E_w) - sum(state.E_w_cum); sum(E_e) - sum(state.E_e_cum); sum(dL(:)) - sum(dL_cum_mat(:)); 0];
if ~isempty(rt); Kinc(7) = sum(rt(:)) - sum(rtc(:)); end
if (~isfield(P,'enable_bankability') || P.enable_bankability) && isfield(P,'wm') && isstruct(P.wm) ...
        && isfield(P.wm,'rho_mg') && numel(P.wm.rho_mg) == 7
    bw_ = 0.5; if isfield(P,'bank_weight'); bw_ = P.bank_weight; end
    rm_ = P.wm.rho_mg(:); rm_(~isfinite(rm_)) = 0;
    pen_ = bw_ * max(0, -rm_) .* capex_unit_annual(P, year)';
    objective = objective + pen_' * Kinc;
end
% ── 闭环: 电力层可行性进入规划(创新一Ω_power) —— 敏感线路DC潮流软约束 ──
ov_net = [];
if (~isfield(P,'enable_net_planning') || P.enable_net_planning) && isfield(P,'net') && ~isempty(P.net)
    nl_ = numel(P.net.rate); ov_net = sdpvar(nl_, 1);
    dP_ = [P.net.cfw(:) .* G(:) - W_T(:); -W_I(:)];
    fl_ = P.net.f0(:) + P.net.H * dP_;
    cons = [cons, ov_net >= 0, fl_ <= P.net.rate(:) + ov_net, -fl_ <= P.net.rate(:) + ov_net];
    np_ = 30; if isfield(P,'net_pen'); np_ = P.net_pen; end
    objective = objective + np_ * sum(ov_net);
end

%    其UB低于任何可行方案 → LB>UB → gap被算成0, Benders立即"收敛"并锁定不可行方案) ──
if isfield(P,'proj_target') && isstruct(P.proj_target)
    xt = P.proj_target; au_ = capex_unit_annual(P, year); bigw = 1e3 * max(au_);
    qT_ = sdpvar(NI,1); qI_ = sdpvar(NJ,1); qG_ = sdpvar(NI,1); qW_ = sdpvar(NI,1); qE_ = sdpvar(NJ,1);
    cons = [cons, qT_ >= W_T - xt.W_T(:), qT_ >= xt.W_T(:) - W_T, qI_ >= W_I - xt.W_I(:), qI_ >= xt.W_I(:) - W_I, ...
                  qG_ >= G - xt.G(:), qG_ >= xt.G(:) - G, qW_ >= E_w - xt.E_w(:), qW_ >= xt.E_w(:) - E_w, ...
                  qE_ >= E_e - xt.E_e(:), qE_ >= xt.E_e(:) - E_e];
    objective = au_(1)*sum(qT_) + au_(2)*sum(qI_) + au_(3)*sum(qG_) + au_(4)*sum(qW_) + au_(5)*sum(qE_);
    if isfield(xt,'dL') && isequal(size(xt.dL), size(dL))
        qL_ = sdpvar(NI,NJ,'full'); cons = [cons, qL_ >= dL - xt.dL, qL_ >= xt.dL - dL];
        objective = objective + au_(6)*sum(qL_(:));
    end
    zt_ = double(xt.z(:) > 0.5); objective = objective + bigw * sum(z .* (1 - zt_) + zt_ .* (1 - z));
    if ~isempty(rt) && isfield(xt,'rt') && isequal(size(xt.rt), size(rt))
        objective = objective + bigw * sum(sum(rt .* (1 - xt.rt) + xt.rt .* (1 - rt)));
    end
end
% ── 近端信赖域 + 经验梯度局部模型(仅局部迭代; 局部迭代的目标值不用于全局下界) ──
% 改为: ①L1近端罚(偏离现任解按单位年金×κ计罚, 永不不可行); ②θ ≥ Q_c − g'(K − K_c),
%       g为上一年真实运行测得的反事实边际(万元/单位·年), 使局部提案沿"真实有价值"的方向
cons_tr = []; obj_tr = 0;
if isfield(P,'tr') && isstruct(P.tr) && isfield(P.tr,'on') && P.tr.on && isfield(P.tr,'x')
    xc = P.tr.x; kp_ = P.tr.kappa; au_ = capex_unit_annual(P, year);
    try
        sT_ = sdpvar(NI,1); sI_ = sdpvar(NJ,1); sG_ = sdpvar(NI,1); sW_ = sdpvar(NI,1); sE_ = sdpvar(NJ,1);
        cons_tr = [sT_ >= W_T - xc.W_T(:), sT_ >= xc.W_T(:) - W_T, sI_ >= W_I - xc.W_I(:), sI_ >= xc.W_I(:) - W_I, ...
                   sG_ >= G - xc.G(:), sG_ >= xc.G(:) - G, sW_ >= E_w - xc.E_w(:), sW_ >= xc.E_w(:) - E_w, ...
                   sE_ >= E_e - xc.E_e(:), sE_ >= xc.E_e(:) - E_e];
        obj_tr = kp_ * (au_(1)*sum(sT_) + au_(2)*sum(sI_) + au_(3)*sum(sG_) + au_(4)*sum(sW_) + au_(5)*sum(sE_));
        if isfield(xc,'dL') && isequal(size(xc.dL), size(dL))
            sL_ = sdpvar(NI,NJ,'full');
            cons_tr = [cons_tr, sL_ >= dL - xc.dL, sL_ >= xc.dL - dL];
            obj_tr = obj_tr + kp_ * au_(6) * sum(sL_(:));
        end
        if isfield(P.tr,'grad') && numel(P.tr.grad) == 7 && isfield(P.tr,'Qc') && isfinite(P.tr.Qc)
            g_ = P.tr.grad(:); g_(~isfinite(g_)) = 0;
            rtc_ = 0; if isfield(xc,'rt') && ~isempty(xc.rt); rtc_ = sum(xc.rt(:)); end
            dLc_ = 0; if isfield(xc,'dL'); dLc_ = sum(xc.dL(:)); end
            Kv_ = [sum(W_T); sum(W_I); sum(G); sum(E_w); sum(E_e); sum(dL(:)); 0];
            if ~isempty(rt); Kv_(7) = sum(rt(:)); end
            Kc_ = [sum(xc.W_T); sum(xc.W_I); sum(xc.G); sum(xc.E_w); sum(xc.E_e); dLc_; rtc_];
            cons_tr = [cons_tr, theta >= P.tr.Qc - g_' * (Kv_ - Kc_)];
        end
    catch
        cons_tr = []; obj_tr = 0;
    end
end
try
    ok_ = @(dg) dg.problem == 0 || dg.problem == 3;
    diag = optimize([cons, cons_hub, cons_tr], objective + obj_tr, ops);
    if ~ok_(diag) && ~isempty(cons_tr)
        diag = optimize([cons, cons_hub], objective, ops);                 % ①去掉信赖域(含局部模型)
    end
    if ~ok_(diag) && ~isempty(cons_hub)
        diag = optimize(cons, objective, ops);                             % ②去掉枢纽集中度
        if ok_(diag); fprintf('  [诊断] 枢纽集中度约束与其余约束冲突, 本轮已放松\n'); end
    end
    % problem=0(最优) 或 3(可能不精确但有解) 可接受; 其余(1不可行/2无界)用fallback
    if diag.problem ~= 0 && diag.problem ~= 3
        warning('主问题求解状态异常(problem=%d): %s, 使用fallback', diag.problem, diag.info);
        % ── P2诊断①: Gurobi status12歧义消解(区分真不可行/真无界) ──
        try
            ops2 = ops; ops2.gurobi.DualReductions = 0;
            diag2 = optimize(cons, objective, ops2);
            fprintf('  [诊断] DualReductions=0复解: problem=%d (%s)\n', ...
                diag2.problem, diag2.info);
        catch; end
        % ── P2诊断②: 关键约束数值预审计(定位不可行真凶) ──
        fprintf('  [审计] W_T: lb_soft=%.0f ub_soft=%.0f 锁定和=%.0f\n', ...
            W_T_lb_soft, W_T_ub_soft, sum(state.W_T_cum));
        fprintf('  [审计] W_I: target=%.0f 上界和=%.0f 锁定和=%.0f\n', ...
            W_I_target, NJ*P.W_infer_max, sum(state.W_I_cum));
        fprintf('  [审计] G锁定和=%.0f E_w锁定=%.0f E_e锁定=%.0f dL锁定=%.0f\n', ...
            sum(state.G_cum), sum(state.E_w_cum), sum(state.E_e_cum), sum(state.dL_cum(:)));
        x_sol = make_fallback_solution(state, P, cuts, W_T_lb_soft);
        return;
    end
catch ME
    warning('主问题求解失败: %s', ME.message);
    x_sol = make_fallback_solution(state, P, cuts, W_T_lb_soft);
    return;
end

%% ── 取值 ────────────────────────────────────────────────────────────────
x_sol = struct();
x_sol.z   = round(value(z));
x_sol.W_T = max(0, value(W_T));
x_sol.net_ov = 0; if ~isempty(ov_net); x_sol.net_ov = sum(max(0, value(ov_net))); end
if ~isempty(rt); x_sol.rt = round(value(rt)); else; x_sol.rt = rtc; end
x_sol.W_I = max(0, value(W_I));
x_sol.G   = max(0, value(G));
x_sol.E_w = max(0, value(E_w));
x_sol.E_e = max(0, value(E_e));
x_sol.dL  = max(0, value(dL));
x_sol.theta = value(theta);
x_sol.F1_total = value(F1);

% 原实现用F1_total - F1_cum_state，但C_infer_eff(0.65×)使F1_total<F1_cum_state → 归零
dW_T_inc = max(0, value(W_T) - state.W_T_cum(:));
dG_inc   = max(0, value(G)   - state.G_cum(:));
dEw_inc  = max(0, value(E_w) - state.E_w_cum(:));
dWI_inc  = max(0, value(W_I) - state.W_I_cum(:));
dEe_inc  = max(0, value(E_e) - state.E_e_cum(:));
dL_inc   = max(0, value(dL)  - dL_cum_mat);
x_sol.F1_incremental = ...
    P.C_train_fix * sum(dW_T_inc) ...
    + (P.C_renew_wind + P.C_renew_pv) * 1000 * sum(dG_inc) * 0.5 ...
    + P.C_stor * 1000 * sum(dEw_inc) ...
    + C_infer_eff * sum(dWI_inc) ...
    + P.C_stor * 1000 * sum(dEe_inc) ...
    + sum(sum(P.C_trans_per_node .* dL_inc));

LB = value(objective);
ob_bound = NaN;
try; ob_bound = diag.solveroutput.result.objbound; catch; end
if isfinite(ob_bound); LB = min(LB, ob_bound); end
if diag.problem ~= 0 || (isfinite(ob_bound) && abs(value(objective)-ob_bound) > 0.01*abs(ob_bound)+1)
    fprintf('    [master诊断] problem=%d t=%.1fs incumbent=%.1f objbound=%.1f\n', ...
        diag.problem, diag.solvertime, value(objective), ob_bound);
end
end


%% ── 累计投资计算辅助 ──────────────────────────────────────────────────
function F1_cum = compute_cumulative_F1(state, P)
F1_cum = P.C_train_fix * sum(state.W_T_cum) ...
       + P.C_renew_wind * 1000 * sum(state.G_cum) * 0.5 ...
       + P.C_renew_pv * 1000 * sum(state.G_cum) * 0.5 ...
       + P.C_stor * 1000 * sum(state.E_w_cum) ...
       + P.C_infer_fix * sum(state.W_I_cum) ...
       + P.C_stor * 1000 * sum(state.E_e_cum) ...
       + sum(sum(P.C_trans_per_node .* state.dL_cum));
end


%% ── 降级方案 ──────────────────────────────────────────────────────────
function x_sol = make_fallback_solution(state, P, cuts, W_T_lb_soft)
if nargin < 3; cuts = {}; end
if nargin < 4; W_T_lb_soft = 0; end
NI = P.N_west; NJ = P.N_east;
x_sol = struct();
x_sol.z = state.z_cum;
x_sol.rt = zeros(P.N_west, P.N_east);
if isfield(state,'rt_cum'); x_sol.rt = state.rt_cum; end
% fallback选址：自动选CF最高节点（与主函数逻辑一致，不硬编码）
if all(x_sol.z == 0)
    if isfield(P,'CF_wind_west') && isfield(P,'CF_pv_west')
        CF_avg = (P.CF_wind_west(:) + P.CF_pv_west(:)) / 2;
        [~, best_i] = max(CF_avg);
        x_sol.z(best_i) = 1;
    else
        x_sol.z(1) = 1;
    end
end
% W_T需求驱动(替代硬编码500): 满足训练需求下界, 按选中节点均摊增量
n_sel = max(1, sum(x_sol.z));
W_T_need_per = max(0, (W_T_lb_soft - sum(state.W_T_cum))) / n_sel;
x_sol.W_T  = max(state.W_T_cum, state.W_T_cum + W_T_need_per * x_sol.z);
x_sol.W_T  = max(x_sol.W_T, 300 * x_sol.z);   % 最小规模保底
x_sol.W_I  = max(state.W_I_cum, 1000 * ones(NJ,1));
x_sol.G    = max(state.G_cum, 1.8 * x_sol.W_T);
x_sol.E_w  = max(state.E_w_cum, P.mu_min * x_sol.G * P.dt_stor);
x_sol.E_e  = max(state.E_e_cum, 200 * ones(NJ,1));
% dL_cum_mat在子函数不可见，直接用state.dL_cum
dL_cum_fallback = state.dL_cum;
if ~isequal(size(dL_cum_fallback), [NI, NJ])
    dL_cum_fallback = zeros(NI, NJ);
end
x_sol.dL   = dL_cum_fallback;
% theta真实化(P4): 用已知割的最优Q替代-100亿占位, 使UB/gap有意义
theta_fb = -1e6;
if ~isempty(cuts)
    Qs = [];
    for kk = 1:numel(cuts)
        if isfield(cuts{kk},'Q_star'); Qs(end+1) = cuts{kk}.Q_star; end
    end
    if ~isempty(Qs); theta_fb = min(Qs); end
end
x_sol.theta = theta_fb;
x_sol.F1_total = 1e6;
x_sol.F1_incremental = 1e5;
end
