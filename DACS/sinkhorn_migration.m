function [plan, sk_info] = sinkhorn_migration(supply_j, capacity_i, cost_ji, P)
%% Sinkhorn-OT — 熵正则化最优传输求解C类任务东→西迁移(本文空间耦合核心)
%
%  ── 数学地位(跨学科迁移: ML/数学→电力规划) ───────────────────────────
%  C类迁移的本质 = Monge-Kantorovich最优传输: 把需求质量μ(东部积压+到达)
%  以最小代价运输到供给容量ν(西部空闲算力)。Sinkhorn算法(Cuturi 2013,
%  熵正则OT, ML界标准解法)通过交替行列缩放求解:
%     min_T <T,C> + ε·H(T)   s.t. T·1=μ, Tᵀ·1=ν
%  收敛保证: Sinkhorn定理(矩阵缩放不动点), 线性收敛率。
%
%  ── 相对原方法的严格支配关系 ─────────────────────────────────────────
%  原贪婪排序: 逐对分配, 无全局最优性; GAT-Route行softmax恰为Sinkhorn
%  的半步(只满足行约束); 完整Sinkhorn补上列约束(容量可行性内生满足),
%  且ε→0时收敛到精确OT(即全局最优运输), ε>0给出探索性软路由。
%
%  输入:  supply_j (NJ×1)   东部各源可迁移量(百万tok)
%         capacity_i(NI×1)  西部各汇承接容量(百万tok)
%         cost_ji  (NJ×NI)  单位运输代价(万元/百万tok, inf=不可达)
%  输出:  plan(NJ×NI) 最优运输计划(百万tok); sk_info 诊断

NJ = numel(supply_j); NI = numel(capacity_i);
eps_reg = 0.05; if isfield(P,'sinkhorn_eps');   eps_reg = P.sinkhorn_eps; end
n_iter  = 60;   if isfield(P,'sinkhorn_iters'); n_iter  = P.sinkhorn_iters; end

mu = max(supply_j(:), 0);  nu = max(capacity_i(:), 0);
M_mu = sum(mu); M_nu = sum(nu);
plan = zeros(NJ, NI);
sk_info = struct('iters',0,'mass',0,'converged',false);
if M_mu < 1e-9 || M_nu < 1e-9; return; end

% 平衡化: 可运输总质量 = min(供,需); 归一为概率测度
mass = min(M_mu, M_nu);
a = mu / M_mu;  b = nu / M_nu;

% Gibbs核(不可达边cost=inf→K=0自动屏蔽)
C = cost_ji;  C(~isfinite(C)) = 1e6;
C = C - min(C(:));                       % 平移不改变最优计划, 改善条件数
K = exp(-C / eps_reg);
K = max(K, 1e-300);

% Sinkhorn交替缩放(u←a./(K v), v←b./(Kᵀ u))
u = ones(NJ,1)/NJ;  v = ones(NI,1)/NI;
for it = 1:n_iter
    u_new = a ./ max(K * v, 1e-300);
    v_new = b ./ max(K' * u_new, 1e-300);
    delta = max(abs(u_new - u)) + max(abs(v_new - v));
    u = u_new; v = v_new;
    if delta < 1e-8; sk_info.converged = true; break; end
end
sk_info.iters = it;
sk_info.u = u;  sk_info.v = v;   % Kantorovich对偶缩放向量(势=ε·ln u)

% 传输计划(缩放回真实质量)
plan = diag(u) * K * diag(v) * mass;
plan = max(plan, 0);
sk_info.mass = sum(plan(:));
sk_info.transport_cost = sum(sum(plan .* min(C,1e5)));
% 计划熵(ε的探索效应度量, 可入论文)
p_n = plan / max(sum(plan(:)),1e-12);
sk_info.plan_entropy = -sum(p_n(p_n>0) .* log(p_n(p_n>0)));
end
