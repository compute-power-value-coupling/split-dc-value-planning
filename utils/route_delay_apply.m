function D = route_delay_apply(P, rt)
%% 通信路由升级的时延矩阵应用(边界2: 通信投资进入规划的物理载体)
%  投资直连光缆/波分专线使对应东西节点对时延降低route_delay_reduction
%  (物理事实: token流带宽极轻, 通信侧真实投资杠杆是时延而非带宽)
D = P.comm_delay_base;
red = 0.4; if isfield(P,'route_delay_reduction'); red = P.route_delay_reduction; end
if isempty(rt); return; end
for i = 1:P.N_west
    for j = 1:P.N_east
        if rt(i,j) > 0.5
            a = P.west_hub_idx(i); b = P.east_hub_idx(j);
            D(a,b) = P.comm_delay_base(a,b) * (1 - red);
            D(b,a) = D(a,b);
        end
    end
end
end
