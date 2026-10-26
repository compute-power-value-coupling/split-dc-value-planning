%% =========================================================================
%  solve_minimum_cost_flow.m — C类MCF最小费用流 + LP对偶变量提取
%
%  对应论文式(31-32)东西部解耦子问题
%
%  LP形式:
%    min   Σ_{ij} c_{ij} × f_{ij}          (迁移费用最小化)
%    s.t.  Σ_j f_{ij} ≤ b_sup_i            (西部供给约束，对偶λ_sup)
%          Σ_i f_{ij} ≤ b_dem_j            (东部需求约束，对偶λ_dem)
%          f_{ij} ≥ 0                       (非负)
%          f_{ij} ≤ L_{ij}                  (通信时延可达约束)
%
%  对偶变量物理意义:
%    λ_sup(i) = 西部节点i增加1MW训练容量对MCF目标的边际改善 = μ_train真值
%    λ_dem(j) = 东部节点j增加1单位C类需求对MCF的边际影响
%% =========================================================================
function [solR, QR, dual_sup, dual_dem] = solve_minimum_cost_flow(solW, solE, scen_s, x_sol, P, SKU, NI, NJ, T)

solR.f_migrate   = zeros(NJ, NI, T);  % f_{ji,t}: j东部→i西部迁移量(百万tokens/h)
solR.Q_migrate   = zeros(NJ, NI, T);
solR.comm_delay  = zeros(NJ, NI);
solR.mu_sup      = zeros(NI, 1);      % 西部供给对偶变量（真正的Lagrange乘子）
solR.mu_dem      = zeros(NJ, 1);      % 东部需求对偶变量
solR.migr_rate   = 0;                 % C类迁移率（供solve_subproblem读取）
solR.W_route     = zeros(NJ, NI, T); % 兼容字段（路由功率矩阵）
QR = 0;
dual_sup = zeros(NI, 1);  % 全时段平均对偶变量（传给VAIC）
dual_dem = zeros(NJ, 1);

% ── 消融M4：w/o 跨域迁移 → 禁止C类东西迁移，验证算力空间柔性价值 ──────
if isfield(P,'ablation') && strcmp(P.ablation,'M4')
    solR.migr_rate = 0;
    return;   % 零迁移直接返回
end

n_var = NI * NJ * 2;   % 两段式：每条(j,i)边拆2段(价响应分段线性化)
idx  = @(j,i) (i-1)*NJ + j;              % 第1段变量索引
idx2 = @(j,i) NI*NJ + (i-1)*NJ + j;      % 第2段变量索引

% 预计算通信时延
D_mat = zeros(NJ, NI);
for j = 1:NJ
    for i = 1:NI
        if isfield(P,'comm_delay') && all(size(P.comm_delay) >= [NJ NI])
            D_mat(j,i) = P.comm_delay(j,i);
        else
            D_mat(j,i) = 20 + 5*(i+j);  % 默认时延（ms）
        end
    end
end

for t = 1:T
    lam_e = mean(scen_s.lam_e(:,t));
    lam_w = mean(scen_s.lam_w(:,t));
    % 紧迫度归一化基准：各东部节点C类需求量级(百万tokens/时段)
    b_dem_ref = zeros(NJ,1);
    for j2 = 1:NJ
        b_dem_ref(j2) = max(1, scen_s.Lambda_C(t) * P.eta_token ...
                        / P.eta_PUE_east(j2) / NJ * 3);  % 3时段积压为满紧迫
    end

    % ── LP费用向量（多因素两段式分段线性）─────────────────────────────
    % 迁移净收益的多因素构成（对应论文式26扩展）：
    %  ① 电价差套利：lam_e - lam_w_marginal
    %  ② 西部模式感知边际成本：弃电时段西部边际成本≈0(绿电本要弃掉)，
    %     购电时段=lam_w → 弃电时段迁移吸引力大幅提升(消纳价值)
    %  ③ 东部积压紧迫度溢价：B_C越接近SLA阈值，迁移避免违约的价值越高
    %  ④ 通信成本：随时延线性
    %  ⑤ 电价响应第2段：价差自我收敛(LMP线性化)
    c_vec = zeros(n_var, 1);
    pr_on = isfield(P,'enable_price_response') && P.enable_price_response;
    % 西部各节点该时段的弃电状态(模式感知边际成本)
    curt_frac = zeros(NI,1);
    if isfield(solW,'P_curt') && isfield(solW,'P_renew')
        for i2 = 1:NI
            tot_re = solW.P_renew(i2,t) + solW.P_curt(i2,t);
            if tot_re > 0.1
                curt_frac(i2) = solW.P_curt(i2,t) / tot_re;  % 弃电比例
            end
        end
    end
    % 东部各节点积压紧迫度(0~1)
    urg = zeros(NJ,1);
    if isfield(solE,'B_C')
        for j2 = 1:NJ
            B_ref = max(1, b_dem_ref(j2));
            urg(j2) = min(1, solE.B_C(j2,t) / B_ref);
        end
    end
    for i = 1:NI
        for j = 1:NJ
            c_comm_ij = (P.comm_cost_base + P.comm_cost_per_ms * D_mat(j,i)) ...
                        * P.eta_PUE_west(i) / (P.eta_token * P.delta_comm(i));   % 万元/百万token(原按万元/MWh直减)
            % ② 模式感知：弃电比例越高，西部边际电力成本越低
            lam_w_marg = lam_w * (1 - 0.85*curt_frac(i));
            % ③ 紧迫度溢价：积压压力折算为迁移额外价值(避免SLA违约)
            urg_premium = (P.pi_C_viol/10000/P.eta_token) * 0.3 * urg(j);
            net_benefit1 = (lam_e - lam_w_marg)/10000/P.eta_token ...
                         + urg_premium - c_comm_ij;
            if pr_on
                gap_shrink = (P.price_sens_west + P.price_sens_east) * 0.5;
                net_benefit2 = ((lam_e - lam_w_marg)*(1-gap_shrink))/10000/P.eta_token ...
                             + urg_premium - c_comm_ij;
            else
                net_benefit2 = net_benefit1;
            end
            c_vec(idx(j,i))  = -net_benefit1;
            c_vec(idx2(j,i)) = -net_benefit2;
        end
    end

    % ── 供给约束（西部节点i的可接收迁移量上限，两段求和）───────────────
    A_sup = zeros(NI, n_var);
    for i = 1:NI
        for j = 1:NJ
            A_sup(i, idx(j,i)) = 1; A_sup(i, idx2(j,i)) = 1;
        end
    end
    eta_PUE_avg_w = mean(P.eta_PUE_west);
    b_sup = max(0, x_sol.W_T(:) * P.P2_ratio - solW.P_train(:,t)) ...
            * P.eta_token ./ P.eta_PUE_west(:) .* P.delta_comm(:);   % 空闲算力→百万token(原MW/η)
    b_sup = max(0, b_sup);

    % ── 需求约束（东部节点j的C类积压需求上限，两段求和）───────────────
    A_dem = zeros(NJ, n_var);
    for j = 1:NJ
        for i = 1:NI
            A_dem(j, idx(j,i)) = 1; A_dem(j, idx2(j,i)) = 1;
        end
    end
    b_dem = zeros(NJ, 1);
    for j = 1:NJ
        eta_j = P.eta_PUE_east(j);
        b_dem(j) = max(0, solE.B_C(j, t)) ...
                 + scen_s.Lambda_C(t) * P.eta_token / eta_j / NJ;
    end

    % ── 通信时延可达约束（两段各占HVDC容量50%）──────────────────────
    lb = zeros(n_var, 1);
    ub = zeros(n_var, 1);
    for j = 1:NJ
        for i = 1:NI
            if D_mat(j,i) <= P.D_max_migrate
                if isequal(size(x_sol.dL), [NI, NJ])
                    hvdc_cap_ij = P.HVDC_cap_per_node(i,j) + x_sol.dL(i,j);
                else
                    hvdc_cap_ij = P.HVDC_cap_per_node(i,j);
                end
                % 任务经光纤迁移、在西部就地用电, 不占用HVDC(原以HVDC容量MW/η作上限, 量纲与物理均错)
                seg_cap = max(0, b_dem(j)) / 2 + hvdc_cap_ij * 0;
                ub(idx(j,i))  = seg_cap;   % 第1段：低价差成本
                ub(idx2(j,i)) = seg_cap;   % 第2段：收窄后成本
            else
                ub(idx(j,i)) = 0; ub(idx2(j,i)) = 0;
            end
        end
    end

    % ── LP求解（linprog，Dual-Simplex精确对偶）────────────────────────
    A_ineq = [A_sup; A_dem];
    b_ineq = [b_sup; b_dem];
    opts = optimoptions('linprog','Display','off','Algorithm','dual-simplex');
    [f_opt, fval, eflag, ~, lambda_lp] = linprog(c_vec, A_ineq, b_ineq, [], [], lb, ub, opts);

    if eflag > 0 && ~isempty(f_opt)
        % 提取真正的对偶变量（shadow price）
        if ~isempty(lambda_lp) && isfield(lambda_lp,'ineqlin') ...
                && length(lambda_lp.ineqlin) >= NI+NJ
            mu_sup_t = -lambda_lp.ineqlin(1:NI);       % 西部供给对偶
            mu_dem_t = -lambda_lp.ineqlin(NI+1:NI+NJ); % 东部需求对偶
            dual_sup = dual_sup + mu_sup_t / T;
            dual_dem = dual_dem + mu_dem_t / T;
        end
        % 填回迁移量（两段求和）
        total_flow_t = 0;
        for j = 1:NJ
            for i = 1:NI
                fij = max(0, f_opt(idx(j,i))) + max(0, f_opt(idx2(j,i)));
                solR.f_migrate(j,i,t) = fij;
                solR.W_route(j,i,t)   = fij;
                total_flow_t = total_flow_t + fij;
            end
        end
        QR = QR + fval;
    else
        % LP失败：退化为零迁移（保守策略）
        QR = QR + 0;
    end
end

% 传递真正的Lagrange乘子（供VAIC使用）
solR.mu_sup = dual_sup;
solR.mu_dem = dual_dem;

% 计算总迁移率（供solve_subproblem读取）
total_migration = sum(solR.f_migrate(:));
Lambda_C_cap    = sum(x_sol.W_T) * P.eta_token * P.task_ratio(3) * T;
solR.migr_rate  = min(0.95, total_migration / max(1, Lambda_C_cap));
end
