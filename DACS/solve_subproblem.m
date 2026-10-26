%% =========================================================================
%  solve_subproblem.m  —  DACS子问题主入口 (完整三层算法)
%  
%  输入: x_sol(规划方案), AEMF(情景), P(参数), mu_in(初始乘子), precision(精度)
%  输出: Q_s(规划期累计运营净成本, 万元), mu_out, info
%  
%  实现:
%    1. LR-DW对偶松弛迭代(论文式31-33)
%    2. 西部三模式套利(式14-19)
%    3. 东部前向后向DP(式20-27)
%    4. C类最小成本流(式28-30)
%  
%  单位: Q_s输出为20年规划期累计运营净成本(万元)
%        子问题模拟168h典型周, 通过P.T_planning(=608)放大到20年累计
%% =========================================================================
function [Q_s, mu_out, info] = solve_subproblem(x_sol, scen_s, P, SKU, mu_in, precision)
% 线性化运行子问题(LP, 精确对偶割, Benders可收敛) —— 默认; 设 P.recourse_lp=false 回到原启发式子问题
if ~isfield(P,'recourse_lp') || P.recourse_lp
    if isfield(P,'lp_engine') && strcmpi(P.lp_engine,'yalmip')
        [Q_s, mu_out, info] = solve_subproblem_lp(x_sol, scen_s, P, SKU);
    else
        [Q_s, mu_out, info] = solve_subproblem_lp_fast(x_sol, scen_s, P, SKU);   % 稀疏直接建模(默认)
    end
    return;
end

NI = P.N_west; NJ = P.N_east; T = P.T;
if nargin < 6; precision = 'high'; end
% η口径统一(规划侧): 定价已按η_y传导折价, token↔MW换算必须同用η_y
if isfield(SKU,'eta_token') && ~isempty(SKU.eta_token); P.eta_token = SKU.eta_token; end

% T_planning: 168h典型周→年度(×52周), 使Q代表年度运营净成本
% 与dQ(年度尺度 mu×8760×0.05)和F1/T_life(年化投资)统一, 避免数值病态
T_planning = 52;   % 周→年(不再×20年寿命, Benders用年度尺度)

% 空方案保护
if all(x_sol.W_T <= 0.1) && all(x_sol.W_I <= 0.1)
    Q_s = 1e6;
    mu_out = struct('train',zeros(NI,T),'renew',zeros(NI,T),'stor',zeros(NI,T));
    info = struct('precision',precision,'time',0,'r_viol',1,...
        'mode_freq',[0,0,1],'migr_rate',0,'mu_train_out',zeros(NI,T));
    return;
end

if isempty(mu_in)
    mu_in = struct('train',zeros(NI,T),'renew',zeros(NI,T),'stor',zeros(NI,T));
end
mu = mu_in;
tic_sub = tic;

% 精度→LR迭代轮次
switch precision
    case 'high'; n_lr = P.n_LR_high;
    case 'mid';  n_lr = P.n_LR_mid;
    case 'low';  n_lr = P.n_LR_low;
end

%% ── LR-DW对偶松弛主循环 (式31-33) ──────────────────────────────────────
Q_best = Inf;
UB_sub = Inf;   % 子问题原始上界(用于Polyak步长)
LB_sub = -Inf;  % 子问题对偶下界
mu_best      = mu_in;   % 使原始Q最小的μ（用于UB计算）
mu_dual_best = mu_in;   % 使对偶Q_lr最大的μ（用于VAIC割次梯度，更紧）
Q_lr_max     = -Inf;    % 记录最大Q_lr（对偶函数峰值）
solW_best = []; solE_best = []; solR_best = [];

for lr_k = 1:n_lr
    % HVDC总容量：每个西部节点i到所有东部节点j的总容量之和
    dL_per_west = zeros(NI, 1);
    dL_mat = x_sol.dL;
    if ~isequal(size(dL_mat), [NI, P.N_east])
        dL_mat = zeros(NI, P.N_east);  % 维度不符时重置
    end
    for i = 1:NI
        % 所有东部方向容量之和 = P.HVDC_cap(i,:) + dL(i,:)
        dL_per_west(i) = sum(P.HVDC_cap_per_node(i,:)) + sum(dL_mat(i,:));
    end
    
    [solW, QW] = subproblem_DACS_west(x_sol, scen_s, mu, P, SKU, NI, T, dL_per_west);
    
    % HVDC接收量按东部各节点负荷比例分配（而非均分）
    P_hvdc_total = sum(solW.P_hvdc_out, 1);   % 1×T
    % 各节点负荷权重（用P.east_B_share，不再硬编码）
    Lambda_j_sum = zeros(NJ, 1);
    for j = 1:NJ
        b_s = P.east_B_share(min(j, length(P.east_B_share)));
        Lambda_j_sum(j) = max(1, mean(scen_s.Lambda_B) * b_s * NJ);
    end
    w_j = Lambda_j_sum / sum(Lambda_j_sum);   % 归一化权重
    hvdc_recv_per_j = zeros(NJ, T);
    for j = 1:NJ
        hvdc_recv_per_j(j, :) = P_hvdc_total * w_j(j);  % 按负荷比分配
    end
    
    [solE, QE] = subproblem_DACS_east(x_sol, scen_s, P, SKU, NJ, T, hvdc_recv_per_j);
    [solR, QR] = solve_minimum_cost_flow(solW, solE, scen_s, x_sol, P, SKU, NI, NJ, T);
    QE_corr    = update_QE_after_migration(solE, solR, scen_s, P, NJ, T, SKU);
    
    Q_lr = QW + QE_corr + QR;

    % 原始最优μ（使Q最低，用于UB计算）
    % 原始可行解 = 不含Lagrange惩罚项的实际运营成本
    QW_p = QW; if isfield(solW,'QW_primal'); QW_p = solW.QW_primal; end
    Q_primal = QW_p + QE_corr + QR;   % 原始运营成本(不含拉格朗日罚项)
    if lr_k == 1
        UB_sub = Q_primal;   % 第一轮即为原始可行上界
    else
        UB_sub = min(UB_sub, Q_primal);   % 保持最好的原始上界
    end

    if Q_primal < Q_best
        Q_best = Q_primal;
        mu_best  = mu;
        solW_best = solW; solE_best = solE; solR_best = solR;
    end
    % 对偶最优μ（使Q_lr最大，对应最紧Lagrangian下界，用于VAIC割次梯度）
    if Q_lr > Q_lr_max
        Q_lr_max     = Q_lr;
        mu_dual_best = mu;
    end
    
    LB_sub = max(LB_sub, Q_lr);

    % 执行mu更新（n_lr=1时也做一次，保证mu_dual_best不是零初值）
    try
        mu_next = lagrange_update(mu, solW, x_sol, scen_s, solE.r_viol, lr_k, P, UB_sub, LB_sub);
    catch ME_lr
        if contains(ME_lr.message,'输入参数') || contains(ME_lr.message,'input')
            mu_next = lagrange_update(mu, solW, x_sol, scen_s, solE.r_viol, lr_k, P);
        else
            mu_next = mu;
        end
    end
    % 用更新后的mu对应的对偶值作为候选（而非更新前的零初值）
    if Q_lr > Q_lr_max
        Q_lr_max     = Q_lr;
        mu_dual_best = mu_next;
    end

    if lr_k < n_lr
        mu = mu_next;
    end
end

% 规划期累计(168h周 → 年度)
Q_s = Q_best * T_planning;

mu_out      = mu_dual_best;   % 对偶最优μ(使Q_lr最大), 传给VAIC割次梯度更精准
info.mu_primal = mu_best;     % 原始最优μ(使Q最小), 保留供记录
info.precision = precision;
info.time = toc(tic_sub);
info.r_viol = solE_best.r_viol;
info.mode_freq = solW_best.mode_freq;
info.migr_rate = solR_best.migr_rate;
info.mu_train_out = mu_best.train;
info.Q_west = QW * T_planning;
if exist('solW_best','var') && isfield(solW_best,'QW_primal'); info.Q_west = solW_best.QW_primal * T_planning; end
info.Q_east = QE_corr * T_planning;
info.Q_route = QR * T_planning;
if exist('solE_best','var') && isfield(solE_best,'dbg'); info.east_dbg = solE_best.dbg * T_planning; end
end


%% ── MCF修正后的QE子函数 ────────────────────────────────────────────────
function QE_corr = update_QE_after_migration(solE, solR, scen_s, P, NJ, T, SKU)
% MCF迁出量影响东部C类积压, 重新计算SLA惩罚 + 迁移服务费转移支付
eta_PUE_avg = mean(P.eta_PUE_east);
Lambda_C_tok = scen_s.Lambda_C * P.eta_token / eta_PUE_avg;   % 转百万tokens
% Λ_C(t) 已经在solE生成时是百万tokens单位

QE_corr = solE.QE_base;
% ②违约成本修正符号反转(QE_corr + C_old − C_new, 积压越大反而越"盈利")
shC = ones(1,NJ)/NJ; if isfield(P,'east_C_share'); shC = P.east_C_share / sum(P.east_C_share); end
for j = 1:NJ
    B_C_new = solE.B_C(j, :);
    B_thr_C = P.B_thresh_C_ratio * scen_s.mean_C * P.eta_token / eta_PUE_avg * shC(j);
    
    for t = 1:T
        W_out = sum(solR.W_route(j, :, t));
        if t < T
            B_C_new(t+1) = max(0, B_C_new(t) + scen_s.Lambda_C(t) ...
                * P.eta_token / eta_PUE_avg * shC(j) - solE.S_C(j,t) - W_out);
        end
    end

    % ── 迁移服务费转移支付（消除系统级重复计算）─────────────────────
    % 西部Q_W已计入 p_B×f_migrate 承接收益；东部作为发起方须支付同额
    % 服务费。系统净效应 = 电价差套利 - 通信费(MCF的QR已核算)，
    % 转移支付使东西部节点级账目各自正确、系统级不重复。
    if nargin >= 7 && isfield(SKU,'p_B')
        f_out_j = sum(sum(solR.f_migrate(j,:,:)));   % j节点周内总外迁(百万tokens)
        p_B_j = SKU.p_B(min(j, length(SKU.p_B)));
        QE_corr = QE_corr + p_B_j * f_out_j * 0.1;   % 东部支付服务费(成本↑)
    end
    
    C_old = P.pi_C_viol/10000 * sum(max(0, solE.B_C(j,1:T) - B_thr_C));
    C_new = P.pi_C_viol/10000 * sum(max(0, B_C_new(1:T) - B_thr_C));
    QE_corr = QE_corr - C_old + C_new;   % Q为成本: 以迁移后违约成本替换迁移前
end
end
