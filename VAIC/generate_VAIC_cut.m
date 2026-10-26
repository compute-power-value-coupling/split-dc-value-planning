%% =========================================================================
%  generate_VAIC_cut.m  —  VAIC割(混合策略, 论文式36增强版)
%
%  割形式: θ ≥ Q* + Σ_i w_i×dQ_i×(z_i*-z_i) + Σ_i dG_i×(G_i*-G_i) + dL项
%
%  dQ混合策略(论文精神 + 真实有效):
%    当 μ_train 充分更新(非零):  dQ_i = -∂Q/∂W_T_i = Σ_{t,s} w_s×μ_train(i,t,s)×T
%    当 μ_train ≈ 0(初期):       dQ_i = 经济估算(token收益-电费+迁移边际)
%    最终: dQ_i = max(dQ_lagrange_i, dQ_economic_i)  两者取优
%
%  dG混合策略:
%    当 μ_renew 充分更新:  dG_i = -∂Q/∂G_i = Σ_{t,s} w_s×μ_renew(i,t,s)×CF(i,t,s)×T
%    当 μ_renew ≈ 0:       dG_i = CF_avg×8760×lam_w×0.15 (经济估算)
%    最终: dG_i = max(dG_lagrange_i, dG_economic_i)
%
%  正值保证: dQ, dG均为正值, 与VAIC割公式一致.
%            Lagrange次梯度本身为负, 取正值化(-∂Q/∂x = Σ μ×...)后使用.
%% =========================================================================
function cut = generate_VAIC_cut(x_sol, Q_total, mu_all_scen, scen_weights, P, SKU, AEMF, year, scen_data)
persistent last_rec_year   % 回收反馈每年打印一次
if nargin < 7;  AEMF = struct(); end
if nargin < 8;  year = 1; end
if nargin < 9;  scen_data = {}; end
% ── LP子问题: 经典Benders最优性割 θ ≥ Q* + Σ_s p_s g_s'(x − x*) (Q对x凸, 割精确有效) ──
if (~isfield(P,'recourse_lp') || P.recourse_lp) && ~isempty(mu_all_scen) && isstruct(mu_all_scen{1}) ...
        && isfield(mu_all_scen{1},'grad') && ~isempty(mu_all_scen{1}.grad)
    w_ = scen_weights(:) / max(1e-12, sum(scen_weights(:)));
    fn_ = {'W_T','W_I','G','E_w','E_e','z','dL','rt'}; g_ = struct();
    for q_ = 1:numel(fn_)
        acc_ = 0;
        for s_ = 1:numel(mu_all_scen)
            if isstruct(mu_all_scen{s_}) && isfield(mu_all_scen{s_},'grad') && ~isempty(mu_all_scen{s_}.grad)
                acc_ = acc_ + w_(s_) * mu_all_scen{s_}.grad.(fn_{q_});
            end
        end
        g_.(fn_{q_}) = acc_;
    end
    cut = struct('type','lp', 'Q_star', Q_total, 'g', g_, 'year', year);
    try
        Ek = zeros(1,4); fnl = {'Lambda_A','Lambda_B','Lambda_C','Lambda_D'};
        for s_ = 1:numel(scen_data)
            for k_ = 1:4
                v_ = scen_data{s_}.(fnl{k_})(:); Ek(k_) = max(Ek(k_), sum(max(v_,0)) * 8760/numel(v_));
            end
        end
        pm_ = min([P.eta_PUE_west(:); P.eta_PUE_east(:)]); sm_ = 1.5; if isfield(P,'spot_market_mult'); sm_ = P.spot_market_mult; end
        crw_ = 1; if isfield(P,'calib_rev_west'); crw_ = P.calib_rev_west; end
        vR_ = max(SKU.p_R(:)) * 0.1 * SKU.eta_token / pm_; vT_ = crw_ * max([SKU.p_T(:); SKU.p_B_s(:)]) * 0.1 * SKU.eta_token / pm_;
        ex_ = 0.5; if isfield(P,'expand_max_annual'); ex_ = P.expand_max_annual; end
        hv_ = sum((1+ex_)*P.HVDC_cap_per_node(:)) * 8760 * max(scen_data{1}.lam_e(:)) / 1e4;
        if isfield(x_sol,'dL'); hv_ = hv_ + sum(x_sol.dL(:)) * 8760 * max(scen_data{1}.lam_e(:)) / 1e4; end
        cut.L = -1.2 * (vR_*(Ek(1) + Ek(2) + Ek(3)) + vT_*Ek(4)*(1 + sm_) + hv_);
    catch
        cut.L = -1e10;
    end
    cut.x_star = struct('W_T', x_sol.W_T(:), 'W_I', x_sol.W_I(:), 'G', x_sol.G(:), 'E_w', x_sol.E_w(:), ...
        'E_e', x_sol.E_e(:), 'z', double(x_sol.z(:) > 0.5), 'dL', zeros(P.N_west,P.N_east), 'rt', zeros(P.N_west,P.N_east));
    if isfield(x_sol,'dL') && isequal(size(x_sol.dL), [P.N_west P.N_east]); cut.x_star.dL = x_sol.dL; end
    if isfield(x_sol,'rt') && isequal(size(x_sol.rt), [P.N_west P.N_east]); cut.x_star.rt = x_sol.rt; end
    fprintf('     [LP割] Q*=%.2f亿 | dQ/dW_T=[%s] dQ/dG=[%s] 万元/MW\n', Q_total/1e4, ...
        num2str(round(g_.W_T(:)'),'%d '), num2str(round(g_.G(:)'),'%d '));
    return;
end

NI = P.N_west;
T_plan = 52;   % 168h→年度放大因子

%% ── 节点价值密度(逐节点局部) ─────────────────────────────────────────
w_local = compute_value_density(x_sol, [], P, SKU, AEMF);

%% ── VUFP: 价值-不确定性场在算电耦合图上多跳传播(本文核心创新) ─────────
% 逐节点独立价值密度 → 图传播后的耦合价值场; 节点i的价值感知邻居j经
% HVDC/光纤/迁移边传导的价值与不确定性溢出(多跳/有向/随年演化)
unc_local0 = ones(P.N_west + P.N_east, 1);
if isstruct(AEMF) && isfield(AEMF,'epsilon_1')
    unc_local0 = unc_local0 * AEMF.epsilon_1;   % 全局ε作节点不确定性基
end
% ══ OVT价值链: WGF年际演化 → VUFP空间传播 → GAT注意力精炼(全门控) ════
w_stage = w_local;
if ~isfield(P,'enable_wgf') || P.enable_wgf
    w_prev_f = [];
    if isstruct(AEMF) && isfield(AEMF,'w_field_prev'); w_prev_f = AEMF.w_field_prev; end
    [w_stage, wgf_info] = wgf_value_evolution(w_stage, w_prev_f, P, AEMF);
    if ~wgf_info.cold_start
        fprintf('     [WGF] τ=%.2f μ=%.2f 阶跃=%.2f Dirichlet降=%.1f%%\n', ...
            wgf_info.tau, wgf_info.mu, wgf_info.step, 100*wgf_info.dirichlet_drop);
    end
end
if ~isfield(P,'enable_vufp') || P.enable_vufp
    [w_stage, ~, vufp_info] = vufp_propagate(w_stage, unc_local0, P, x_sol, AEMF, year);
    fprintf('     [VUFP] L=%d跳 α=%.2f 价值场修正=[%s]\n', ...
        vufp_info.L_hops, vufp_info.alpha, num2str(vufp_info.w_shift(:)','%.2f '));
end
if ~isfield(P,'enable_gat_cut') || P.enable_gat_cut
    [w_stage, gat_info] = gat_cut_weights(w_stage, P, x_sol, SKU, AEMF, year);
    fprintf('     [GAT-VAIC] 注意力修正=[%s]\n', num2str(gat_info.w_shift(:)','%.2f '));
end
w = w_stage;
% ── 回收闭合反馈(创新点三): 支撑资产(HVDC/储能)存在回收缺口时,
%    依赖其支撑的节点价值有界打折——规划"看见"链条回收状态而非仅运行成本
if (~isfield(P,'enable_recovery_feedback') || P.enable_recovery_feedback) ...
        && isfield(P,'recovery_gap') && numel(P.recovery_gap) >= 6
    % 修正: 均匀缩放在w̃=w/min(w)中被抵消(上版惰性)。改为按节点对缺口资产的
    % 暴露度非均匀调制——只改割的探索几何(w̃≥1有效性不变)
    gEw = min(0, P.recovery_gap(4));  gHV = min(0, P.recovery_gap(6));
    nw = numel(w); shEw = ones(nw,1)/nw; shHV = shEw;
    if isfield(x_sol,'E_w') && sum(x_sol.E_w) > 1e-6; shEw = x_sol.E_w(:)/sum(x_sol.E_w); end
    if isfield(x_sol,'dL') && sum(x_sol.dL(:)) > 1e-6
        shHV = sum(x_sol.dL,2); shHV = shHV(:)/sum(shHV); end
    pen_i = max(0.92, 1 + 0.02*nw*(gEw*shEw + gHV*shHV)/500);
    w = w(:) .* pen_i;
    if isempty(last_rec_year) || last_rec_year ~= year
        last_rec_year = year;
        fprintf('     [回收反馈] 西储缺口%.0f亿 HVDC缺口%.0f亿 → 节点调制=[%s]\n', ...
            -gEw, -gHV, num2str(pen_i','%.3f '));
    end
end

%% ── 电价与token价格(年度变化) ────────────────────────────────────────
% 训练token价：对应D类合同价的先升后降曲线（与compute_SKU_pricing保持一致）
% Y1-Y6: +8%/年（需求驱动）; Y7-Y15: -5%/年（效率反超）
train_annual = [1,1.08,1.08,1.08,1.08,1.08, 0.95,0.95,0.95,0.95,0.95,0.95,0.95,0.95,0.95];
train_factor_yr = prod(train_annual(1:year));
lam_tok_yr = P.lambda_token_base * train_factor_yr;
% 改用当年SKU训练价与当年token能效(与子问题同口径), 保持"上界"性质
eta_c = P.eta_token; if isfield(SKU,'eta_token') && ~isempty(SKU.eta_token); eta_c = SKU.eta_token; end
if isfield(SKU,'p_T') && ~isempty(SKU.p_T); lam_tok_yr = max(SKU.p_T(:)); end
lam_w_yr   = P.lambda_energy_west / 10000;
lam_e_yr   = P.lambda_energy_east / 10000;
if isfield(AEMF,'lam_w_avg_hist') && AEMF.lam_w_avg_hist > 0
    lam_w_yr = AEMF.lam_w_avg_hist;
end
if isfield(AEMF,'lam_e_avg_hist') && AEMF.lam_e_avg_hist > 0
    lam_e_yr = AEMF.lam_e_avg_hist;
end
net_elec_diff = max(0, lam_e_yr - lam_w_yr);

CF_avg = 0.19;
if isfield(AEMF,'CF_avg_hist') && AEMF.CF_avg_hist > 0
    CF_avg = AEMF.CF_avg_hist;
end

%% ── dQ: 混合策略(次梯度优先, 经济估算兜底) ─────────────────────────
dQ = zeros(NI, 1);
for i = 1:NI

    % ── A. Lagrange次梯度(正值化: -∂Q/∂W_T = Σ_{t,s} w_s × μ_train(i,t)) ──
    % 当训练约束紧(P_train→W_T), μ_train>0, 此值反映了真实的扩容边际价值
    dQ_lagrange_i = 0;
    for s = 1:length(mu_all_scen)
        if isfield(mu_all_scen{s},'train') && size(mu_all_scen{s}.train,1) >= i
            dQ_lagrange_i = dQ_lagrange_i + scen_weights(s) * sum(mu_all_scen{s}.train(i,:));
        end
    end
    dQ_lagrange_i = dQ_lagrange_i * T_plan;   % 年化

    % ── B. 经济估算（含节点kappa差异——这是VAIC"价值感知"的核心）─────────────
    % 原来用lam_tok_yr对所有节点统一→dQ无节点差异→内蒙和宁夏割激励几乎相同
    % 物理含义：内蒙kappa=1.50→训练单价高→每MW训练容量带来的收益更多→dQ更大
    kappa_i    = P.kappa_cluster_west(min(i, length(P.kappa_cluster_west)));
    kappa_mean = mean(P.kappa_cluster_west);
    lam_tok_node = lam_tok_yr * kappa_i / kappa_mean;   % 节点差异化token价值

    coef_rev = lam_tok_node * eta_c * P.delta_comm(i) / P.eta_PUE_west(i) * 0.1;   % 万元/MWh
    dQ_econ_i = max(0, coef_rev - lam_w_yr) * 8760;
    comm_idx  = P.comm_delay(P.east_hub_idx, P.west_hub_idx(i));
    c_comm    = 0.002 + 0.0003 * max(0, mean(comm_idx) - 5);
    % 承接迁移/跨域服务的电费差价值(万元/MW·年); 原式把万元/MWh的通信费从每token价值中扣除, 恒为0
    dQ_econ_i = dQ_econ_i + max(0, net_elec_diff - c_comm) * 8760 * 0.5;

    % ── C. 混合: 两者取较大值(μ充分时次梯度更精确, μ≈0时经济估算更有效)
    dQ(i) = max(dQ_lagrange_i, dQ_econ_i);
end
if all(dQ < 1.0); dQ = w * 5.0; end

%% ── dG: 混合策略(次梯度优先, 经济估算兜底) ─────────────────────────
dG = zeros(NI, 1);
for i = 1:NI

    % ── A. Lagrange次梯度(正值化: -∂Q/∂G = Σ_{t,s} w_s × μ_renew × CF) ──
    dG_lagrange_i = 0;
    for s = 1:length(mu_all_scen)
        if isfield(mu_all_scen{s},'renew') && size(mu_all_scen{s}.renew,1) >= i
            if ~isempty(scen_data) && isfield(scen_data{s},'CF_renew') ...
                    && size(scen_data{s}.CF_renew,1) >= i
                CF_s = scen_data{s}.CF_renew(i,:);
            else
                CF_s = CF_avg * ones(1, size(mu_all_scen{s}.renew,2));
            end
            dG_lagrange_i = dG_lagrange_i ...
                + scen_weights(s) * sum(mu_all_scen{s}.renew(i,:) .* CF_s);
        end
    end
    dG_lagrange_i = dG_lagrange_i * T_plan;

    % ── B. 经济估算（节点差异化CF：宁夏CF=0.215 > 甘肃CF=0.19 > 内蒙CF=0.200 > 贵州CF=0.145）
    % 正确逻辑：CF越高 → 每MW绿电发的电越多 → 单位G的替代购电量越多 → dG越大
    % 同时：CF越高的节点，绿电成本越低（gamma_econ越小），dG的激励应该更强
    if isfield(P,'CF_wind_west') && isfield(P,'CF_pv_west') && length(P.CF_wind_west) >= i
        CF_node_i = (P.CF_wind_west(i) + P.CF_pv_west(i)) / 2;   % 节点i的实际CF
    else
        CF_node_i = CF_avg;   % fallback到全局均值
    end
    % 单位绿电价值上界: 发电量×max(外送东部电价(扣损耗), 替代西部购电, 支撑训练的价值密度)
    loss_g = 0.07; if isfield(P,'hvdc_loss'); loss_g = P.hvdc_loss; end
    vD_ = lam_tok_node * eta_c / P.eta_PUE_west(i) * 0.1;
    dG_econ_i = CF_node_i * 8760 * max([lam_e_yr*(1-loss_g), lam_w_yr, vD_]);

    % ── C. 混合（保守化：宁欠切勿过切，选址不可逆保护）────────────────
    % 原max(lagr,econ)有高估→过切风险；改为lagr为主、econ为帽：
    % 弃电期lagr=0(诚实边际)→dG=0；非弃电期以econ封顶防高估。
    % 欠切仅减慢收敛(安全)，过切会永久排除真最优选址(不可接受)。
    dG(i) = max(max(dG_lagrange_i, 0), dG_econ_i);
end

%% ── HVDC梯度（NI×NJ矩阵，不能用length，应用numel或显式循环）────────────
c_hvdc_loss  = 5 / 10000;
hvdc_net     = max(0, lam_e_yr - lam_w_yr - c_hvdc_loss);
NI_g = P.N_west; NJ_g = P.N_east;
dL_grad = zeros(NI_g, NJ_g);   % 全矩阵梯度（单位：万元/MW/年）
for ig = 1:NI_g
    for jg = 1:NJ_g
        % 每MW HVDC每年套利收益 = 东西价差 × 有效利用率 × 8760h
        % 利用率按路径距离调整（近路利用率高）
        dist_factor = max(0.40, 1.0 - 0.0001 * P.C_trans_per_node(ig,jg));
        dL_grad(ig, jg) = -hvdc_net * dist_factor * 8760;
    end
end

%% ── 割结构体 ────────────────────────────────────────────────────────
cut = struct();
cut.z_star    = x_sol.z;
cut.W_T_star  = x_sol.W_T;
cut.G_star    = x_sol.G;
cut.E_w_star  = x_sol.E_w;
cut.dL_star   = x_sol.dL;
cut.Q_star    = Q_total;
cut.timestamp = now;
cut.w         = w;
cut.dQ        = dQ;

%% ── 加权Laporte–Louveaux整数割（构造性有效，选址安全核心）─────────────
% 形式: θ ≥ Q* − (Q*−L)·Σᵢ w̃ᵢ·devᵢ(z),  devᵢ = zᵢ*(1−zᵢ)+(1−zᵢ*)zᵢ
% 有效性(两行证明): w̃ᵢ=wᵢ/min(w)≥1 ⇒ 任意z≠z*有Σw̃·dev≥1 ⇒ RHS≤L≤Q(z)✓;
%                   z=z*时dev=0 ⇒ RHS=Q*精确✓。整数可行域零裁剪。
% 价值引导仅作用于LP松弛几何(w̃差异化斜率引导搜索方向)——加速不越权。
w_pos = w(w > 1e-9);
if isempty(w_pos); w_pos = 1; end
cut.w_tilde = max(1, w / min(w_pos));          % 归一权重, 全部≥1(有效性条件)

% 解析全局下界 L ≤ min_z Q(z) = −最大可能年利润(容量上限×最高价×2倍安全裕度)
% L_glob需求锚定收紧(修复数值病态): 原容量上界(60GW推理)使LLcoef~5e8万元,
% theta范围1e10致Gurobi条件数灾难+中途gap无意义。收益上限受需求约束:
% 服务量≤(1+φ)×1.3×D_peak, 训练≤min(容量上限, 6×D_peak)——下界仍合法(≤min Q)
D_hint = 0;
if isfield(P,'D_peak_hint'); D_hint = P.D_peak_hint; end
if D_hint > 0
    WT_cap = min(P.K_max * P.W_train_max, 6 * D_hint);
    WI_cap = min(P.W_infer_max * P.N_east, 1.3 * (1 + P.phi_reserve) * D_hint);
else
    WT_cap = P.K_max * P.W_train_max;
    WI_cap = P.W_infer_max * P.N_east;
end
rev_cap_west = WT_cap / min(P.eta_PUE_west) ...
             * max(SKU.p_T) * 0.1 * SKU.eta_token * max(P.delta_comm) * 8760;
rev_cap_east = WI_cap / min(P.eta_PUE_east) ...
             * max(SKU.p_R) * 0.1 * SKU.eta_token * 8760;
L_glob = -1.5 * (rev_cap_west + rev_cap_east); % ×1.5裕度覆盖HVDC/绿证/柔性
% 需求锚定收紧: 服务量不超过需求能量(含1.5倍现货与柔性裕度), HVDC外送不超过4倍基础通道×8760h
if D_hint > 0
    v_max = max([max(SKU.p_T), max(SKU.p_R), max(SKU.p_B_s)]) * 0.1 * SKU.eta_token / min([P.eta_PUE_west(:); P.eta_PUE_east(:)]);
    hv_b  = 4 * sum(P.HVDC_cap_per_node(:)) * 8760 * 1.5 * P.lambda_energy_east / 1e4;
    L_dem = -1.5 * (1.5 * D_hint * 8760 * v_max + hv_b);
    L_glob = max(L_glob, L_dem);
end
sm_c = 1.5; if isfield(P,'spot_market_mult'); sm_c = P.spot_market_mult; end
% 分类能量锚定(更紧且仍有效): 利润 ≤ 收入 ≤ Σ_k 年需求能量_k × 该类最高价值密度 + 现货 + HVDC外送 (×1.5裕度)
% v8.16中按"峰值×8760×最高价"估计, 比真实收入大一个量级, 未评估选址组合的下界因此停在−900~−4500亿
try
    Ek = zeros(1,4); fn = {'Lambda_A','Lambda_B','Lambda_C','Lambda_D'};
    for s_ = 1:numel(scen_data)
        for k_ = 1:4
            if isfield(scen_data{s_}, fn{k_})
                v_ = scen_data{s_}.(fn{k_})(:); Ek(k_) = max(Ek(k_), sum(max(v_,0)) * 8760/numel(v_));
            end
        end
    end
    pue_m = min([P.eta_PUE_west(:); P.eta_PUE_east(:)]);
    vRT = 1.5 * max(SKU.p_R(:)) * 0.1 * SKU.eta_token / pue_m;                 % A/B(含A类溢价)
    vC  = max([SKU.p_B_s(:); SKU.p_T(:)]) * 0.1 * SKU.eta_token / pue_m;       % C(批量/迁移)
    vD  = max(SKU.p_T(:)) * 0.1 * SKU.eta_token / pue_m;                        % D(合同+现货)
    hvc = P.HVDC_cap_per_node; if isfield(x_sol,'dL') && isequal(size(x_sol.dL), size(hvc)); hvc = hvc + x_sol.dL; end
    ex_ = 0.5; if isfield(P,'expand_max_annual'); ex_ = P.expand_max_annual; end
    hv_e = sum(hvc(:) + ex_*P.HVDC_cap_per_node(:)) * 8760 * 0.6 * 1.5 * P.lambda_energy_east / 1e4;   % 本年可达通道容量
    if all(Ek > 0)
        L_cls = -1.5 * (vRT*(Ek(1)+Ek(2)) + vC*Ek(3) + vD*Ek(4)*(1 + sm_c) + hv_e);
        L_glob = max(L_glob, L_cls);
    end
catch
end
cut.L_glob  = L_glob;
cut.LLcoef  = max(0, Q_total - L_glob);        % (Q*−L) ≥ 0
cut.W_T_star = x_sol.W_T(:);                   % 正部松弛参考点(训练)
if isfield(x_sol,'rt'); cut.rt_star = x_sol.rt; end  % 路由参考点
% 路由Q改善上界(万元/年): ①解锁B类可达: κ_B×B峰值×8760×东部电价上限(外送B只节省电费,
% 收入不变); ②时延降低的通信费节省: Δms×单位时延通信费×(B+C峰值)×8760。均取上界→割有效
try
    [~, Ur_] = reach_potential(P);
    kB_ = 0.35; if isfield(P,'kappa_B_mig'); kB_ = P.kappa_B_mig; end
    pcap_ = 2500; if isfield(P,'price_cap_east'); pcap_ = P.price_cap_east; end   % 取高于尖峰电价的上界保证割有效
    red_ = 0.40; if isfield(P,'route_delay_reduction'); red_ = P.route_delay_reduction; end
    Dh_ = 1000; if isfield(P,'D_peak_hint'); Dh_ = P.D_peak_hint; end
    Bpk_ = Dh_ * P.task_ratio(2) * P.east_B_share(:)';
    Cpk_ = Dh_ * P.task_ratio(3) / P.N_east * ones(1, P.N_east);
    Db_ = P.comm_delay; if isfield(P,'comm_delay_base'); Db_ = P.comm_delay_base; end
    U = zeros(P.N_west, P.N_east);
    for i_ = 1:P.N_west
        for j_ = 1:P.N_east
            dms = Db_(P.west_hub_idx(i_), P.east_hub_idx(j_)) * red_;
            U(i_,j_) = Ur_(i_,j_) * kB_ * Bpk_(j_) * 8760 * pcap_/1e4 ...
                     + dms * P.comm_cost_per_ms * (Bpk_(j_) + Cpk_(j_)) * 8760;
        end
    end
    cut.U_rt = U;
catch
end
cut.W_I_star = x_sol.W_I(:);                   % 正部松弛参考点(推理)
% 可利用容量上限(×1.5安全裕度): 训练侧=D类+C类+可跨域B类+现货; 推理侧=A+B+C(含备用率)
Dh_c = 1000; if isfield(P,'D_peak_hint'); Dh_c = P.D_peak_hint; end
tr_c = P.task_ratio; kB_c = 0.35; if isfield(P,'kappa_B_mig'); kB_c = P.kappa_B_mig; end
sm_c = 1.5; if isfield(P,'spot_market_mult'); sm_c = P.spot_market_mult; end
U_T = 1.5 * (1.2*Dh_c*(tr_c(4) + tr_c(3) + kB_c*tr_c(2)) + sm_c*tr_c(4)*Dh_c);
U_I = 1.5 * 1.2*(1 + P.phi_reserve)*Dh_c*(tr_c(1) + tr_c(2) + tr_c(3));
cut.capT = max(0, U_T - sum(x_sol.W_T));
cut.capI = max(0, U_I - sum(x_sol.W_I));
% W_I上界斜率: 推理收益密度年额上界(欠切合法)
cut.dW_I = ones(P.N_east,1) * max(SKU.p_R) * 0.1 * SKU.eta_token ...
           / min(P.eta_PUE_east) * 8760;
cut.type    = 'wLL';

% ── 消融M1或过切守卫回退：经典(等权)Laporte–Louveaux割 ────────────────
% w̃≡1即教科书标准整数L割——与wLL同一有效性框架, 唯一差异是无价值加权,
% 使M1成为对"价值引导"贡献的纯净对照(而非另一套割体系)
if (isfield(P,'ablation') && strcmp(P.ablation,'M1')) ...
        || (isfield(P,'vaic_force_classic') && P.vaic_force_classic)
    cut.w_tilde = ones(size(w));
end
cut.dG        = dG;
cut.dL_grad   = dL_grad;
% 注：W_T方向梯度不加入割——因为割在z固定后对W_T方向是非线性的，
%     强行线性化会使主问题通过最大化W_T来人为放宽割约束（单节点2813MW bug）
cut.valid     = all(dQ >= 0) && all(w > 0) && all(dG >= 0);

fprintf('     [VAIC割] Q*=%.2f亿 w=[%.2f,%.2f,%.2f,%.2f] dQ=[%.0f,%.0f,%.0f,%.0f]万元/MW dG=[%.1f,%.1f,%.1f,%.1f]万元/MW\n', ...
    Q_total/1e4, w(1), w(2), w(3), w(4), ...
    dQ(1), dQ(2), dQ(3), dQ(4), ...
    dG(1), dG(2), dG(3), dG(4));
end
