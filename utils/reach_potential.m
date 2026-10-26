function [B0, U] = reach_potential(P)
%% 可达潜力矩阵(主问题线性化用, 与候选路由无关的静态数据)
%  B0(i,j)=1: 基准时延即满足B类门限(只需选址i)
%  U(i,j) =1: 基准不满足, 但建设直连路由(时延×(1-red))后满足
Dbase = P.comm_delay;
if isfield(P,'comm_delay_base'); Dbase = P.comm_delay_base; end
red  = 0.40; if isfield(P,'route_delay_reduction'); red = P.route_delay_reduction; end
dmax = 20;   if isfield(P,'d_max_B_mig'); dmax = P.d_max_B_mig; end
NI = P.N_west; NJ = P.N_east;
B0 = zeros(NI,NJ); U = zeros(NI,NJ);
fc = 0.5; if isfield(P,'func_compat'); fc = P.func_compat(2,1); end
if fc <= 0; return; end
if fc >= 1; B0 = ones(NI,NJ); return; end
for i = 1:NI
    for j = 1:NJ
        d = Dbase(P.west_hub_idx(i), P.east_hub_idx(j));
        B0(i,j) = d <= dmax;
        U(i,j)  = (~B0(i,j)) && (d*(1-red) <= dmax);
    end
end
end
