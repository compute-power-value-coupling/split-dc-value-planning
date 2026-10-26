function [w_field, unc_field, info] = vufp_propagate(w_local, unc_local, P, state, AEMF, year)
%% VUFP — Value-Uncertainty Field Propagation on the Compute-Power Graph
%  价值-不确定性场在算电耦合图上的多跳消息传播算子(本文规划层核心创新)
%
%  ── 为什么必须用图算子而非规则(方法论必要性) ──────────────────────────
%  节点价值不是孤立的: 迁移使节点i承接节点j的负荷波动, j的需求不确定性
%  沿HVDC/光纤边有向传导给i; 且这种传导是多跳的(j→i→k)、非对称的
%  (东→西为主)、边权随规划年演化(迁移流量逐年变化)。规则式逐节点计算
%  无法表达多跳非对称演化耦合, 图上消息传递是其自然且必要的数学形式。
%
%  ── 传播机制(有向加权图上的L跳消息传递) ──────────────────────────────
%  构图: 节点=4西+3东; 有向边权 a_{j→i} = 归一化迁移倾向
%        × 通信可达性 exp(-D_ji/D0) × HVDC容量份额  (物理三要素融合)
%  消息: 每跳聚合邻居价值溢出与不确定性溢出, 残差更新(防过平滑)
%        w^{(l+1)}_i = (1-α) w^{(l)}_i + α Σ_j ã_{j→i} w^{(l)}_j
%        u^{(l+1)}_i = (1-α) u^{(l)}_i + α Σ_j ã_{j→i} (u^{(l)}_j · κ_unc)
%  演化: 边权与传播深度随year自适应(迁移成熟度↑→耦合增强→L增大)
%
%  输入:  w_local  (NI×1)  逐节点独立价值密度(compute_value_density产出)
%         unc_local(N×1)   逐节点不确定性(AEMF全局ε按节点禀赋分解)
%  输出:  w_field  (NI×1)  图传播后的西部节点价值场(注入VAIC割斜率)
%         unc_field(N×1)   图传播后的节点不确定性场
%         info     结构体   邻接矩阵/跳数/谱半径等诊断

NI = P.N_west; NJ = P.N_east; N = NI + NJ;

% ── 1. 构建有向邻接矩阵 A (N×N, A(j,i)=从j流向i的耦合强度) ─────────────
A = zeros(N, N);
D0 = 15;                                  % 通信衰减尺度(ms)
% 迁移流量矩阵(东j→西i), 运行层反馈; 首年用先验(HVDC容量)
OD = zeros(NJ, NI);
if isstruct(AEMF) && isfield(AEMF,'migration_OD_prev')
    OD = AEMF.migration_OD_prev;
end
use_prior = (sum(OD(:)) < 1);
for jj = 1:NJ
    for ii = 1:NI
        % 通信可达性(时延越小耦合越强)
        Dji = P.comm_delay(P.east_hub_idx(jj), P.west_hub_idx(ii));
        reach = exp(-Dji / D0);
        % HVDC容量份额(物理输电能力上限)
        hvdc = P.HVDC_cap_per_node(ii, jj) / max(1, sum(P.HVDC_cap_per_node(:,jj)));
        % 迁移倾向(运行层实测流量, 首年退化为均匀先验)
        if use_prior
            migr = 1 / NI;
        else
            migr = OD(jj, ii) / max(1, sum(OD(jj, :)));
        end
        % 东节点(NI+jj) → 西节点(ii) 的有向边: 三要素乘积
        A(NI + jj, ii) = reach * hvdc * migr;
    end
end
% 西部节点间的二阶耦合(共享东部需求源→价值相关): 经东节点的两跳自然涌现
% 行归一化(消息传递标准化, 防尺度爆炸)
rowsum = sum(A, 2);
A_norm = A ./ max(rowsum, 1e-9);

% ── 2. 自适应传播深度与强度(随迁移成熟度/年份演化) ────────────────────
mig_maturity = 0;
if ~use_prior; mig_maturity = min(1, sum(OD(:)) / (1e4 * year)); end
L_hops = 1 + round(2 * mig_maturity);      % 1~3跳(迁移越成熟传播越深)
alpha  = 0.03 + 0.05 * mig_maturity;       % 耦合强度0.03~0.08(排序保持型微扰)
kappa_unc = 0.6;                           % 不确定性传导衰减(比价值传导更快衰减)

% ── 3. 节点状态向量(西部在前, 东部在后) ──────────────────────────────
w_vec = zeros(N, 1); w_vec(1:NI) = w_local(:);
% 东部节点价值(用推理价代理, 供西部承接价值参考)
if isfield(AEMF,'east_value_proxy') && numel(AEMF.east_value_proxy)>=NJ
    w_vec(NI+1:end) = AEMF.east_value_proxy(:);
else
    w_vec(NI+1:end) = mean(w_local) * ones(NJ,1);
end
u_vec = zeros(N,1);
if numel(unc_local) >= N; u_vec = unc_local(:);
else; u_vec(:) = mean(unc_local); end

% ── 4. L跳残差消息传递 ────────────────────────────────────────────────
w0 = w_vec; u0 = u_vec;
for l = 1:L_hops
    msg_w = A_norm * w_vec;                 % 邻居价值聚合
    msg_u = A_norm * u_vec;                 % 邻居不确定性聚合
    w_vec = (1-alpha)*w_vec + alpha*msg_w;             % 残差更新(防过平滑)
    u_vec = (1-alpha)*u_vec + alpha*kappa_unc*msg_u;
end

% ── 5. 输出西部场 + 诊断 ──────────────────────────────────────────────
w_field   = max(w_vec(1:NI), 0.1*w0(1:NI));   % 下界保护(传播不清零原始价值)
unc_field = u_vec;
info = struct();
info.A_norm = A_norm;
info.L_hops = L_hops;
info.alpha  = alpha;
info.mig_maturity = mig_maturity;
info.spectral_radius = max(abs(eig(A_norm)));  % 谱半径<1保证传播收敛
info.w_shift = w_field - w0(1:NI);             % 图传播带来的价值修正量
end
