%% =========================================================================
%  subproblem_DACS_west.m  —  西部L_W子问题(三模式套利+储能+HVDC外送)
%  对应论文式(14-19)
%  
%  输入:
%    x_sol: 规划方案(z, W_T, G, E_w, dL)
%    scen_s: 单情景时序(lam_w(t), CF_renew(i,t), lam_token(t))
%    mu: 拉格朗日乘子(train, renew, stor)
%    P, SKU: 参数
%    dL_per_west: 各西部节点可用HVDC容量(NI×1, MW), 包含原有+扩容
%  输出:
%    solW: 西部运行解(P_train, P_renew, P_grid, P_ch, P_dis, E_soc, T_gen, P_hvdc_out)
%    QW: 西部净成本(万元, 168h累计)
%% =========================================================================
function [solW, QW] = subproblem_DACS_west(x_sol, scen_s, mu, P, SKU, NI, T, dL_per_west)

if nargin < 8 || isempty(dL_per_west)
    dL_per_west = zeros(NI, 1);   % 无HVDC容量（兼容旧接口）
end

solW = struct();
solW.P_train = zeros(NI, T);
solW.P_renew = zeros(NI, T);
solW.P_curt  = zeros(NI, T);
solW.P_grid  = zeros(NI, T);
solW.P_ch    = zeros(NI, T);
solW.P_dis   = zeros(NI, T);
solW.T_gen   = zeros(NI, T);
solW.E_soc   = zeros(NI, T+1);
solW.mode    = zeros(NI, T);   % 1=弃电 2=购电 3=降载
solW.mu_train_out = zeros(NI, T);
solW.mu_renew_out = zeros(NI, T);
solW.P_hvdc_out = zeros(NI, T);   % HVDC外送功率(新增, 真正功率平衡)

QW = 0;
QW_pri = 0;   % 原始运营成本(不含拉格朗日罚项μ·g, 用于Benders割值与UB)
mode_cnt = zeros(3, 1);

for i = 1:NI
    if x_sol.W_T(i) < 1; continue; end
    eta_i = P.eta_PUE_west(i);
    del_i = P.delta_comm(i);
    Wi    = x_sol.W_T(i);
    Gi    = x_sol.G(i);
    Ei    = x_sol.E_w(i);
    Pc_min = P.W_contract_D(i) / eta_i;
    
    % 初始SOC: 优先用历史均值（反映前一年末的真实状态），否则取50%
    % 根据P.SOC_min和SOC_max约束初始值
    if isfield(scen_s,'soc_init') && length(scen_s.soc_init) >= i && scen_s.soc_init(i) > 0
        soc0_frac = max(P.SOC_min_ratio, min(P.SOC_max_ratio, scen_s.soc_init(i)));
    else
        soc0_frac = 0.50;   % 缺省中位值
    end
    solW.E_soc(i, 1) = soc0_frac * Ei;
    
    for t = 1:T
        % 原bug：lam_tok=P.lambda_token_base×噪声(3.145固定15年)→
        %   ①与SKU.p_T年度演化脱钩(SKU定价体系未驱动运营收益)
        %   ②收益密度10倍虚高(13104元/MWh, 正确约1292元/MWh)
        %   ③eta用P.eta_token固定值, Huang年度演化未进运营层
        % 单位：p_T[元/千tok]×0.1 = [万元/百万tok]  (0.31元/千tok→0.031万元/百万tok)
        p_T_i   = SKU.p_T(min(i, length(SKU.p_T)));
        tok_shape = scen_s.lam_token(t) / max(1e-6, mean(scen_s.lam_token));
        lam_tok_wan = p_T_i * 0.1 * tok_shape;    % 万元/百万tokens
        eta_tok_y   = SKU.eta_token;              % 本年效率(Huang分段演化)
        lam_w   = scen_s.lam_w(i, t);     % 该节点电价(情景基准)
        % ── 节点电价响应(线性化LMP阻塞效应)──────────────────────────
        % 数据中心购电增加→本地节点电价上浮，套利自我收敛
        if isfield(P,'enable_price_response') && P.enable_price_response
            P_net_prev = 0;
            if t > 1
                P_net_prev = solW.P_grid(i, t-1);  % 用上一时段购电量近似(避免循环依赖)
            end
            lam_w = lam_w * (1 + P.price_sens_west * P_net_prev / P.price_base_load_w);
        end
        CF_it   = scen_s.CF_renew(i, t);
        Pr_avail = Gi * CF_it;
        SOC_i  = solW.E_soc(i, t);
        
        % 单步系数(万元/MW/h)：SKU价×年度效率，价值耦合正确单位
        coef_rev = lam_tok_wan * eta_tok_y * del_i / eta_i;   % 训练收益密度
        coef_elec = lam_w / 10000;                                  % 电力成本密度
        pi_t = coef_rev - coef_elec;                                % 套利信号
        
        % ── 三模式决策(式17, 严格互斥) ─────────────────────────────
        % 即使绿电不能完全覆盖合同, 只要超过一半就以"绿电优先+电网兜底"运行

        % ── 消融M5：w/o 三模式柔性 → 强制固定购电模式 ─────────────────
        % 训练负荷=合同刚性值，绿电仅被动消纳，无弃电充储/无降载调节
        if isfield(P,'ablation') && strcmp(P.ablation,'M5')
            Pt = Pc_min;                       % 训练负荷固定为合同值
            Pr = min(Pr_avail, Pt);            % 绿电被动消纳
            Pg = max(0, Pt - Pr);              % 缺口全部购电
            Pc = max(0, Pr_avail - Pr);        % 多余绿电全部弃掉（无充储调节）
            P_dis_t = 0; P_ch_t = 0;
            mode_t = 2;                        % 记为购电模式
            solW.P_train(i,t)=Pt; solW.P_renew(i,t)=Pr;
            solW.P_grid(i,t)=Pg;  solW.P_curt(i,t)=Pc;
            solW.P_ch(i,t)=0;     solW.P_dis(i,t)=0;
            solW.E_soc(i,t)=SOC_i;
            mode_cnt(mode_t) = mode_cnt(mode_t)+1;
            T_gen_t = Pt * SKU.eta_token / P.eta_PUE_west(i);
            solW.T_gen(i,t) = T_gen_t;
            continue;   % 跳过三模式选择
        end

        if pi_t > 0 && Pr_avail >= 0.5 * Pc_min
            % 弃电模式: 优先消纳绿电
            % 训练负载在Wi上界与Pr_avail+合同保障之间取大者
            Pt = max(Pc_min, min(Wi, Pr_avail));   % 至少满足合同, 最多用满绿电
            Pr = min(Pr_avail, Pt);                  % 绿电消纳
            Pg = max(0, Pt - Pr);                    % 缺口由电网补
            Pc = max(0, Pr_avail - Pr);              % 多余绿电=弃电(若Pr_avail>Wi)
            P_dis_t = 0;
            P_ch_t  = 0;
            % 若绿电仍有多余, 优先充储能而非弃电
            if Pc > 0.1 && SOC_i < P.SOC_max_ratio*Ei
                P_ch_t = min(Pc, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_i));
                Pc = Pc - P_ch_t;
            end
            mode_t = 1;
            % HVDC外送: 储能充满后剩余弃电 + 东西电价差套利(弃电时段收益最高)
            HVDC_cap_i = dL_per_west(i);
            if Pc > 0.01 && HVDC_cap_i > 0.1
                P_hvdc_i_t = min(Pc, HVDC_cap_i);
                solW.P_hvdc_out(i, t) = P_hvdc_i_t;
                Pc = Pc - P_hvdc_i_t;
            end
            % ── μ条件绑定（诚实的运行→规划边际价值反馈）─────────────────
            % 原bug：模式1无条件μ=coef_rev → 容量未绑紧时也给VAIC虚假扩容信号
            % 现货饱和检测: 富裕token已达市场吸纳上限→额外产能无收益
            sat_spot = false;
            if isfield(SKU,'spot_cap_tok_h')
                Tg_sur_now = eta_tok_y * (max(0,Pt-Pc_min)/eta_i) * del_i;
                sat_spot = (Tg_sur_now >= SKU.spot_cap_tok_h - 1e-6);
            end
            if (Wi - Pt) < 0.5 && ~sat_spot
                mu_new = coef_rev;          % 容量瓶颈且市场未饱和：全额边际价值
            else
                mu_new = 0;                 % 绿电受限/市场饱和：扩容无边际价值
            end
            if Pc < 0.01 && ~sat_spot
                mu_renew_new = coef_rev;    % 绿电全消纳且可售：扩G增产有价值
            else
                mu_renew_new = 0;
            end
        elseif pi_t > 0 && Pr_avail < 0.5 * Pc_min
            % 购电模式: 绿电严重不足, 电网补差
            Pt = min(Wi, max(Pc_min, Pr_avail*1.3));
            Pr = Pr_avail;
            Pg = max(0, Pt - Pr);
            Pc = 0;
            % 储能放电: 当电价高于阈值时优先放电替代购电(套利核心)
            % 深度放电保护: SOC须保持高于SOC_min(10%保护区间)
            SOC_min_i = P.SOC_min_ratio * Ei;
            dis_avail = max(0, (SOC_i - SOC_min_i) * P.eta_dis);  % 可放电量
            lam_w_threshold = mean(scen_s.lam_w(i,:)) * 1.10;     % 高于均价10%则放电
            if lam_w > lam_w_threshold && dis_avail > 0.01 && Pg > 0.01
                P_dis_t = min(dis_avail, Pg);   % 最多放到满足Pg需求
                Pg = max(0, Pg - P_dis_t);       % 购电减少
                P_ch_t = 0;                       % 放电时不同时充电
            else
                P_dis_t = 0;
                P_ch_t = max(0, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_i));
            end
            mode_t = 2;
            % HVDC套利
            lam_e_avg_mode = mean(scen_s.lam_e(:));
            c_hvdc_op = P.c_hvdc_op;
            east_infer_demand = sum(x_sol.W_I) * 0.70 / P.N_west;
            HVDC_cap_i = dL_per_west(i);
            if HVDC_cap_i > 0.1 && (lam_e_avg_mode - lam_w - c_hvdc_op) > 10 ...
                    && isfield(P,'hvdc_arbitrage') && P.hvdc_arbitrage
                P_hvdc_i_t = min(HVDC_cap_i, east_infer_demand);
                solW.P_hvdc_out(i, t) = P_hvdc_i_t;
            end
            mu_new = max(0, coef_rev - coef_elec);
            mu_renew_new = coef_elec;
        else
            % 降载模式: 按任务等级分级降载(D类训练优先降, A/B刚性保留)
            % 论文SLA分级: A类绝对实时不可降, B类轻微弹性, C类批量可降, D类可中断
            % 降载顺序: 先降D类训练(Pc_min以上部分), 再降C类批量
            Pt_max = min(Wi, max(Pc_min, Pr_avail));   % 绿电能支撑的最高功率
            Pt = Pt_max;   % 降载模式下维持绿电能覆盖的功率
            Pr = min(Pr_avail, Pt);
            Pg = max(0, Pt - Pr);
            Pc = 0;
            % 储能补充: 若SOC充足可延伸训练功率(减少降载损失)
            SOC_min_i = P.SOC_min_ratio * Ei;
            dis_avail = max(0, (SOC_i - SOC_min_i) * P.eta_dis);
            if dis_avail > 0.01 && Pt < Pc_min
                % 放电补足合同功率(优先保障D类合同不违约)
                P_dis_t = min(dis_avail, Pc_min - Pt);
                Pt = Pt + P_dis_t;
                P_ch_t = 0;
            else
                P_dis_t = 0;
                P_ch_t = max(0, min(P.ch_rate*Ei, P.SOC_max_ratio*Ei - SOC_i));
            end
            mode_t = 3;
            mu_new = 0;
            mu_renew_new = 0;
        end
        
        % 储能状态转移(式18)
        SOC_next = SOC_i*(1-P.sigma_stor) + P.eta_ch*P_ch_t - P_dis_t/P.eta_dis;
        solW.E_soc(i, t+1) = max(P.SOC_min_ratio*Ei, min(P.SOC_max_ratio*Ei, SOC_next));
        
        % Token生产(式15)：使用年度效率(Huang分段演化)
        Tg = eta_tok_y * (Pt/eta_i) * del_i;   % 百万tokens/h
        
        % 记录
        solW.P_train(i,t) = Pt;
        solW.P_renew(i,t) = Pr;
        solW.P_curt(i,t)  = Pc;
        solW.P_grid(i,t)  = Pg;
        solW.P_ch(i,t)    = P_ch_t;
        solW.P_dis(i,t)   = P_dis_t;
        solW.T_gen(i,t)   = Tg;
        solW.mode(i,t)    = mode_t;
        solW.mu_train_out(i,t) = mu_new;
        solW.mu_renew_out(i,t) = mu_renew_new;   % 新增:扩G的边际价值
        mode_cnt(mode_t) = mode_cnt(mode_t) + 1;
        
        % ── 目标函数贡献(万元)(式19)：分层token定价 ─────────────────────
        % 合同部分(≤Pc_min)按SKU长约价p_T全价；富裕绿电驱动的额外部分
        % (Pt−Pc_min)为机会型算力，按现货折扣价(可抢占实例市场惯例35%折让)
        % → "大量无成本收益"保留但不再按合同价虚估
        spot_disc = 0.65;
        if isfield(P,'spot_token_discount'); spot_disc = P.spot_token_discount; end
        Pt_contract = min(Pt, Pc_min);
        Pt_surplus  = max(0, Pt - Pc_min);
        Tg_contract = eta_tok_y * (Pt_contract/eta_i) * del_i;
        Tg_surplus  = eta_tok_y * (Pt_surplus /eta_i) * del_i;
        spot_cap_h = inf;
        if isfield(SKU,'spot_cap_tok_h'); spot_cap_h = SKU.spot_cap_tok_h; end
        Tg_surplus_sold = min(Tg_surplus, spot_cap_h);
        rev_wan  = lam_tok_wan * (Tg_contract + spot_disc * Tg_surplus_sold);
        elec_wan = lam_w/10000 * Pg;
        curt_wan = P.C_curt_op/10000 * Pc;
        stor_wan = P.C_stor_op/10000 * (P_ch_t + P_dis_t);
        % HVDC外送收益: 外送电量 × (东部平均电价 - 西部电价 - 输电损耗成本)
        lam_e_avg_hvdc = mean(scen_s.lam_e(:));
        c_hvdc_unit = P.c_hvdc_op;   % 输电成本(元/MWh, 含损耗+运维)
        hvdc_rev_wan = max(0, lam_e_avg_hvdc - lam_w - c_hvdc_unit) / 10000 ...
                       * solW.P_hvdc_out(i, t);
        % 绿证(GEC)收益：按实际绿电发电量计算（促进绿色算力商业可行性）
        green_gen_t  = CF_it * Gi;   % 本时步绿电发电量(MWh/h per MW)，CF_it已在上方定义
        rev_gec_wan  = green_gen_t * P.lambda_GEC * P.GEC_fraction / 10000;

        profit_wan = rev_wan - elec_wan - curt_wan - stor_wan + hvdc_rev_wan + rev_gec_wan;

        % D类训练降载违约惩罚（mode=3时若Pt<Pc_min则触发合同惩罚）
        if mode_t == 3 && isfield(P,'pi_D_curtail')
            pen_curtail = P.pi_D_curtail * max(0, Pc_min - Pt);  % 万元/h
        else
            pen_curtail = 0;
        end
        
        % Lagrangian项(正确形式: μ × (实际值 - 容量值))
        pen_wan = mu.train(i,t)*(Pt - Wi) + ...
                  mu.renew(i,t)*(Pr - Pr_avail) + ...
                  mu.stor(i,t)*(SOC_i - Ei);
        
        QW = QW - profit_wan + pen_wan + pen_curtail;
        QW_pri = QW_pri - profit_wan + pen_curtail;
        solW.QW_primal = QW_pri;
    end
end

total_cnt = sum(mode_cnt);
if total_cnt > 0
    solW.mode_freq = mode_cnt' / total_cnt;
else
    solW.mode_freq = [0.33, 0.33, 0.34];
end
end
