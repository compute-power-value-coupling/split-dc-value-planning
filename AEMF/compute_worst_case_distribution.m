%% =========================================================================
%  compute_worst_case_distribution.m  —  DRO最坏分布求解
%  
%  对应论文式(4): max_{P ∈ B_total} E_P[Q(x,ξ)]
%  
%  在嵌套模糊集B_total内寻找使期望运营成本最大(最坏)的情景概率分布P。
%  这是分布鲁棒优化(DRO)的核心——区别于普通随机规划(SP)用固定名义概率。
%  
%  模糊集约束(论文式1-3的离散对应):
%    - Wasserstein球(充裕维度): P与名义分布pi_nominal的概率距离 <= epsilon_1
%      离散情景下用L1范数(总变差)近似: sum|P_s - pi_s| <= 2*epsilon_1
%    - 矩约束(稀疏维度): 加权均值落在矩区间内(通过情景特征隐式满足)
%  
%  求解: L1约束下的线性规划, 等价于"将概率从低成本情景转移到高成本情景"
%        的贪心最优(网络流式), 转移总量受Wasserstein半径预算约束。
%  
%  输入:
%    Q_scen      - 各情景运营成本向量 (N_s×1, 万元, 负值=收益)
%    pi_nominal  - 名义概率分布 (N_s×1, 和为1)
%    epsilon_1   - Wasserstein球半径(AEMF式2)
%    scen_feat   - (可选)情景特征, 用于矩约束检验
%  输出:
%    P_worst     - 最坏分布 (N_s×1)
%    Q_worst     - 最坏期望成本 = sum(P_worst .* Q_scen)
%% =========================================================================
function [P_worst, Q_worst] = compute_worst_case_distribution(Q_scen, pi_nominal, epsilon_1, scen_feat)
%% LP求解Wasserstein球内真正最坏分布(论文式4)
% 本代码使用 W_1(p, π) ≤ ε 的离散近似: Σ_s |p_s - π_s| ≤ 2ε (总变差TV距离)
% TV距离 = W_1/2 在离散分布上等价。论文若声称W_2，需将约束改为
%   Σ_{s,t} transport(s,t) × d(s,t)^2 ≤ ε^2 （需额外引入transport变量）
% 当前LP形式对应W_1，计算更高效，请在论文中明确声明"W_1 Wasserstein球"
%
%  max  Σ_s p_s × Q_s
%  s.t. Σ_s p_s = 1              (概率归一化)
%       p_s ≥ 0
%       Σ_s |p_s - π_s| ≤ 2ε    (L1 Wasserstein近似)
%       μ_lb ≤ Σ_s p_s×feat_s ≤ μ_ub   (矩约束, 论文式3)
%
%  线性化|p-π|: 引入辅助变量 d_s ≥ |p_s-π_s|
%  LP变量: x = [p_1...p_N, d_1...d_N] (2N维)

N_s = length(Q_scen);
Q_scen     = Q_scen(:);
pi_nominal = pi_nominal(:);

% ── LP目标: min -Q'p (linprog最小化) ─────────────────────────────
f_obj = [-Q_scen; zeros(N_s,1)];   % [−Q; 0]

% ── 等式约束: Σp_s = 1 ───────────────────────────────────────────
Aeq = [ones(1,N_s), zeros(1,N_s)];
beq = 1;

% ── 不等式约束 ───────────────────────────────────────────────────
% (1) p_s - d_s ≤ π_s   → d_s ≥ p_s - π_s
A1 = [eye(N_s), -eye(N_s)];
b1 = pi_nominal;
% (2) -p_s - d_s ≤ -π_s  → d_s ≥ π_s - p_s
A2 = [-eye(N_s), -eye(N_s)];
b2 = -pi_nominal;
% (3) Σd_s ≤ 2ε  (Wasserstein半径预算)
A3 = [zeros(1,N_s), ones(1,N_s)];
b3 = 2 * epsilon_1;

A_ineq = [A1; A2; A3];
b_ineq = [b1; b2; b3];

% ── 矩约束(论文式3, 若提供特征) ──────────────────────────────────
if nargin >= 4 && ~isempty(scen_feat)
    feat = scen_feat(:);
    feat_mean = sum(pi_nominal .* feat);
    feat_std  = max(std(feat), 1e-6);
    % 矩区间: [μ-2σ, μ+2σ]
    A_ineq = [A_ineq;
              [feat',  zeros(1,N_s)];   % Σp×feat ≤ μ+2σ
              [-feat', zeros(1,N_s)]];  % -Σp×feat ≤ -(μ-2σ)
    b_ineq = [b_ineq;
              feat_mean + 2*feat_std;
              -(feat_mean - 2*feat_std)];
end

% ── 变量界: p∈[0,1], d∈[0,1] ────────────────────────────────────
lb = zeros(2*N_s, 1);
ub = ones(2*N_s, 1);

% ── LP求解 ───────────────────────────────────────────────────────
opts = optimoptions('linprog','Display','off','Algorithm','dual-simplex');
try
    [x_opt, ~, exitflag] = linprog(f_obj, A_ineq, b_ineq, Aeq, beq, lb, ub, opts);
catch
    exitflag = -1;
end

if exitflag > 0 && ~isempty(x_opt)
    P_worst = max(0, x_opt(1:N_s));
    P_worst = P_worst / sum(P_worst);
else
    % LP失败退化为贪心(保证可行)
    P_worst = pi_nominal;
    budget  = min(0.5, 2*epsilon_1);
    [~, idx_asc] = sort(Q_scen,'ascend');
    remaining = budget; lo = 1; hi = N_s;
    while remaining > 1e-9 && lo < hi
        s_lo = idx_asc(lo); s_hi = idx_asc(hi);
        t = min([remaining, P_worst(s_lo)]);
        if t <= 1e-12; lo = lo+1; hi = hi-1; continue; end
        P_worst(s_lo) = P_worst(s_lo) - t;
        P_worst(s_hi) = P_worst(s_hi) + t;
        remaining = remaining - t;
        if P_worst(s_lo) <= 1e-9; lo = lo+1; end
    end
    P_worst = max(0,P_worst)/sum(P_worst);
end

Q_worst = sum(P_worst .* Q_scen);
end
