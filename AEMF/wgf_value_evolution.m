function [w_ev, wgf_info] = wgf_value_evolution(w_target, w_prev, P, AEMF)
%% WGF-JKO — 价值场年际演化的Wasserstein梯度流(本文时间耦合核心)
%
%  ── 数学地位(跨学科迁移: 最优传输/PDE→电力规划) ──────────────────────
%  价值场的年际演化 = 测度在Wasserstein空间中的梯度流。JKO格式
%  (Jordan-Kinderlehrer-Otto 1998, 扩散模型/采样理论的基石)给出:
%     ρ_{t+1} = argmin_ρ  E(ρ) + W₂²(ρ, ρ_t)/(2τ)
%  其奠基定理: 熵泛函的W₂梯度流 = 热方程。在图上的离散形式即
%  图拉普拉斯隐式热步:  w_ev = (I + τL)⁻¹ · w_blend
%  —— 一次PSD线性求解, 无条件稳定(隐式格式), 严格降Dirichlet能量。
%
%  ── 相对原方法(逐年独立重算)的升级 ───────────────────────────────────
%  原: 每年价值场独立重算, 无年际记忆、无空间平滑的原理性依据。
%  今: 惯性μ(年际记忆)+图热流(空间一致性)统一于一个JKO步;
%      步长τ由TempGraph阶跃强度调制——需求跃变年τ收小, 场获准跳变
%      (演化速度与环境非平稳性自适应耦合)。
%
%  输入:  w_target (NI×1) 本年新算局部价值; w_prev 上年演化后场
%  输出:  w_ev 演化后价值场; wgf_info 诊断(τ/μ/能量降)

NI = P.N_west;
w_target = w_target(:);
if nargin < 2 || isempty(w_prev) || numel(w_prev) ~= NI
    w_ev = w_target; wgf_info = struct('tau',0,'mu',0,'cold_start',true); return;
end
w_prev = w_prev(:);

% ── 1. 西-西图拉普拉斯(经东部枢纽介导的二跳相似度) ────────────────────
S = zeros(NI, NI);
for jj = 1:P.N_east
    r = zeros(NI,1);
    for ii = 1:NI
        Dji = P.comm_delay(P.east_hub_idx(jj), P.west_hub_idx(ii));
        r(ii) = exp(-Dji/15) * P.HVDC_cap_per_node(ii,jj) ...
                / max(1, sum(P.HVDC_cap_per_node(:,jj)));
    end
    S = S + r * r';                       % 共享东部需求源→价值相关
end
S = S - diag(diag(S));
d = sum(S,2); Dm = diag(max(d,1e-9));
L = eye(NI) - Dm^(-0.5) * S * Dm^(-0.5);  % 归一化图拉普拉斯(PSD)

% ── 2. 阶跃自适应步长与惯性 ───────────────────────────────────────────
step = 0; if isstruct(AEMF)&&isfield(AEMF,'step_intensity'); step=AEMF.step_intensity; end
tau0 = 0.6;  if isfield(P,'wgf_tau0');    tau0 = P.wgf_tau0;    end
mu0  = 0.30; if isfield(P,'wgf_inertia'); mu0  = P.wgf_inertia; end
tau = tau0 / (1 + 2*step);                % 跃变年→少平滑(允许场跳变)
mu  = mu0  / (1 + step);                  % 跃变年→少惯性(信任新观测)

% ── 3. JKO隐式热步: 记忆混合 + 图热流 ─────────────────────────────────
w_blend = (1-mu)*w_target + mu*w_prev;
w_ev = (eye(NI) + tau*L) \ w_blend;
w_ev = max(w_ev, 0.15*w_target);          % 正性保护

% ── 4. 诊断: Dirichlet能量降(梯度流的可验证签名) ─────────────────────
E0 = w_blend' * L * w_blend;
E1 = w_ev'    * L * w_ev;
wgf_info = struct('tau',tau,'mu',mu,'step',step, ...
                  'dirichlet_drop',(E0-E1)/max(E0,1e-9),'cold_start',false);
end
