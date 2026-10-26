function rep = verify_dc_powerflow_n1(results_yearly, P)
%% 改进IEEE118 DC潮流 + LODF线性N-1安全筛查(创新一电力层Ω_power的事后校验)
%  基态潮流 f0 = PTDF·(Pg-Pd)  +  数据中心增量注入(西部:绿电-训练, 东部:-推理)
%  N-1: 断开支路k后  f_l^(k) = f_l + LODF(l,k)·f_k   (放射状支路跳过)
%  额定值: 取RATE_A; 若算例无热稳定限值(全部≥9000或为0), 按基态|f0|×1.3推定并声明
%  声称边界: 线性DC近似+事后筛查, 不是AC-OPF, 也未作为规划硬约束
rep = struct('ok',false,'n0_viol',[],'n1_viol',[],'max_load',[],'max_load_n1',[]);
try
    mpc = loadcase('case118');
catch
    fprintf('\n[潮流N-1] 未检测到MATPOWER(case118), 跳过电力层校验\n'); return;
end
k = 20; if isfield(P,'ieee118_scale'); k = P.ieee118_scale; end
mpc.bus(:,3:4)    = mpc.bus(:,3:4) * k;
mpc.branch(:,6:8) = mpc.branch(:,6:8) * k;
mpc.gen(:,[2,4,9])= mpc.gen(:,[2,4,9]) * k;
nb = size(mpc.bus,1); nl = size(mpc.branch,1);
slack = find(mpc.bus(:,2) == 3, 1);
H = makePTDF(mpc, slack);
try
    L = makeLODF(mpc.branch, H);
catch
    fprintf('[潮流N-1] makeLODF不可用(MATPOWER版本过旧), 仅做N-0\n'); L = [];
end
% 母线编号→行号
bi = zeros(max(mpc.bus(:,1)),1); bi(mpc.bus(:,1)) = 1:nb;
Pg = accumarray(bi(mpc.gen(:,1)), mpc.gen(:,2), [nb 1]);
Pd = mpc.bus(:,3);
f_base0 = H * (Pg - Pd);
rate = mpc.branch(:,6);
rate_note = 'RATE_A';
if all(rate == 0 | rate >= 9000*k)
    rate = max(1.5*abs(f_base0), 0.3*max(abs(f_base0)));   % 推定额定值(假设, 需敏感性)
    rate_note = '基态×1.5推定(下限0.3×最大基态; 算例无热稳定限值)';
end
rate(rate <= 0) = inf;
emerg = 1.2; if isfield(P,'n1_emergency_ratio'); emerg = P.n1_emergency_ratio; end
radial = false(nl,1);
if ~isempty(L); radial = any(~isfinite(L),1)'; end   % 断开即解列的放射状支路

fprintf('\n[潮流N-1] 改进IEEE118(×%d) DC+LODF | 额定值: %s | N-1紧急限值=%.1f×\n', k, rate_note, emerg);
% 无数据中心基态的N-1越限集合(用于区分"电网本身的N-1薄弱"与"数据中心新增越限")
base_viol = false(nl,1);
if ~isempty(L)
    for kk = 1:nl
        if radial(kk) || ~isfinite(rate(kk)); continue; end
        lk = L(:,kk); if any(~isfinite(lk)) || max(abs(lk)) > 10; continue; end
        fk = f_base0 + lk*f_base0(kk); fk(kk) = 0;
        base_viol(kk) = any(abs(fk) > emerg*rate);
    end
end
fprintf('  无数据中心基态自身N-1越限的故障数: %d(属电网/额定值假设, 非规划造成)\n', sum(base_viol));
fprintf('%-4s %10s %8s %12s %8s %12s\n','年','N-0最大','N-0越限','N-1最大','N-1越限','其中新增');
bw = P.ieee118_bus_west; be = P.ieee118_bus_east;
NY = numel(results_yearly);
rep.max_load = nan(NY,1); rep.max_load_n1 = nan(NY,1);
for y = 1:NY
    R = results_yearly{y}; if isempty(R) || ~isfield(R,'state'); continue; end
    dP = zeros(nb,1);
    for i = 1:numel(bw)
        G_out = R.state.G_cum(i) * mean([P.CF_wind_west(i), P.CF_pv_west(i)]);
        dP(bi(bw(i))) = dP(bi(bw(i))) + G_out - R.state.W_T_cum(i);
    end
    for j = 1:numel(be)
        dP(bi(be(j))) = dP(bi(be(j))) - R.state.W_I_cum(j);
    end
    f = f_base0 + H * dP;
    ld0 = abs(f) ./ rate;
    n0 = sum(ld0 > 1.0);
    ld1max = NaN; n1 = 0; n1_new = 0;
    if ~isempty(L)
        ld1max = 0;
        for kk = 1:nl
            if radial(kk) || ~isfinite(rate(kk)); continue; end
            lk = L(:,kk); if any(~isfinite(lk)) || max(abs(lk)) > 10; continue; end   % 近放射状支路不做N-1
            fk = f + lk * f(kk); fk(kk) = 0;
            ldk = abs(fk) ./ (emerg*rate);
            ld1max = max(ld1max, max(ldk));
            n1 = n1 + any(ldk > 1.0);
            if any(ldk > 1.0) && ~base_viol(kk); n1_new = n1_new + 1; end
        end
    end
    rep.max_load(y) = max(ld0); rep.max_load_n1(y) = ld1max;
    rep.n0_viol(y) = n0; rep.n1_viol(y) = n1;
    fprintf('Y%-3d %9.1f%% %8d %11.1f%% %8d %12d\n', y, 100*max(ld0), n0, 100*ld1max, n1, n1_new);
    rep.n1_new(y) = n1_new;
end
rep.ok = true;
fprintf('[潮流N-1] 声称边界: 线性DC近似的事后安全筛查; AC电压/无功未校核\n');
end
