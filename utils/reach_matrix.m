function R = reach_matrix(P, z)
%% B类时延门控服务可达矩阵(创新一: Ω_SLA∩Ω_task 的可计算形式)
%  R(i,j)=1  ⇔  西部节点i已选址 且 当前通信时延D(i→j) ≤ d_max_B_mig
%  时延取P.comm_delay(已叠加当年锁定/候选路由升级), 故路由投资直接改变可达域
NI = P.N_west; NJ = P.N_east;
dmax = 20; if isfield(P,'d_max_B_mig'); dmax = P.d_max_B_mig; end
if nargin < 2 || isempty(z); z = ones(NI,1); end
R = zeros(NI, NJ);
fc = 0.5; if isfield(P,'func_compat'); fc = P.func_compat(2,1); end   % B类→训练侧兼容度
if fc <= 0; return; end                      % 功能不兼容: 不可跨侧
ungated = fc >= 1;                           % 完全兼容: 仅需选址, 不受时延门限
for i = 1:NI
    if z(i) < 0.5; continue; end
    for j = 1:NJ
        R(i,j) = ungated || P.comm_delay(P.west_hub_idx(i), P.east_hub_idx(j)) <= dmax;
    end
end
end
