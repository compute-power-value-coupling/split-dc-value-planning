function net = build_network_sens(P)
%% 电力层线性灵敏度(创新一Ω_power进入规划): 改进IEEE118(×k) DC-PTDF
%  选取对7个数据中心接入母线最敏感的若干条线路, 输出 基态潮流f0、灵敏度H(线路×7)、推定额定值
%  额定值与事后N-1筛查同一规则(算例无热稳定限值时按1.5×基态、下限0.3×最大基态, 属假设须做敏感性)
net = [];
try
    mpc = loadcase('case118');
catch
    fprintf('[网络约束] 未检测到MATPOWER, 规划不含线路约束(仅运行后筛查)\n'); return;
end
k = 20; if isfield(P,'ieee118_scale'); k = P.ieee118_scale; end
mpc.bus(:,3:4) = mpc.bus(:,3:4)*k; mpc.branch(:,6:8) = mpc.branch(:,6:8)*k; mpc.gen(:,[2,4,9]) = mpc.gen(:,[2,4,9])*k;
nb = size(mpc.bus,1); slack = find(mpc.bus(:,2) == 3, 1);
H = makePTDF(mpc, slack);
bi = zeros(max(mpc.bus(:,1)),1); bi(mpc.bus(:,1)) = 1:nb;
Pg = accumarray(bi(mpc.gen(:,1)), mpc.gen(:,2), [nb 1]); Pd = mpc.bus(:,3);
f0 = H * (Pg - Pd);
rate = mpc.branch(:,6);
if all(rate == 0 | rate >= 9000*k); rate = max(1.5*abs(f0), 0.3*max(abs(f0))); end
buses = [bi(P.ieee118_bus_west(:)); bi(P.ieee118_bus_east(:))];
Hd = H(:, buses);
nsel = 40; if isfield(P,'net_n_lines'); nsel = P.net_n_lines; end
[~, o] = sort(max(abs(Hd),[],2) ./ max(rate,1), 'descend'); sel = o(1:min(nsel, numel(o)));
cfw = zeros(P.N_west,1);
for i = 1:P.N_west; cfw(i) = mean([P.CF_wind_west(i), P.CF_pv_west(i)]); end
net = struct('H', Hd(sel,:), 'f0', f0(sel), 'rate', rate(sel), 'cfw', cfw, 'lines', sel);
fprintf('[网络约束] 规划纳入%d条敏感线路的DC潮流软约束(越限罚%.0f万元/MW·年)\n', numel(sel), getp_(P,'net_pen',30));
end
function v = getp_(P,f,d); if isfield(P,f); v = P.(f); else; v = d; end; end
