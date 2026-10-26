%% =========================================================================
%  simulate_actual_operation.m  —  该年实际运行模拟(8760h)
%  
%  在Benders锁定本年容量x_locked后, 模拟该年8760小时的实际运行情况
%  生成: 风光CF时序、电价时序、三模式切换、储能SOC、积压队列、SLA违约
%  
%  实际数据 = 从代表性情景中按权重抽样 + 小扰动
%% =========================================================================
function actual = simulate_actual_operation(state, AEMF, P, demand_y, year, SKU_in)

NI = P.N_west; NJ = P.N_east;
N_hour = P.N_hour_year;   % 8760
scenarios = AEMF.scenarios;
N_s = scenarios.N_scen;

%% ── 1. 从情景中抽样生成8760h的风光与电价 ──────────────────────────────
rng(2024 + year);   % 该年随机种子

% 每168h周抽样一次, 共52周构成8760h
N_week = ceil(N_hour / 168);
sampled_scen = zeros(N_week, 1);

cum_p = cumsum(scenarios.pi_s);
for w = 1:N_week
    r = rand();
    sampled_scen(w) = find(cum_p >= r, 1);
end

% 拼接8760h时序
actual.cf_wind = zeros(N_hour, NI);
actual.cf_pv = zeros(N_hour, NI);
actual.price = zeros(N_hour, NI + NJ);

for w = 1:N_week
    s = sampled_scen(w);
    h_start = (w-1)*168 + 1;
    h_end = min(w*168, N_hour);
    T_eff = h_end - h_start + 1;
    
    % 风光
    cf_w_s = squeeze(scenarios.cf_wind(s,:,1:T_eff));
    cf_p_s = squeeze(scenarios.cf_pv(s,:,1:T_eff));
    if size(cf_w_s, 1) ~= NI; cf_w_s = cf_w_s'; end
    if size(cf_p_s, 1) ~= NI; cf_p_s = cf_p_s'; end
    
    actual.cf_wind(h_start:h_end, :) = cf_w_s';
    actual.cf_pv(h_start:h_end, :) = cf_p_s';
    
    % 电价(西+东)
    pw_s = squeeze(scenarios.price_west(s,:,1:T_eff));
    pe_s = squeeze(scenarios.price_east(s,:,1:T_eff));
    if size(pw_s, 1) ~= NI; pw_s = pw_s'; end
    if size(pe_s, 1) ~= NJ; pe_s = pe_s'; end
    
    actual.price(h_start:h_end, 1:NI) = pw_s';
    actual.price(h_start:h_end, NI+1:end) = pe_s';
end

% 小扰动(均值0, 5%标准差)
actual.cf_wind = max(0, min(0.85, actual.cf_wind .* (1 + 0.05*randn(size(actual.cf_wind)))));
actual.cf_pv   = max(0, min(0.90, actual.cf_pv   .* (1 + 0.05*randn(size(actual.cf_pv)))));
actual.price   = max(50, min(3000, actual.price .* (1 + 0.05*randn(size(actual.price)))));

%% ── 2. 三模式切换 + 储能逐小时模拟 ─────────────────────────────────────
actual.P_train = zeros(N_hour, NI);
actual.P_renew = zeros(N_hour, NI);
actual.P_curt = zeros(N_hour, NI);
actual.P_grid = zeros(N_hour, NI);
actual.P_ch = zeros(N_hour, NI);
actual.P_dis = zeros(N_hour, NI);
actual.T_gen = zeros(N_hour, NI);
actual.SOC = zeros(N_hour, NI+NJ);   % 西+东储能SOC
actual.mode = zeros(N_hour, NI);     % 1/2/3
actual.arbitrage_signal = zeros(N_hour, NI);

% ── 定价源统一：优先SKU穿透(年度演化+节点差异)，兜底旧本地公式 ────────
if nargin >= 6 && ~isempty(SKU_in) && isfield(SKU_in,'p_T')
    p_T_per_node = SKU_in.p_T(:)';            % 元/千tokens(本年)
    p_R_per_node = SKU_in.p_R(:)';
    p_B_s_eff    = SKU_in.p_B_s(1);
    eta_tok_eff  = SKU_in.eta_token;          % Huang年度演化
else
    p_T_per_node = P.lambda_compute_base * (1 + P.pi_service_T) * 0.04 ...
                  * [1.575, 1.30, 1.434, 1.045];
    p_R_per_node = P.lambda_compute_base * (1+P.pi_service_R) * 0.05 * [1.15, 1.20, 1.18];
    p_B_s_eff    = P.lambda_compute_base * (1+P.pi_service_B) * 0.035;
    eta_tok_eff  = P.eta_token;
end
P.eta_token = eta_tok_eff;   % η口径统一(实际层): 下游全部token↔MW换算使用η_y
spot_disc = 0.65;
if isfield(P,'spot_token_discount'); spot_disc = P.spot_token_discount; end
actual.rev_west_tiered = 0;   % 分层(合同+现货)西部收益累计(万元)

for i = 1:NI
    if state.W_T_cum(i) < 1; continue; end
    eta_i = P.eta_PUE_west(i);
    del_i = P.delta_comm(i);
    Wi    = state.W_T_cum(i);
    Gi    = state.G_cum(i);
    Ei    = state.E_w_cum(i);
    Pc_min = P.W_contract_D(i) / eta_i;
    
    actual.SOC(1, i) = 0.5 * Ei;
    
    for h = 1:N_hour
        cf_h = (actual.cf_wind(h,i) + actual.cf_pv(h,i)) / 2;
        Pr_avail = Gi * cf_h;
        SOC_h = actual.SOC(h, i);
        lam_w_h = actual.price(h, i);
        % ── 时级套利信号(修复降载=0%根因)────────────────────────────
        % 原bug：lambda_token_base固定+×0.1系数→coef_rev≈13000元/MWh虚高10倍，
        % 尖峰电价1400元永远打不过→模式3永不触发。修复后coef_rev≈1292元/MWh，
        % 3-5倍尖峰(1050-1750元)可越过→降载/VPP削峰自然出现
        lam_tok_wan_h = p_T_per_node(i) * 0.1 * (0.9 + 0.2*rand());
        coef_rev = lam_tok_wan_h * eta_tok_eff * del_i / eta_i;
        coef_elec = lam_w_h / 10000;
        pi_h = coef_rev - coef_elec;
        actual.arbitrage_signal(h, i) = pi_h;
        
        % 三模式决策(与子问题subproblem_DACS_west一致: 弃电触发放宽到0.5×Pc_min)
        if pi_h > 0 && Pr_avail >= 0.5 * Pc_min
            % 弃电模式: 优先消纳绿电, 多余先充储能再弃电
            Pt = max(Pc_min, min(Wi, Pr_avail));
            Pr = min(Pr_avail, Pt);
            Pg = max(0, Pt - Pr);
            Pc = max(0, Pr_avail - Pr);
            P_dis_h = 0;
            P_ch_h = 0;
            if Pc > 0.1 && SOC_h < P.SOC_max_ratio*Ei
                P_ch_h = min(Pc, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_h));
                Pc = Pc - P_ch_h;
            end
            mode_h = 1;
        elseif pi_h > 0 && Pr_avail < 0.5 * Pc_min
            % 购电模式: 绿电严重不足
            Pt = min(Wi, max(Pc_min, Pr_avail*1.3));
            Pr = Pr_avail;
            Pg = max(0, Pt - Pr);
            Pc = 0;
            P_dis_h = 0;
            P_ch_h = max(0, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_h));
            mode_h = 2;
        else
            % 降载模式
            Pt = Pc_min;
            Pr = min(Pr_avail, Pt);
            Pg = max(0, Pt - Pr);
            Pc = 0;
            P_dis_h = 0;
            P_ch_h = max(0, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_h));
            mode_h = 3;
        end
        
        % 储能更新
        SOC_next = SOC_h * (1-P.sigma_stor) + P.eta_ch*P_ch_h - P_dis_h/P.eta_dis;
        if h < N_hour
            actual.SOC(h+1, i) = max(P.SOC_min_ratio*Ei, min(P.SOC_max_ratio*Ei, SOC_next));
        end
        
        Tg_h = eta_tok_eff * (Pt/eta_i) * del_i;   % 百万tokens/h(年度效率)
        % 分层收益：合同部分全价，绿电富裕驱动的超合同部分按现货折扣
        % 修正: 合同价覆盖本节点承担的D类需求(原封顶于固定最低合同容量Pc_min, 15年不变,
        %       使实际训练收入从Y7起停滞, 规划/实际西部利润差距逐年扩大到2.4倍)
        shT_i = state.W_T_cum(i) / max(1e-9, sum(state.W_T_cum(:)));
        D_node_h = demand_y(4, mod(h-1, size(demand_y,2)) + 1) * shT_i;
        Tg_c = eta_tok_eff * (min(Pt, max(D_node_h, Pc_min))/eta_i) * del_i;
        spot_cap_a = inf;
        if nargin>=6 && ~isempty(SKU_in) && isfield(SKU_in,'spot_cap_tok_h')
            spot_cap_a = SKU_in.spot_cap_tok_h;
        end
        Tg_s_sold = min(Tg_h - Tg_c, spot_cap_a);   % 现货吸纳封顶
        actual.rev_west_tiered = actual.rev_west_tiered ...
            + p_T_per_node(i)*0.1 * (Tg_c + spot_disc*Tg_s_sold);
        
        actual.P_train(h,i) = Pt;
        actual.P_renew(h,i) = Pr;
        actual.P_curt(h,i) = Pc;
        actual.P_grid(h,i) = Pg;
        actual.P_ch(h,i) = P_ch_h;
        actual.P_dis(h,i) = P_dis_h;
        actual.T_gen(h,i) = Tg_h;
        actual.mode(h,i) = mode_h;
    end
end

%% ── 3. 模式频率统计 ───────────────────────────────────────────────────
mode_counts = zeros(3, 1);
for m = 1:3
    mode_counts(m) = sum(actual.mode(:) == m);
end
total_mode = sum(actual.mode(:) > 0);
if total_mode > 0
    actual.mode_freq = (mode_counts / total_mode)';
else
    actual.mode_freq = [0.33, 0.33, 0.34];
end

%% ── 4. 弃电消纳率(真实物理定义: 消纳绿电/可发绿电) ─────────────────────
% 消纳率 = 实际消纳的绿电 / 可发的绿电总量(G×CF全量)
% 可发绿电 = 各节点装机×逐时CF的全量积分
total_renew_avail = 0;
for i = 1:NI
    cf_i = (actual.cf_wind(:,i) + actual.cf_pv(:,i)) / 2;
    total_renew_avail = total_renew_avail + sum(state.G_cum(i) * cf_i);
end
total_consumed = sum(actual.P_renew(:));     % 实际消纳
total_curt = sum(actual.P_curt(:));           % 弃电量
if total_renew_avail > 1
    % 消纳率 = 消纳/可发 (= 1 - 弃电率), 真实物理值, 不再恒为1
    actual.curtail_rate = total_consumed / total_renew_avail;
    actual.curtail_rate = max(0, min(1, actual.curtail_rate));
else
    actual.curtail_rate = 0;
end
actual.curt_total = total_curt;
actual.renew_avail_total = total_renew_avail;

%% ── 5. 东部积压队列模拟(简化) ─────────────────────────────────────────
actual.B_B = zeros(N_hour, NJ);
actual.B_C = zeros(N_hour, NJ);
actual.S_B = zeros(N_hour, NJ);
actual.S_C = zeros(N_hour, NJ);
actual.dP_flex = zeros(N_hour, NJ);
actual.vpp_hourly = zeros(N_hour, 1);  % 逐时VPP削峰(初始化必须先于278行使用)
actual.SLA_viol_count = 0;
actual.sla_B_viol_rate = 0;

% 简化: 用168h典型周展开
% 创新一: B类跨域服务台账(先于C类迁移占用西部空闲容量——B类SLA价值更高)
actual.P_Boff = zeros(N_hour, NI);    % 西部承接B类的设施功率(MW)
actual.B_off  = zeros(N_hour, NJ);    % 东部各节点外送B类token(百万)
actual.Boff_OD = zeros(NJ, NI);       % B类跨域OD(东j→西i, 百万token)
rev_boff = 0; cost_boff_energy = 0; cost_boff_comm = 0;
kB = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
for j = 1:NJ
    eta_j = P.eta_PUE_east(j);
    Wi_j = state.W_I_cum(j);
    if Wi_j < 1; continue; end
    
    % 东部三节点异构负荷(北京/上海/广州各有不同AI产业特征)
    % 节点1(北京): B类实时推理偏高(互联网+金融), A类最多
    % 节点2(上海): B/C类均衡(金融+制造), 周末C类批量更多
    % 节点3(广州): C类迁移偏多(制造+跨境), B类标准
    east_B_share = [0.38, 0.33, 0.29];   % B类推理各节点份额(和=1)
    east_C_share = [0.27, 0.35, 0.38];   % C类迁移各节点份额(和=1)
    B_share_j = east_B_share(min(j, length(east_B_share))) * NJ;
    C_share_j = east_C_share(min(j, length(east_C_share))) * NJ;
    
    % 服务能力上界
    total_infer_cap = Wi_j * P.eta_token / eta_j;
    Lambda_B_peak = max(demand_y(2,:)) * B_share_j / NJ * P.eta_token / eta_j;
    Lambda_C_peak = max(demand_y(3,:)) * C_share_j / NJ * P.eta_token / eta_j;
    mu_max_B = max(0.40 * total_infer_cap, 1.2 * Lambda_B_peak);
    mu_max_C = max(0.35 * total_infer_cap, 1.2 * Lambda_C_peak);
    
    % 实际到达率（含节点异构份额）
    Lambda_B_full = zeros(N_hour, 1);
    Lambda_C_full = zeros(N_hour, 1);
    for h = 1:N_hour
        hod = mod(h-1, 168) + 1;
        Lambda_B_full(h) = demand_y(2, hod) * B_share_j / NJ * eta_tok_eff / eta_j;
        Lambda_C_full(h) = demand_y(3, hod) * C_share_j / NJ * eta_tok_eff / eta_j;
    end
    
    B_thr_B = P.B_thresh_B_ratio * mean(Lambda_B_full);
    Boff_nodes = [];
    if ~isfield(P,'enable_B_reach') || P.enable_B_reach
        Rm_ = reach_matrix(P, state.z_cum);
        Boff_nodes = find(Rm_(:,j))';
        if ~isempty(Boff_nodes)   % 按时延升序优先
            [~,ord_] = sort(arrayfun(@(ii) P.comm_delay(P.west_hub_idx(ii), P.east_hub_idx(j)), Boff_nodes));
            Boff_nodes = Boff_nodes(ord_);
        end
    end
    
    B_B_h = 0;
    B_C_h = 0;
    S_B_prev = 0;
    WIsh_j = Wi_j / max(1e-9, sum(state.W_I_cum(:)));               % A类按推理装机份额分配(与东部电费口径一致)
    for h = 1:N_hour
        % B类: 先做时延门控跨域外送(经济门控), 余量进入本地队列
        Lam_B_h = Lambda_B_full(h);
        A_tok_h = demand_y(1, mod(h-1,168)+1) * WIsh_j / eta_j * eta_tok_eff;
        capB_h  = max(0, total_infer_cap - A_tok_h);                 % A优先占用后的剩余推理能力
        if ~isempty(Boff_nodes)
            off_want = kB * Lam_B_h;  off_done = 0;
            c_e_t = actual.price(h,NI+j)/10000 * eta_j / P.eta_token;
            for iw = Boff_nodes
                if off_want - off_done < 1e-6; break; end
                spare_w = max(0, state.W_T_cum(iw) - actual.P_train(h,iw) - actual.P_Boff(h,iw));
                if spare_w < 0.5; continue; end
                Dij = P.comm_delay(P.west_hub_idx(iw), P.east_hub_idx(j));
                c_cm_t = (P.comm_cost_base + P.comm_cost_per_ms*max(0,Dij-5)) ...
                         * P.eta_PUE_west(iw) / (P.eta_token * P.delta_comm(iw));
                if actual.P_curt(h,iw) > 1
                    c_w_t = P.C_curt_op/10000 * P.eta_PUE_west(iw) / P.eta_token;
                else
                    c_w_t = actual.price(h,iw)/10000 * P.eta_PUE_west(iw) / P.eta_token;
                end
                if c_e_t <= c_w_t + c_cm_t; continue; end          % 经济门控
                tok_cap = spare_w / P.eta_PUE_west(iw) * P.eta_token * P.delta_comm(iw);
                off = min(off_want - off_done, tok_cap);
                MW  = off * P.eta_PUE_west(iw) / (P.eta_token * P.delta_comm(iw));
                absorb = min(actual.P_curt(h,iw), MW);
                actual.P_curt(h,iw) = actual.P_curt(h,iw) - absorb;
                actual.P_Boff(h,iw) = actual.P_Boff(h,iw) + MW;
                cost_boff_energy = cost_boff_energy + actual.price(h,iw)*(MW-absorb)/10000;
                cost_boff_comm   = cost_boff_comm + off * c_cm_t;
                rev_boff = rev_boff + p_R_per_node(j) * 0.1 * off;
                off_done = off_done + off;
                actual.Boff_OD(j, iw) = actual.Boff_OD(j, iw) + off;
            end
            actual.B_off(h,j) = off_done;
            Lam_B_h = Lam_B_h - off_done;
        end
        S_up = min([mu_max_B, capB_h, B_B_h + Lam_B_h]);
        S_lo = P.SLA_floor_B * Lam_B_h;
        if h > 1
            S_lo = max(S_lo, S_B_prev - P.Delta_down * mu_max_B);
            S_up = min(S_up, S_B_prev + P.Delta_up * mu_max_B);
        end
        S_lo = min(S_lo, S_up);
        S_B_h = max(S_lo, min(S_up, B_B_h + Lam_B_h));
        B_B_h = max(0, B_B_h + Lam_B_h - S_B_h);
        
        actual.B_B(h,j) = B_B_h;
        actual.S_B(h,j) = S_B_h;
        
        % C类(简化)
        S_C_h = P.SLA_floor_C * Lambda_C_full(h);
        S_C_h = min([mu_max_C, max(0, capB_h - S_B_h), S_C_h]);      % C类只用A、B之后的剩余能力
        B_C_h = max(0, B_C_h + Lambda_C_full(h) - S_C_h);
        actual.B_C(h,j) = B_C_h;
        actual.S_C(h,j) = S_C_h;
        
        % 调峰功率
        if h > 1
            actual.dP_flex(h,j) = (S_B_prev - S_B_h)/P.eta_token * eta_j;   % MW(原缺η)
            actual.vpp_hourly(h) = actual.vpp_hourly(h) + max(0, actual.dP_flex(h,j));
        end
        
        % 违约统计
        if B_B_h > B_thr_B
            actual.SLA_viol_count = actual.SLA_viol_count + 1;
        end
        
        S_B_prev = S_B_h;
    end
end

actual.sla_B_viol_rate = actual.SLA_viol_count / (N_hour * NJ);

% SLA违约率回写SKU（供下一年compute_value_density动态调整w_i）
% 按节点分配违约率（当前为全局，后续可扩展为per-node）
SKU.sla_viol_rate = actual.sla_B_viol_rate * ones(P.N_west, 1);

%% ── 6. C类跨域迁移(真实多维博弈决策) ───────────────────────────────────
%  对应论文式(28)-(30): 跨域迁移最小成本流博弈
%  
%  迁移决策不是单一电价比较, 而是综合以下六维因素的净收益博弈:
%    (1) 西部批量推理服务收益  p_B × token量
%    (2) 跨域通信成本          c_comm(D_ji)  随时延递增
%    (3) 西部电力成本          λ_w,i 等效电费(弃电时段近零)
%    (4) 西部绿电消纳激励      若西部正弃电, 迁入消纳绿电额外收益
%    (5) 东部等待违约机会成本  东部积压越高, 迁出避免违约的收益越大
%    (6) 西部P2空余容量约束    扣除P1合同保障后的可用算力
%  
%  仅当净收益>0(迁移优于留东部)且通信时延可达时触发, 按净收益最优分配
%% =========================================================================
actual.C_migration = zeros(N_hour, NI*NJ);
actual.total_migration = 0;
actual.migration_OD = zeros(NJ, NI);   % 累计OD迁移矩阵(东j→西i, 绘图用)
actual.P_mig_run = zeros(N_hour, NI);  % 迁移任务执行功率(能量台账)
cost_mig_energy = 0;                   % 迁移非弃电时段的购电成本
actual.avg_comm_delay  = 0;   % 加权平均通信时延(ms)
n_migration_events = 0;
actual.migration_revenue = 0;       % 迁移净收益累计(万元, 东部视角)
actual.west_nash_surplus = 0;       % 西部Nash议价收益(卖方盈余)

% 预计算各西部节点P2级空余算力(扣除P1合同保障)
% P2空余 = (W_T - 合同保障功率) 对应的可处理token能力
W_P1 = zeros(NI, 1);
for i = 1:NI
    W_P1(i) = P.W_contract_D(i) / P.eta_PUE_west(i);
end

% C类时延上限(秒→小时判据), 全部西部节点对东部均可达(骨干<40ms << 24h)
d_max_C_ms = P.d_max_C;   % 86400000 ms

% 批量推理西部定价(元/千tokens)
p_B_west = P.lambda_compute_base * (1 + P.pi_service_B) * 0.035 * ones(NI,1);

for h = 1:N_hour
    % 每个东部节点: C类可迁供给 = 当前到达 + 积压(主动经济分流, 非仅被动积压)
    for j = 1:NJ
        eta_j = P.eta_PUE_east(j);
        % C类到达量(百万tokens) + 积压: 需求增→到达增→可迁量增
        Lambda_C_h = demand_y(3, mod(h-1,168)+1) * C_share_j / NJ * P.eta_token / eta_j;
        supply_C = actual.B_C(h, j) + Lambda_C_h;
        if supply_C < 0.1; continue; end
        
        % 东部电价时序(VPP博弈蕴含计算需要)
        scen_e_j = actual.price(:, NI+j);   % 东部j节点全年电价时序
        mean_lam_e_j = mean(scen_e_j);       % 年均东部电价
        
        % 东部本地处理该C类的电力成本密度
        price_east_h = actual.price(h, NI+j);
        c_elec_east = price_east_h / 10000 / (P.eta_token) * eta_j;
        
        % 东部等待违约机会成本(仅决策用, 限幅)
        Lambda_C_avg = mean(demand_y(3,:)) / NJ * P.eta_token / eta_j;
        B_thr_C_j = P.B_thresh_C_ratio * Lambda_C_avg * 12;
        backlog_pressure = min(2.0, max(0, actual.B_C(h,j) - B_thr_C_j) / max(1, B_thr_C_j));
        C_wait_viol = P.pi_C_viol / 10000 * (0.3 + backlog_pressure);
        
        % ── 计算迁移到每个西部节点的净收益(东数西算电价差本质) ────────
        net_decision = -inf(NI, 1);
        net_revenue = zeros(NI, 1);
        for i = 1:NI
            if state.W_T_cum(i) < 1; continue; end
            
            % 西部P2空余容量(百万tokens/h)
            spare_MW = max(0, state.W_T_cum(i) - max(W_P1(i), actual.P_train(h,i)) - actual.P_Boff(h,i));
            spare_tok = spare_MW * P.eta_token / P.eta_PUE_west(i) * P.delta_comm(i);
            if spare_tok < 0.1; continue; end
            
            % 通信成本(随时延递增, 万元/百万tokens; 系数校准为算力收益的小比例)
            D_ji = P.comm_delay(P.east_hub_idx(j), P.west_hub_idx(i));
            if D_ji > d_max_C_ms; continue; end
            c_comm = (P.comm_cost_base + P.comm_cost_per_ms * max(0, D_ji - 5)) ...
                     * P.eta_PUE_west(i) / (eta_tok_eff * P.delta_comm(i));
            
            % 西部处理该C类的电力成本(万元/百万tokens)
            if actual.mode(h,i) == 1
                % 弃电模式: 迁入消纳绿电, 电力成本近零 + 绿电消纳激励
                c_elec_west = P.C_curt_op / 10000 / eta_tok_eff * P.eta_PUE_west(i);
                % 新价格体系下等于C价的83倍, 曾致迁移边际虚高1200倍/Y1回收)
                green_bonus = P.lambda_GEC / 10000 / eta_tok_eff * P.eta_PUE_west(i);
            else
                c_elec_west = actual.price(h,i) / 10000 / eta_tok_eff * P.eta_PUE_west(i);
                green_bonus = 0;
            end
            
            % ── C类迁移双重博弈蕴含 ──────────────────────────────────────
            % 【博弈1】Nash价格议价: 东西电价差按β=0.5分配
            beta_nash = 0.5;
            total_surplus = (c_elec_east - c_elec_west) - c_comm + green_bonus;
            if total_surplus > 0
                west_surplus_i = beta_nash * total_surplus;
                east_saving_i  = (1 - beta_nash) * total_surplus;
                net_revenue(i) = east_saving_i + green_bonus;
            else
                west_surplus_i = 0;
                net_revenue(i) = total_surplus;
            end
            
            % 【博弈2】VPP调峰博弈蕴含: B/C积压队列弹性→虚拟电厂调峰
            % 当C类任务被迁移到西部处理时, 东部负荷降低(减少了本地GPU用电)
            % 这个负荷降低在高电价时段 = 虚拟发电(VPP调峰)
            % 东部从电网收到的调峰激励(lambda_flex_eff)叠加到迁移决策价值中
            % 体现了积压队列作为"虚拟电厂"参与东部电网调峰的经济价值
            lam_e_h = scen_e_j(h);        % 该时刻东部电价
            lam_e_mean_h = mean_lam_e_j;  % 东部电价均值
            if lam_e_h > lam_e_mean_h * 1.1   % 高电价时段(超均值10%)
                price_premium = (lam_e_h - lam_e_mean_h) / max(1, lam_e_mean_h);
                lambda_flex_eff = P.lambda_flex * (1 + 0.8 * price_premium);
                % 每单位C任务迁移对应的东部负荷降低量(MW/百万tokens)
                load_reduce_per_tok = eta_j / P.eta_token;   % MW per Mtok/h(原缺η)
                VPP_value_per_tok = lambda_flex_eff / 10000 * load_reduce_per_tok;
                net_decision(i) = total_surplus + C_wait_viol + VPP_value_per_tok;
            else
                net_decision(i) = total_surplus + C_wait_viol;
            end
        end
        
        % ── 按决策净收益降序分配(最小成本流贪心) ──────────────────────
        % Sinkhorn-OT: 熵正则最优传输求迁移计划(每小时一次, j==1时求解)
        % 数学关系: GAT-Route行softmax=Sinkhorn半步; 完整Sinkhorn补列约束
        % (容量可行性内生), ε→0收敛精确OT——严格支配注意力路由
        if (~isfield(P,'enable_sinkhorn') || P.enable_sinkhorn) && j == 1
            sup_all = zeros(NJ,1); cap_all = zeros(NI,1);
            for j2 = 1:NJ
                sup_all(j2) = actual.B_C(h,j2) + demand_y(3, mod(h-1,168)+1) ...
                              * P.eta_token / (NJ * P.eta_PUE_east(j2));
            end
            for i2 = 1:NI
                sp_MW = max(0, state.W_T_cum(i2) - max(W_P1(i2), actual.P_train(h,i2)) - actual.P_Boff(h,i2));
                cap_all(i2) = sp_MW * P.eta_token / P.eta_PUE_west(i2) * P.delta_comm(i2);
            end
            Cji = zeros(NJ, NI);
            for j2 = 1:NJ
                for i2 = 1:NI
                    Dj2 = P.comm_delay(P.east_hub_idx(j2), P.west_hub_idx(i2));
                    ccm = (P.comm_cost_base + P.comm_cost_per_ms*max(0,Dj2-5)) ...
                          * P.eta_PUE_west(i2)/(P.eta_token*P.delta_comm(i2));
                    if actual.P_curt(h,i2) > 1
                        cel = P.C_curt_op/10000/P.eta_token*P.eta_PUE_west(i2);
                        gbn = P.lambda_GEC/10000/P.eta_token*P.eta_PUE_west(i2);
                    else
                        cel = actual.price(h,i2)/10000/P.eta_token*P.eta_PUE_west(i2);
                        gbn = 0;
                    end
                    Cji(j2,i2) = ccm + cel - gbn;
                end
            end
            [plan_h, sk_i_] = sinkhorn_migration(sup_all, cap_all, Cji, P);
            % Kantorovich对偶势累计(节点边际价值信号→归因/论文图)
            if isfield(sk_i_,'u') && ~isempty(sk_i_.u)
                if ~isfield(actual,'ot_n'); actual.ot_n=0; ...
                    actual.ot_f=zeros(NJ,1); actual.ot_g=zeros(NI,1); end
                eps_r = 0.05; if isfield(P,'sinkhorn_eps'); eps_r=P.sinkhorn_eps; end
                actual.ot_f = actual.ot_f + eps_r*log(max(sk_i_.u,1e-300));
                actual.ot_g = actual.ot_g + eps_r*log(max(sk_i_.v,1e-300));
                actual.ot_n = actual.ot_n + 1;
            end
        elseif j == 1
            plan_h = inf(NJ, NI);   % 关闭Sinkhorn→无计划封顶(消融回退)
        end
        [sorted_dec, sidx] = sort(net_decision, 'descend');
        supply_rem = supply_C;   % 供给余量: 防同一份供给被多个西部节点重复吃(原18×多计根源)
        for k = 1:NI
            i = sidx(k);
            if sorted_dec(k) <= 0 || isinf(sorted_dec(k)); break; end
            if supply_rem < 0.1; break; end
            
            spare_MW = max(0, state.W_T_cum(i) - max(W_P1(i), actual.P_train(h,i)) - actual.P_Boff(h,i));
            spare_tok = spare_MW * P.eta_token / P.eta_PUE_west(i) * P.delta_comm(i);
            if spare_tok < 0.1; continue; end
            
            plan_cap = inf;
            if exist('plan_h','var') && all(isfinite(plan_h(:)))
                plan_cap = plan_h(j,i) * 1.10;   % OT计划封顶(10%执行余量)
            end
            flow = min([supply_rem, spare_tok, plan_cap]);
            if flow < 0.01; continue; end
            
            col = (j-1)*NI + i;
            actual.C_migration(h, col) = actual.C_migration(h, col) + flow;
            actual.migration_OD(j, i) = actual.migration_OD(j, i) + flow;
            % 迁移消化的部分: 优先减积压, 余量算分流
            actual.B_C(h, j) = max(0, actual.B_C(h,j) - flow);
            supply_rem = supply_rem - flow;
            % 迁移执行能量入台账: 弃电优先吸收(修正弃电率高估), 余量购电计费
            MW_mig = flow * P.eta_PUE_west(i) / (P.eta_token * P.delta_comm(i));
            absorb = min(actual.P_curt(h,i), MW_mig);
            actual.P_curt(h,i) = actual.P_curt(h,i) - absorb;
            actual.P_mig_run(h,i) = actual.P_mig_run(h,i) + MW_mig;
            rem_mw = MW_mig - absorb;
            if rem_mw > 1e-6
                cost_mig_energy = cost_mig_energy + actual.price(h,i)*rem_mw/10000;
            end
            actual.total_migration = actual.total_migration + flow;
            actual.avg_comm_delay  = actual.avg_comm_delay + flow * D_ji;
            n_migration_events = n_migration_events + (flow > 0);
            actual.migration_revenue = actual.migration_revenue + max(0, net_revenue(i)) * flow;
            if total_surplus > 0
                actual.west_nash_surplus = actual.west_nash_surplus + west_surplus_i * flow;
            end
            
            supply_C = supply_C - flow;
            if supply_C < 0.01; break; end
        end
    end
end

%% ── 7. 收益核算 ──────────────────────────────────────────────────────
% 西部训练收益(分层：合同全价+现货折扣，逐时累计) - 电力成本
% 规则与规划层一致: ①弃电时段剩余绿电外送(算力吸纳之后); ②非弃电时段东西价差>10元/MWh时套利外送
actual.P_hvdc = zeros(N_hour, NI); rev_hvdc = 0;
capM = zeros(NI, NJ);
if isfield(P,'HVDC_cap_per_node'); capM = P.HVDC_cap_per_node; end
if isfield(state,'dL_cum') && isequal(size(state.dL_cum), size(capM)); capM = capM + state.dL_cum; end
c_op_h = 0; if isfield(P,'c_hvdc_op'); c_op_h = P.c_hvdc_op; end
loss_h = 0; if isfield(P,'hvdc_loss'); loss_h = P.hvdc_loss; end
if any(capM(:) > 0.1)
    for h = 1:N_hour
        hod = mod(h-1,168) + 1;
        east_dem = sum(demand_y(1:3, hod));                     % 东部算力负荷(MW), 套利外送上限
        pe = actual.price(h, NI+1:NI+NJ); [pes, oj] = sort(pe, 'descend');
        for i = 1:NI
            sur = actual.P_curt(h,i);
            for q = 1:NJ
                j = oj(q); cap = capM(i,j); if cap < 0.1; continue; end
                if sur > 1                                        % ①弃电外送(能量免费)
                    f = min(sur, cap); v = pes(q)*(1-loss_h) - c_op_h;
                    if v > 0
                        sur = sur - f; actual.P_hvdc(h,i) = actual.P_hvdc(h,i) + f;
                        rev_hvdc = rev_hvdc + f * v / 10000; cap = cap - f;
                    end
                end
                spread = pes(q)*(1-loss_h) - actual.price(h,i) - c_op_h;   % ②价差套利(购西部网电)
                if cap > 0.1 && spread > 10 && east_dem > 1 && isfield(P,'hvdc_arbitrage') && P.hvdc_arbitrage
                    f = min([cap, east_dem/NI]); east_dem = east_dem - f;
                    actual.P_hvdc(h,i) = actual.P_hvdc(h,i) + f; rev_hvdc = rev_hvdc + f * spread / 10000;
                end
            end
            actual.P_curt(h,i) = sur;
        end
    end
end
rev_west = actual.rev_west_tiered;
cost_west = 0;
for i = 1:NI
    cost_west = cost_west + sum(actual.price(:,i) .* actual.P_grid(:,i)) / 10000;
end

% 东部推理收益(定价源已统一至SKU)
rev_east = 0;
cost_east = 0;
% C类本地服务价: p_B_s字段即C/现货档(已锚定至pM_mig=0.18元/M), 语义正确
p_C_eff = p_B_s_eff;
hod_v = mod((0:N_hour-1),168)+1;
A_MW_series = demand_y(1, hod_v);
WIsh0 = state.W_I_cum(:)';
if sum(WIsh0)>0; WIsh0=WIsh0/sum(WIsh0); else; WIsh0=ones(1,NJ)/NJ; end
rev_eA = 0; rev_eB = 0; rev_eC = 0;       % 东部收入按SLA类别分解(供流积递演)
for j = 1:NJ
    rev_eB = rev_eB + p_R_per_node(j) * sum(actual.S_B(:,j)) * 0.1;
    rev_eC = rev_eC + p_C_eff * sum(actual.S_C(:,j)) * 0.1;
    rev_east = rev_east + p_R_per_node(j) * sum(actual.S_B(:,j)) * 0.1 ...
                        + p_C_eff * sum(actual.S_C(:,j)) * 0.1;
    % A类电费: 逐时A功率×容量份额×实时电价(原用峰值×均价高估且与收入口径不一致)
    A_MW_j  = A_MW_series' * WIsh0(j);                       % 设施MW(原/PUE少计)
    BC_MW_j = (actual.S_B(:,j) + actual.S_C(:,j)) / P.eta_token * P.eta_PUE_east(j);  % B/C用电(原漏计)
    cost_east = cost_east + sum(actual.price(:,NI+j) .* (A_MW_j + BC_MW_j)) / 10000;
end
%    而cost_east却在支付A类电费——单边账导致东部收益仅37亿的畸形) ──
hod_vec = mod((0:N_hour-1), 168) + 1;
A_MW_h  = demand_y(1, hod_vec);                       % 东部A类总MW时序
WIsh = state.W_I_cum(:)';
if sum(WIsh) > 0; WIsh = WIsh / sum(WIsh); else; WIsh = ones(1,NJ)/NJ; end
for j = 1:NJ
    tok_A_j = sum(A_MW_h) * WIsh(j) / P.eta_PUE_east(j) * eta_tok_eff;
    rev_east = rev_east + p_R_per_node(j) * 0.1 * tok_A_j;
    rev_eA = rev_eA + p_R_per_node(j) * 0.1 * tok_A_j;
    actual.tok_A_acc(j) = tok_A_j;
end

% 调峰收益: lambda_flex联动实时电价(高电价时段调峰价值更高)
% VPP核心: 调峰激励应随电价偏离动态变化, 而非固定参数
rev_flex = 0;
price_all_east = actual.price(:, NI+1:end);   % 东部实时电价矩阵
price_mean_east = mean(price_all_east(:));
for h = 1:N_hour
    for j = 1:NJ
        dP_hj = actual.dP_flex(h, j);
        if abs(dP_hj) < 0.01; continue; end
        lam_t = actual.price(h, NI+j);
        % 高电价时调峰激励更强: lambda_flex_eff = lambda_flex × (1 + 价格偏离系数)
        price_premium = max(0, lam_t - price_mean_east) / price_mean_east;
        lambda_flex_eff = P.lambda_flex * (1 + 0.8 * price_premium);  % 最高1.8倍
        rev_flex = rev_flex + lambda_flex_eff/10000 * abs(dP_hj);
    end
end

% C类跨域迁移净收益(多维博弈产出)
rev_migration = actual.migration_revenue;

% ── 补全运行成本(此前缺失) ──────────────────────────────────────────
% (1) 固定运维成本O&M
C_om_train = 60;    % 万元/MW/年 (运维, ≈投资4%)
C_om_infer = 48;    % 万元/MW/年
C_om_renew = 8.5;   % 万元/MW/年
C_om_stor  = 1.2;   % 万元/MWh/年

% ── 储能完整成本核算 ─────────────────────────────────────────────────
C_stor_depr_w = P.C_stor * 1000 / P.T_stor_life;
C_stor_depr_e = P.C_stor * 1000 / P.T_stor_life;
C_stor_replace = P.C_stor * 1000 / (P.T_life - P.T_stor_life + 1);

% GPU硬件年折旧（H100/A100约4年替换一次，是最大隐性成本）
C_gpu_depr_train = P.C_gpu_annual;   % 万元/MW/年 ≈262.5万/MW/年

cost_om = C_om_train * sum(state.W_T_cum) ...
        + C_om_infer * sum(state.W_I_cum) ...
        + C_om_renew * sum(state.G_cum) ...
        + C_stor_depr_w * sum(state.E_w_cum) ...        % 西部储能年折旧(10年)
        + C_stor_depr_e * sum(state.E_e_cum) ...        % 东部储能年折旧(10年)
        + C_gpu_depr_train * sum(state.W_T_cum);        % GPU折旧(训练)
% 折旧为非现金项, 单列供现金流口径使用(投资已在资本支出中计入, 避免重复)
actual.cost_depr = C_stor_depr_w*sum(state.E_w_cum) + C_stor_depr_e*sum(state.E_e_cum) ...
                 + C_gpu_depr_train*sum(state.W_T_cum);

% (2) 任务量变动成本(随Token吞吐: 数据传输、冷却、人力, 任务越多成本越高)
total_token = sum(actual.T_gen(:)) + sum(actual.S_B(:)) + sum(actual.S_C(:));
% 变动运维: 每MWh参数派生(η自适应; 原0.003万/Mtok为η=5时代字面量,
% 在η=2000下等于¥30/Mtok×3e11 Mtok/yr=9万亿/年幽灵成本, 致NPV=-56万亿)
% 等效强度保持: 原0.003万/Mtok@η=5 ≈ 136元/MWh → 取130元/MWh
C_var_om = 130; if isfield(P,'C_var_om_MWh'); C_var_om = P.C_var_om_MWh; end
c_var_per_Mtok = C_var_om / 10000 / eta_tok_eff * 1.15;   % 混合PUE
cost_variable = c_var_per_Mtok * total_token;

% (3) C类迁移通信传输成本(迁移有成本: 跨域带宽+传输能耗)
c_migr_per_Mtok = P.comm_cost_base * mean(P.eta_PUE_west) / eta_tok_eff;  % 每MWh参数折token(η自适应)
cost_migration = c_migr_per_Mtok * actual.total_migration;

% (4) 储能充放循环成本(O&M + 往返效率损耗电费)
% 往返效率=eta_stor²≈0.84, 每MWh充电损耗=(1-eta_rt)MWh
% 损耗电费=(1-eta_rt) × 充电量 × 均价, 这是储能被长期低估的隐性成本
P_ch_total  = sum(actual.P_ch(:));
P_dis_total = sum(actual.P_dis(:));
eta_rt = 0.92^2;   % 往返效率(单程0.92^2≈0.84)
rt_loss_frac = (1 - eta_rt);  % 每MWh充电损耗的MWh数(=0.16)
lam_avg_w = mean(actual.price(:, 1:P.N_west), 'all');
cost_stor_cycle = P.C_stor_op/10000 * (P_ch_total + P_dis_total) ...
               + rt_loss_frac * lam_avg_w/10000 * P_ch_total;   % 往返损耗电费

% ── 强化积压队列的虚拟电厂(VPP)功能 ─────────────────────────────────
% 积压队列通过调节服务率实现需求响应: 高电价时段削峰(减服务=虚拟发电),
% 低电价时段填谷(增服务). 这是数据中心作为虚拟电厂参与电网辅助服务的核心价值.
rev_vpp = 0;
for j = 1:NJ
    eta_j = P.eta_PUE_east(j);
    price_j = actual.price(:, NI+j);
    price_avg_j = mean(price_j);
    for h = 2:N_hour
        % 服务率变化对应的负荷调节量(MW)
        dS_B = actual.S_B(h,j) - actual.S_B(h-1,j);
        dLoad = -dS_B / P.eta_token * eta_j;   % 服务减少=负荷减少(MW, 原缺η致VPP×η倍)
        % 削峰填谷套利: 高于均价时削峰(dLoad<0)赚价差, 低于均价时填谷
        price_dev = price_j(h) - price_avg_j;
        % 削峰填谷收益 = 负荷调节 × 电价偏离 (高价削峰/低价填谷均为正收益)
        vpp_arbitrage = dLoad * price_dev / 10000;
        rev_vpp = rev_vpp + max(0, vpp_arbitrage);
    end
    % 容量市场收益: 提供可调容量(积压队列可调范围)参与容量市场
    adjustable_cap = (max(actual.S_B(:,j)) - min(actual.S_B(:,j))) / P.eta_token * eta_j;  % MW
    rev_vpp = rev_vpp + adjustable_cap * P.lambda_cap_east / 10000 * 12;  % 月度容量费×12
end

% ── 汇总 ────────────────────────────────────────────────────────────
actual.revenue_total = rev_west + rev_east + rev_flex + rev_migration + rev_vpp + rev_boff + rev_hvdc;
actual.rev_east_cls = [rev_eA, rev_eB, rev_eC];   % [A,B,C]类东部本地服务收入(万元)
% 分项存档(瀑布图数据源)
actual.tok_A = sum(actual.tok_A_acc);
if ~isfield(P,'quiet_actual') || ~P.quiet_actual
fprintf('  [收入分解] 西训%.0f 东推%.0f 柔性%.0f 迁移%.0f VPP%.0f B跨域%.0f HVDC外送%.0f 亿 | 东电费%.0f 西电费%.0f 亿 | B外送率%.1f%%\n', ...
    rev_west/1e4, rev_east/1e4, rev_flex/1e4, rev_migration/1e4, rev_vpp/1e4, rev_boff/1e4, rev_hvdc/1e4, ...
    cost_east/1e4, cost_west/1e4, 100*sum(actual.B_off(:))/max(1,sum(actual.B_off(:))+sum(actual.S_B(:))));
end
actual.rev_parts  = struct('west',rev_west,'east',rev_east,'flex',rev_flex, ...
                           'migration',rev_migration,'vpp',rev_vpp,'b_offload',rev_boff,'hvdc',rev_hvdc);
actual.cost_parts = struct('west',cost_west,'east',cost_east,'om',cost_om, ...
                           'variable',cost_variable,'stor',cost_stor_cycle, ...
                           'mig_comm',cost_migration,'mig_energy',cost_mig_energy, ...
                           'boff_energy',cost_boff_energy,'boff_comm',cost_boff_comm);
cost_variable = cost_variable + cost_mig_energy;   % 迁移购电并入可变成本
actual.cost_total = cost_west + cost_east + cost_om + cost_variable ...
                  + cost_migration + cost_stor_cycle + cost_boff_energy + cost_boff_comm;
actual.net_profit = actual.revenue_total - actual.cost_total;
% 加权平均通信时延（有迁移时才有意义）
if actual.total_migration > 0
    actual.avg_comm_delay = actual.avg_comm_delay / actual.total_migration;
else
    actual.avg_comm_delay = NaN;
end

% 年末SOC比例（供下一年初始化使用）
% 取所有小时末尾的SOC均值作为代表值
E_soc_final_frac = zeros(P.N_west, 1);
for i = 1:P.N_west
    Ei = state.E_w_cum(i);
    if Ei > 0.1 && isfield(actual,'E_soc') && size(actual.E_soc,1) >= i
        soc_end = mean(actual.E_soc(i, max(1,end-167):end));  % 末尾168h均值
        E_soc_final_frac(i) = soc_end / Ei;
    else
        E_soc_final_frac(i) = 0.50;
    end
end
actual.E_soc_final_frac = max(P.SOC_min_ratio, min(P.SOC_max_ratio, E_soc_final_frac));

% 成本明细(供分析)
actual.cost_breakdown = struct('elec_west', cost_west, 'elec_east', cost_east, ...
    'om_fixed', cost_om, 'variable', cost_variable, 'migration', cost_migration, ...
    'stor_cycle', cost_stor_cycle);
actual.rev_breakdown = struct('train', rev_west, 'infer', rev_east, ...
    'flex', rev_flex, 'migration', rev_migration, 'vpp', rev_vpp, 'b_offload', rev_boff);

actual.year_num = year;   % 当前规划年（供NPV折现使用）
if ~isfield(actual,'F1_incremental')
    actual.F1_incremental = 0;
end
F1_cum = P.C_train_fix * sum(state.W_T_cum) ...
       + P.C_renew_wind * 1000 * sum(state.G_cum) * 0.5 ...
       + P.C_renew_pv * 1000 * sum(state.G_cum) * 0.5 ...
       + P.C_stor * 1000 * sum(state.E_w_cum) ...
       + P.C_infer_fix * sum(state.W_I_cum) ...
       + P.C_stor * 1000 * sum(state.E_e_cum) ...
       + sum(sum(P.C_trans_per_node .* state.dL_cum));
F1_cum = F1_cum(1);

% 简单ROI（无折现，仅供参考）
if F1_cum > 0
    actual.ROI = actual.net_profit(1) / F1_cum;
else
    actual.ROI = 0;
end

% NPV折现ROI（WACC=8%，更真实的项目价值评估）
wacc = isfield(P,'r_min') * P.r_min + ~isfield(P,'r_min') * 0.08;
year_num = actual.year_num;  % 当前年份（第几年）
discount_factor = 1 / (1 + wacc)^year_num;
npv_increment = actual.net_profit(1) * discount_factor;   % 本年现金流折现值
actual.npv_increment  = npv_increment;
actual.discount_factor = discount_factor;

% 净现金流（含折现）
net_cf = actual.net_profit(1) - actual.F1_incremental;    % 现金流 = 收益-本年投资
actual.net_cashflow      = net_cf;
actual.cumulative_cashflow = net_cf;   % 主循环里累加：sum(all_years)

%% ── 8. 实际算力需求(用于历史追加) ──────────────────────────────────────
actual.demand_realized_peak = max(sum(demand_y, 1)) * (0.9 + 0.2*rand());

%% ── 9. 调度模式时段索引列表 ──────────────────────────────────────────
actual.curt_hours = find(any(actual.mode == 1, 2));
actual.grid_hours = find(any(actual.mode == 2, 2));
actual.load_red_hours = find(any(actual.mode == 3, 2));
end
