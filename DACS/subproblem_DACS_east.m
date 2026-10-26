%% =========================================================================
%  subproblem_DACS_east.m  —  东部L_E子问题(前向后向DP+积压队列+HVDC接收)
%  对应论文式(20-27)
%  
%  输入: x_sol(W_I), scen_s(Lambda_A,B,C, lam_e, mean_B, mean_C), P, SKU
%        hvdc_recv_per_j: 东部各节点每时步接收的HVDC电力(1×T, MW)
%  输出: solE(B_B, B_C, S_B, S_C, dP_flex), QE(168h净成本万元)
%% =========================================================================
function [solE, QE] = subproblem_DACS_east(x_sol, scen_s, P, SKU, NJ, T, hvdc_recv_per_j)

if nargin < 7 || isempty(hvdc_recv_per_j)
    hvdc_recv_per_j = zeros(1, T);   % 无HVDC接收（兼容旧接口）
end

eta_PUE_avg = mean(P.eta_PUE_east);

% 东部三节点异构负荷份额(与simulate_actual_operation保持一致)
% 北京: B类推理偏重(金融/互联网), 上海: 均衡, 广州: C类批量偏多(制造/跨境)
% 东部三节点份额（从P参数读取，不再本地硬编码）
EAST_B_SHARE = P.east_B_share;   % B类份额（北京/上海/广州）
EAST_C_SHARE = P.east_C_share;   % C类份额

solE = struct();
solE.B_B = zeros(NJ, T+1);
solE.B_C = zeros(NJ, T+1);
solE.S_B = zeros(NJ, T);
solE.S_C = zeros(NJ, T);
solE.dP_flex = zeros(NJ, T);
solE.r_viol = 0;
solE.dbg = zeros(1,7);   % [RevA RevB RevC Revflex RevBoff 电费 储能] 万元/周(诊断)

QE = 0;

for j = 1:NJ
    eta_j = P.eta_PUE_east(j);
    Wi_j  = x_sol.W_I(j);
    % A类绝对实时(不可降级): 溢价30%; B类标准实时: 标准价; 两类SLA不同
    p_R_j   = SKU.p_R(j);
    p_RA_j  = p_R_j * 1.30;   % A类溢价(绝对实时SLA)
    p_RB_j  = p_R_j;           % B类标准
    p_B_deg_j = isfield(SKU,'p_B_deg') * SKU.p_B_deg(min(j,end)) + ...
                ~isfield(SKU,'p_B_deg') * p_R_j * 0.60;
    p_B_j   = SKU.p_B_s;

    % 节点j的异构到达率(按份额权重分配)
    b_share_j = EAST_B_SHARE(min(j, length(EAST_B_SHARE))) * NJ;
    c_share_j = EAST_C_SHARE(min(j, length(EAST_C_SHARE))) * NJ;
    Lambda_B_tok = scen_s.Lambda_B * P.eta_token / eta_j / NJ * b_share_j;
    Lambda_C_tok = scen_s.Lambda_C * P.eta_token / eta_j / NJ * c_share_j;
    % A类刚性需求: 直接满足, 不进队列, 不参与VPP调峰
    Lambda_A_tok = scen_s.Lambda_A * P.eta_token / eta_j / NJ;
    % ── 创新一: B类时延门控跨域服务(搬token代替搬电子) ─────────────────
    % 可达: 已选址西部节点且时延≤d_max_B_mig(候选路由已叠加进P.comm_delay)
    % 经济门控: 东部逐时电费 > 西部能源代理成本 + 通信费 时才外送
    Rev_Boff = 0; C_Boff = 0;
    if (~isfield(P,'enable_B_reach') || P.enable_B_reach) && isfield(x_sol,'z')
        Rm = reach_matrix(P, x_sol.z);
        if any(Rm(:,j))
            iis = find(Rm(:,j));
            Dj = arrayfun(@(ii) P.comm_delay(P.west_hub_idx(ii), P.east_hub_idx(j)), iis);
            [Dmin, kk] = min(Dj); iw = iis(kk);
            kB = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
            c_comm_tok = (P.comm_cost_base + P.comm_cost_per_ms*max(0,Dmin-5)) ...
                         * P.eta_PUE_west(iw) / (P.eta_token * P.delta_comm(iw));
            c_w_tok = P.lambda_energy_west/10000 * P.eta_PUE_west(iw) / P.eta_token;
            c_e_tok = scen_s.lam_e(j,:)/10000 * eta_j / P.eta_token;
            gate = reshape(c_e_tok > (c_w_tok + c_comm_tok), size(Lambda_B_tok));
            Boff = kB * Lambda_B_tok .* gate;
            Lambda_B_tok = Lambda_B_tok - Boff;
            Rev_Boff = p_RB_j * sum(Boff) * 0.1;
            C_Boff   = sum(Boff) * (c_w_tok + c_comm_tok);
        end
    end
    
    % 容量上界(百万tokens/h)
    % 推理总能力 = W_I × eta_token / eta_j, 按A:B:C = 0.35:0.25:0.25分配
    % 但服务能力上界取"该类份额能力"与"该类到达率峰值×1.2"的较大者
    total_infer_cap = Wi_j * P.eta_token / eta_j;   % 该节点总推理能力
    mu_max_B = max(0.40 * total_infer_cap, 1.2 * max(Lambda_B_tok));
    mu_max_C = max(0.35 * total_infer_cap, 1.2 * max(Lambda_C_tok));
    
    % SLA阈值
    % 积压队列阈值: 90th percentile峰值比均值更合理(避免高峰SLA违约)
    B_thr_B = P.B_thresh_B_ratio * prctile(Lambda_B_tok, 90);
    B_thr_C = P.B_thresh_C_ratio * prctile(Lambda_C_tok, 90) * 12;
    
    B_B = zeros(1, T+1);
    B_C = zeros(1, T+1);
    S_B = zeros(1, T);
    S_C = zeros(1, T);
    
    % ═══════════════════════════════════════════════════════════════════
    % 真正的后向动态规划(论文式20-27的完整实现)
    % 值函数 V(b,t) = max_{S∈[S_lo,S_up]} [r(S,b,t) + V(b',t+1)]
    % 奖励: 推理收益 - 电力成本 - SLA违约惩罚 - 积压等待成本
    % 目的: 最优调度服务率S_B(t), 高电价削峰/低电价填谷, 兼顾SLA
    % ═══════════════════════════════════════════════════════════════════
    
    N_grid = 20;    % 积压状态离散格点数
    N_ctrl = 8;     % 控制(服务率)离散点数
    lam_e_j  = scen_s.lam_e(j, :);
    % ── 东部节点电价响应(与西部对称，线性化LMP效应)──────────────────
    % 东部推理负荷购电↑→受端节点电价上浮；C类西迁降低东部净负荷→电价回落
    if isfield(P,'enable_price_response') && P.enable_price_response
        W_I_j = x_sol.W_I(min(j, length(x_sol.W_I)));
        load_frac = W_I_j / P.price_base_load_e;
        lam_e_j = lam_e_j * (1 + P.price_sens_east * load_frac);
    end
    lam_e_mean = mean(lam_e_j);
    p_R_j = SKU.p_R(j);   % 层1: 正常实时推理价
    p_B_deg_j = isfield(SKU,'p_B_deg') * SKU.p_B_deg(min(j,end)) + ...
                ~isfield(SKU,'p_B_deg') * p_R_j * 0.60;  % 层2a: B降级博弈价
    
    % 价值函数 V(grid_idx, t), 初始化为0 (末期无递延价值)
    V_B = zeros(N_grid, T+1);
    S_opt_B = zeros(N_grid, T);   % 最优服务率查找表
    
    B_max_B = 2 * B_thr_B;
    B_grid_B = linspace(0, B_max_B, N_grid);
    
    % ── 后向递推 ─────────────────────────────────────────────────────
    for t = T:-1:1
        Lambda_t = Lambda_B_tok(t);
        lam_t = lam_e_j(t);
        
        for ib = 1:N_grid
            b = B_grid_B(ib);
            
            % 合法服务率区间(SLA下界 + 容量上界)
            S_lo_t = P.SLA_floor_B * Lambda_t;
            S_up_t = min(mu_max_B, b + Lambda_t);
            S_lo_t = min(S_lo_t, S_up_t);
            
            S_cands = linspace(S_lo_t, S_up_t, N_ctrl);
            best_val = -inf;
            best_s = S_lo_t;
            
            for ic = 1:N_ctrl
                s = S_cands(ic);
                b_next = max(0, min(B_max_B, b + Lambda_t - s));
                
                % 下一步值函数(线性插值)
                ib_next = (b_next / B_max_B) * (N_grid-1) + 1;
                ib_lo = max(1, floor(ib_next)); ib_hi = min(N_grid, ib_lo+1);
                alpha_interp = ib_next - ib_lo;
                V_next = (1-alpha_interp)*V_B(ib_lo,t+1) + alpha_interp*V_B(ib_hi,t+1);
                
                % 当步奖励: 推理收益 - 电费 - SLA违约 - 积压等待成本
                % B降级博弈: 积压>阈值时自动降价(博弈均衡: 用户接受降级, 服务商避全额违约金)
                eff_price = p_R_j;
                if b > B_thr_B * 1.1   % 积压超阈值10%时触发降级
                    eff_price = p_B_deg_j;  % 层2a降级价, 体现博弈让步
                end
                r_infer  = s * eff_price * 0.1;
                r_elec   = -lam_t/10000 * s/P.eta_token * eta_j;   % token→设施MWh(原缺η, 电费×η倍)
                r_sla    = -P.pi_B_viol/10000 * max(0, b - B_thr_B);
                r_wait   = -P.pi_B_viol/10000 * 0.05 * b_next;
                r_t = r_infer + r_elec + r_sla + r_wait;
                
                val = r_t + V_next;
                if val > best_val
                    best_val = val;
                    best_s = s;
                end
            end
            
            V_B(ib, t) = best_val;
            S_opt_B(ib, t) = best_s;
        end
    end
    
    % ── 前向决策: 按值函数查找表执行最优服务率 ───────────────────────
    S_B = zeros(1, T);
    B_B_curr = B_B(1);
    for t = 1:T
        % 当前积压状态对应的格点
        ib_curr = min(N_grid, max(1, round(B_B_curr/B_max_B*(N_grid-1))+1));
        S_B(t) = S_opt_B(ib_curr, t);
        % 爬坡约束修正(论文式21-22: 限制服务率变化速率)
        if t > 1
            S_B(t) = max(S_B(t-1)-P.Delta_down*mu_max_B, ...
                         min(S_B(t-1)+P.Delta_up*mu_max_B, S_B(t)));
        end
        B_B(t+1) = max(0, min(2*B_thr_B, B_B_curr + Lambda_B_tok(t) - S_B(t)));
        B_B_curr = B_B(t+1);
    end
    
    % ── C类同理(简化: 时延容忍高, 使用相同DP框架) ───────────────────
    V_C = zeros(N_grid, T+1);
    S_opt_C = zeros(N_grid, T);
    B_max_C = 3 * B_thr_C;
    B_grid_C = linspace(0, B_max_C, N_grid);
    p_B_j = SKU.p_B(j);
    
    for t = T:-1:1
        Lambda_t = Lambda_C_tok(t);
        lam_t = lam_e_j(t);
        for ib = 1:N_grid
            b = B_grid_C(ib);
            S_lo_t = min(P.SLA_floor_C * Lambda_t, min(mu_max_C, b+Lambda_t));
            S_up_t = min(mu_max_C, b + Lambda_t);
            S_cands = linspace(S_lo_t, S_up_t, N_ctrl);
            best_val = -inf; best_s = S_lo_t;
            for ic = 1:N_ctrl
                s = S_cands(ic);
                b_next = max(0, min(B_max_C, b+Lambda_t-s));
                ib_next = (b_next/B_max_C)*(N_grid-1)+1;
                ib_lo=max(1,floor(ib_next)); ib_hi=min(N_grid,ib_lo+1);
                a2 = ib_next-ib_lo;
                V_next = (1-a2)*V_C(ib_lo,t+1)+a2*V_C(ib_hi,t+1);
                r_infer  = s * p_B_j * 0.1;
                r_elec   = -lam_t/10000 * s/P.eta_token * eta_j * 0.7;
                r_sla    = -P.pi_C_viol/10000 * max(0, b-B_thr_C);
                r_wait   = -P.pi_C_viol/10000 * 0.03 * b_next;
                val = r_infer+r_elec+r_sla+r_wait+V_next;
                if val>best_val; best_val=val; best_s=s; end
            end
            V_C(ib,t)=best_val; S_opt_C(ib,t)=best_s;
        end
    end
    S_C = zeros(1,T);
    B_C_curr = B_C(1);
    for t = 1:T
        ib_curr = min(N_grid,max(1,round(B_C_curr/B_max_C*(N_grid-1))+1));
        S_C(t) = S_opt_C(ib_curr,t);
        if t>1
            S_C(t)=max(S_C(t-1)-P.Delta_down*mu_max_C, ...
                       min(S_C(t-1)+P.Delta_up*mu_max_C, S_C(t)));
        end
        B_C(t+1)=max(0, B_C_curr+Lambda_C_tok(t)-S_C(t));
        B_C_curr=B_C(t+1);
    end
    
    % 调峰等效弹性功率(式25-26): VPP后向DP驱动的服务率变化产生调峰功率
    dP = zeros(1, T);
    R_flex_wan = zeros(1, T);
    for t = 2:T
        dP(t) = (S_B(t-1) - S_B(t)) / P.eta_token * eta_j;   % MW(原token/PUE当MW, 调峰收益×η倍)
        % 调峰收益: 功率变化 × (实时电价偏离均值) + 固定激励
        price_dev_t = max(0, lam_e_j(t) - lam_e_mean) / 10000;  % 高价偏离
        R_flex_wan(t) = (P.lambda_flex / 10000 + price_dev_t) * abs(dP(t));
    end
    
    % ── 东部储能调度(子问题内含SOC动态, 电价响应充放) ─────────────────
    % 以前完全缺失, 现补全: 东部储能在高电价放电减荷, 低电价充电
    E_e_j = x_sol.E_e(min(j, size(x_sol.E_e,1)));  % 东部j节点储能容量(MWh)
    P_stor_e = E_e_j / P.dt_stor;   % 最大充放功率(MW)
    eta_stor = 0.92;   % 储能充放效率(单程92%, 往返84%)
    SOC_e = 0.5 * E_e_j;            % 初始SOC=50%
    P_ch_e = zeros(1, T);
    P_dis_e = zeros(1, T);
    C_stor_e = 0;
    for t = 1:T
        price_t = lam_e_j(t);
        if price_t > lam_e_mean * 1.2 && SOC_e > 0.2 * E_e_j
            % 高电价: 放电减荷(降低电费)
            dis_t = min(P_stor_e, (SOC_e - 0.2*E_e_j) / eta_stor);
            P_dis_e(t) = dis_t;
            SOC_e = SOC_e - dis_t * eta_stor;
        elseif price_t < lam_e_mean * 0.8 && SOC_e < 0.8 * E_e_j
            % 低电价: 充电(储低价电)
            ch_t = min(P_stor_e, 0.8*E_e_j - SOC_e);
            P_ch_e(t) = ch_t;
            SOC_e = SOC_e + ch_t * eta_stor;
            C_stor_e = C_stor_e + ch_t * price_t / 10000;  % 充电成本
        end
    end
    % 储能套利收益: 放电避免的高价购电 - 充电成本
    rev_stor_e = sum(P_dis_e .* lam_e_j / 10000) - C_stor_e;
    
    % SLA违约成本(式24)
    C_SLA_B = P.pi_B_viol/10000 * sum(max(0, B_B(1:T) - B_thr_B));
    C_SLA_C = P.pi_C_viol/10000 * sum(max(0, B_C(1:T) - B_thr_C));
    
    % 东部电力成本：包含HVDC从西部接收的电力购买成本
    lam_w_avg   = P.lambda_energy_west / 10000;
    c_hvdc_unit = P.c_hvdc_op / 10000;
    hvdc_recv_j_avg = mean(hvdc_recv_per_j(min(j, size(hvdc_recv_per_j,1)), :));
    C_hvdc_buy_j = hvdc_recv_j_avg * T * (lam_w_avg + c_hvdc_unit);
    % 注：迁移服务费转移支付在solve_subproblem协调层结算(MCF求解后)

    % A类净需求（扣除HVDC后）
    P_A_demand = mean(scen_s.Lambda_A) / NJ;             % 节点设施MW(原/PUE且未/NJ, 口径错)
    P_A_net    = P_A_demand;   % 修正: HVDC受电已由西部按东部电价计外送收益, 此处再抵扣为重复计算
    if isfield(P,'east_hvdc_offset') && P.east_hvdc_offset; P_A_net = max(0, P_A_demand - hvdc_recv_j_avg); end
    E_total    = P_A_net * T;
    % B/C服务用电(原完全漏计: 收入记账而电费未记)
    E_total    = E_total + (sum(S_B) + sum(S_C)) / P.eta_token * eta_j;
    
    % 第一层(强制): 80%绿电合规 = 本地绿电自发自用 + 剩余绿证补足
    E_green_required = P.GEC_ratio * E_total;    % 必须的绿电量(80%)

    % 本地绿电自给部分（海上风电+分布式光伏，成本=发电边际成本，无需绿证）
    if isfield(P,'east_local_green_ratio') && length(P.east_local_green_ratio) >= j
        local_ratio = P.east_local_green_ratio(j);
    else
        local_ratio = 0.50;
    end
    E_green_local = E_green_required * local_ratio;   % 本地自发绿电量
    E_green_cert  = E_green_required * (1 - local_ratio); % 剩余靠绿证

    % 本地绿电成本：本地绿电替代的是"绿证+市场电"组合
    % 口径对齐：本地绿电边际成本 = 市场绿电批发价 + 海风运维溢价
    % 单位统一：lam_green_wan为万元/MWh
    lam_green_raw = mean(scen_s.lam_e(j,:));   % 元/MWh 东部就地按东部电价(原取西部价, 与实际层口径不一致)
    lam_green_wan = lam_green_raw / 10000;  % 万元/MWh
    if isfield(P,'east_green_capex') && length(P.east_green_capex) >= j
        % 海风度电成本溢价：海上风电LCOE约400-450元/MWh，扣除批发绿电价后
        % 净溢价约50-100元/MWh（0.005-0.01万元/MWh），造价高的节点溢价略高
        base_premium = 0.005;  % 基础溢价50元/MWh(万元/MWh)
        capex_adj = (P.east_green_capex(j) - 8000) / 100000;  % 造价微调(±)
        lcoe_local_wan = lam_green_wan + base_premium + max(0, capex_adj);
    else
        lcoe_local_wan = lam_green_wan + 0.005;
    end
    C_elec_green_local = lcoe_local_wan * E_green_local;   % 万元

    % 绿证部分成本（仅剩余缺口，本地自发部分免绿证）
    C_green = P.lambda_GEC/10000 * E_green_cert;       % 绿证成本(万元)
    C_elec_green_cert = lam_green_wan * E_green_cert;  % 绿证对应电力成本(万元)

    % 绿电合规总成本 = 本地自发 + 绿证补足
    C_elec_green = C_elec_green_local + C_elec_green_cert;
    
    % 第二层(经济): 剩余20%用市场电, 追逐低电价时段(纯经济驱动)
    E_market = (1 - P.GEC_ratio) * E_total;      % 自由经济部分(20%)
    % 市场电成本: 用该情景的时段平均电价(经济调度会优先低价时段, 取25分位近似)
    lam_e_sorted = sort(scen_s.lam_e(j, :));
    lam_market_econ = mean(lam_e_sorted(1:max(1,round(0.5*T))));  % 低价半段均价
    C_elec_market = lam_market_econ/10000 * E_market;
    
    % 东部总电力成本 = 绿电合规部分(80%) + 市场经济部分(20%, 追低价)
    C_elec = C_elec_green + C_elec_market;
    if isfield(P,'calib_elec_east'); C_elec = C_elec * P.calib_elec_east; end   % 运行→规划校准
    C_GEC = C_green;
    
    % 推理收益(式27)
    % 物理含义：A类任务若未被立即服务（容量不足），将被丢弃（客户端超时重连）
    % 容量约束：A类可服务量 = min(Lambda_A, 0.35×总推理能力)
    % A类优先使用全部推理容量, 与实际运行层一致
    A_cap_j = Wi_j * P.eta_token / eta_j;
    Lambda_A_served = min(Lambda_A_tok, A_cap_j);    % 实际满足量
    Lambda_A_drop   = max(0, Lambda_A_tok - A_cap_j); % 超容量丢弃量
    % A类丢弃惩罚：高于服务收益的2倍（SLA违约赔偿+声誉损失）
    pi_A_drop = p_RA_j * 2.0;
    pen_A_drop_wan = pi_A_drop * sum(Lambda_A_drop) * 0.1;

    Rev_A_wan = p_RA_j  * sum(Lambda_A_served) * 0.1;  % 仅计已服务的A类
    Rev_B_wan = p_RB_j  * sum(S_B) * 0.1;            % B类标准实时
    Rev_C_wan = p_B_j   * sum(S_C) * 0.1;
    Rev_flex  = sum(R_flex_wan);
    
    Profit_j = Rev_A_wan + Rev_B_wan + Rev_C_wan + Rev_flex + rev_stor_e + Rev_Boff - C_Boff ...
               - C_elec - C_GEC - C_SLA_B - C_SLA_C - pen_A_drop_wan - C_hvdc_buy_j;
    QE = QE - Profit_j;
    solE.dbg = solE.dbg + [Rev_A_wan, Rev_B_wan, Rev_C_wan, Rev_flex, Rev_Boff, C_elec, rev_stor_e];
    
    % 记录
    solE.B_B(j, :) = B_B;
    solE.B_C(j, :) = B_C;
    solE.S_B(j, :) = S_B;
    solE.S_C(j, :) = S_C;
    solE.dP_flex(j, :) = dP;
    
    % 违约率(全年时步中超阈占比)
    viol_B_rate = mean(B_B(1:T) > B_thr_B);
    solE.r_viol = solE.r_viol + viol_B_rate / NJ;
end

solE.QE_base = QE;

% ── 积压队列统计（论文证据：队列真实存在且受SLA边界约束）─────────────
% Little定律：平均等待时间 W = 平均队长 L / 平均到达率 λ
solE.queue_stats = struct();
solE.queue_stats.B_B_max  = max(solE.B_B(:));                    % B类最大积压
solE.queue_stats.B_C_max  = max(solE.B_C(:));                    % C类最大积压
solE.queue_stats.B_B_avg  = mean(solE.B_B(:));                   % B类平均队长
solE.queue_stats.B_C_avg  = mean(solE.B_C(:));                   % C类平均队长
solE.queue_stats.nonzero_frac_B = mean(solE.B_B(:) > 1e-3);      % B类非空队列时段比例
solE.queue_stats.nonzero_frac_C = mean(solE.B_C(:) > 1e-3);      % C类非空队列时段比例
% Little定律等待时间(h)：L/λ，验证不超过SLA延期上限d_max
lam_B_avg = max(1e-6, mean(sum(solE.S_B,1)));
lam_C_avg = max(1e-6, mean(sum(solE.S_C,1)));
solE.queue_stats.wait_B_h = solE.queue_stats.B_B_avg * NJ / lam_B_avg;
solE.queue_stats.wait_C_h = solE.queue_stats.B_C_avg * NJ / lam_C_avg;
end
