function [wm, wmb] = vlm_wm_rl(wmb, A, V, results_yearly, P, year, growth_forecast)
%% VLM-WM — 价值引导的世界模型强化学习 + 规划力学(创新点三)
%
%  (1) 世界模型  深度集成网络 f_θ: 物理—价值状态z(12维) → 7类资产单位投资年运营收益率
%                训练数据 = 已实现年份 + 扰动反事实样本(wm_sample_generator)
%                损失 = 预测误差 + 物理一致性(自身饱和↑收益率不增) + L2
%  (2) 价值引导  critic V_φ(z, 剩余期) 由世界模型想象轨迹回报训练(拟合价值迭代),
%                并施加协态锚: ∂V/∂K_a|当前 = Λ_a(创新二流积递演给出) —— 协态即价值梯度
%  (3) 想象中规划 CEM在世界模型内优化H年投资序列, 目标 = 运营价值 − 资本支出 + 终端critic,
%                按集成分歧做风险调整; 另以"冻结当年状态"重解一次得近视计划,
%                前瞻价值VoF = J_fwd(u_fwd) − J_fwd(u_myopic)
%  (4) 物理校正  首年动作经前瞻修正项(只进一阶段目标, 不改割)传给Benders主问题,
%                下一年DACS运行即物理校正器
%  (5) 规划力学  学习力 ρ_a = Λ_a/c_a − 1(约化成本); 力—饱和律 ρ = α + β·s(β≤0恢复力);
%                力平衡容量 K* (ρ=0); 逐年先预测下一年ρ与主导资产, 次年用实现值检验(可证伪)
%  声称边界: 基于模型的强化学习(规划式), 非无模型策略梯度; 学习力学为思想来源, 本文为"规划力学"
NA = 7; Y = P.N_year; beta = 1/(1+A.r);
wm = struct('active',false,'adj',zeros(NA,1),'plan',[],'rho_pred',[],'year',year, ...
            'm_fore',[],'vof',NaN);
Smp = wmb.samples;
c = A.c_unit(:)';  Lf = A.life(:)';
crf = @(n) A.r*(1+A.r)^n/((1+A.r)^n-1);
g_ = @(f,d) getp(P,f,d);
mode_ = g_('wm_mode','full');   use_critic = ~strcmp(mode_,'no_value');

% ── 基准归一化常数 k̄(首个已实现样本) ──────────────────────────────────
if ~isfield(wmb,'kbar') || isempty(wmb.kbar)
    s1 = Smp(find([Smp.real],1));
    kb = s1.K(:)' / max(1, s1.D); kb(kb <= 0) = 0.1; wmb.kbar = kb;
end
kbar = wmb.kbar;
% 边际学习力: ρ_mg = (反事实边际价值×寿命年金)/c − 1  —— 真正的价值梯度(平均归因只作核算)
AF = arrayfun(@(Lx) sum(beta.^(0:Lx-1)), Lf);
Rcf = V.rho(1:year,:); Lam_mg = V.Lambda(year,:);
if isfield(wmb,'cf') && size(wmb.cf,1) >= year
    Rm = wmb.cf(1:year,:) .* AF ./ c - 1; okm = isfinite(Rm); Rcf(okm) = Rm(okm);
    lm = wmb.cf(year,:) .* AF; okl = isfinite(lm); Lam_mg(okl) = lm(okl);
end

% ── 当前状态与外生驱动投影 ─────────────────────────────────────────────
sr = Smp(find([Smp.real] & [Smp.year] == year, 1));
Dn = sr.D; en = sr.eta; mixn = sr.mix; curn = sr.cur; pmn = sr.pm; Kn = A.K(year,:);
eh = zeros(year,1);
for y = 1:year; eh(y) = Smp(find([Smp.real] & [Smp.year] == y, 1)).eta; end
eg = 1.2; if year >= 3; eg = (eh(year)/eh(year-2))^(1/2); end
Dp = zeros(Y+1,1); ep = Dp; mp = Dp;
Dp(year) = Dn; ep(year) = en; mp(year) = mixn;
for t = year+1:Y+1
    gr = growth_forecast(min(t, numel(growth_forecast)));
    Dp(t) = Dp(t-1)*(1+gr); ep(t) = ep(t-1)*max(1, 1 + (eg-1)*0.85^(t-year));
    tr = task_ratio_at(min(t,Y), P); mp(t) = tr(1) + tr(2);
end

% ── 规划力学: 检验上一年对本年的预测(可证伪) ────────────────────────────
rho_now = Rcf(year,:);
if year >= 2 && numel(wmb.pred) >= year && ~isempty(wmb.pred{year})
    pr = wmb.pred{year}; lv = pr.live & (Kn > 1e-6);
    if any(lv)
        mae_l = mean(abs(pr.rho_law(lv) - rho_now(lv)),'omitnan');
        mae_w = mean(abs(pr.rho_wm(lv) - rho_now(lv)),'omitnan');
        sg_l = mean(sign(pr.rho_law(lv)) == sign(rho_now(lv)));
        sg_w = mean(sign(pr.rho_wm(lv)) == sign(rho_now(lv)));
        [~, iL] = max(pr.rho_law .* lv - 1e9*(~lv)); [~, iW] = max(pr.rho_wm .* lv - 1e9*(~lv));
        [~, iR] = max(rho_now .* lv - 1e9*(~lv));
        mae_p = mean(abs(Rcf(year-1,lv) - rho_now(lv)),'omitnan');     % 持平基线
        % 世界模型本职检验: 预测的下一年单位投资收益率 vs 实现值(对照持平)
        g_now = V.m(year,:) ./ c; g_prv = V.m(year-1,:) ./ c; mae_gw = NaN; mae_gp = NaN;
        if isfield(pr,'g_wm') && any(isfinite(pr.g_wm(lv)))
            mae_gw = mean(abs(pr.g_wm(lv) - g_now(lv)),'omitnan');
            mae_gp = mean(abs(g_prv(lv) - g_now(lv)),'omitnan');
        end
        wmb.eval(end+1,:) = [year, mae_l, mae_w, sg_l, sg_w, iL == iR, iW == iR, mae_p, mae_gw, mae_gp];
        wmb.pairs = [wmb.pairs; [pr.rho_law(lv)', pr.rho_wm(lv)', rho_now(lv)']];
        fprintf('  [规划力学] Y%d检验: ρ的MAE 差分律%.3f/持平%.3f | 收益率MAE 世界模型%.4f/持平%.4f | 主导命中%d\n', ...
            year, mae_l, mae_p, mae_gw, mae_gp, iL == iR);
    end
end

if numel(Smp) < 10 || year < 2 || year >= Y
    return;                                            % 数据不足或末年: 不规划
end

% ── (1) 世界模型训练 ──────────────────────────────────────────────────
Ns = numel(Smp); X = zeros(12,Ns); Yt = nan(NA,Ns); w = ones(1,Ns);
for n = 1:Ns
    s = Smp(n);
    X(:,n) = wm_feat(s.D, s.eta, s.mix, s.cur, s.pm, s.K, kbar);
    for a = 1:NA
        if s.K(a) > 1e-6; Yt(a,n) = min(3, max(-1, s.F(a)/(s.K(a)*c(a)))); end
    end
    if s.real; w(n) = 3; end
end
optW = struct('M',g_('wm_ensemble',5),'H',g_('wm_hidden',32),'epochs',g_('wm_epochs',400), ...
              'lr',g_('wm_lr',5e-3),'w',w,'phys_idx',5+(1:NA),'phys_w',1.0,'delta',0.5);
WMn = wm_mlp_train(X, Yt, optW);

% ── (2) critic: 想象轨迹回报 + 协态锚 ─────────────────────────────────
critic = [];
if use_critic
    Nc = g_('wm_critic_n',150); Xc = zeros(13,Nc); Vc = zeros(1,Nc);
    rng(7000+year,'twister');
    for n = 1:Nc
        t0 = year + randi([0, Y-year]);
        K0 = Kn .* [exp(0.3*randn(1,6)) .* (Dp(t0)/Dn), 1];
        K0(7) = Kn(7) + randi([0 2]);
        Vs = 0; r = 0;
        for tau = t0:Y
            Kt = K0 .* [repmat(Dp(tau)/Dp(t0),1,6), 1];
            r = mean(reward_m(WMn, featv(Dp(tau),ep(tau),mp(tau),curn,pmn,Kt',kbar), Kt', c), 2);
            Vs = Vs + beta^(tau-t0) * r;
        end
        Vs = Vs + r * sum(beta.^((Y-t0+1):(Y-t0+10)));
        Vc(n) = Vs / 1e4;                                                % 亿元
        Xc(:,n) = [featv(Dp(t0),ep(t0),mp(t0),curn,pmn,K0',kbar); (Y-t0)/Y];
    end
    anc = [];
    xnow = [featv(Dn,en,mixn,curn,pmn,Kn',kbar); (Y-year)/Y];
    lv = find(Kn > 1e-6 & isfinite(Lam_mg));
    if ~isempty(lv)
        dKds = zeros(1,numel(lv));
        for q = 1:numel(lv)
            a = lv(q);
            if a <= 6; dKds(q) = Dn*kbar(a) + Kn(a); else; dKds(q) = 1 + Kn(a); end
        end
        anc = struct('x_raw',xnow,'fidx',5+lv,'out',ones(1,numel(lv)), ...
                     'slope_raw',(Lam_mg(lv)/1e4).*dKds,'w',g_('wm_anchor_w',1.0));
    end
    optC = struct('M',3,'H',g_('wm_hidden',32),'epochs',g_('wm_epochs',400),'lr',g_('wm_lr',5e-3), ...
                  'phys_idx',0,'delta',0.5,'anchor',anc);
    critic = wm_mlp_train(Xc, Vc, optC);
end

% ── (3) 想象中规划: 前瞻CEM与近视CEM ───────────────────────────────────
Hh = min(g_('wm_horizon',5), Y - year);
umax = reshape([0.6 0.6 0.6 0.6 0.6 0.3 2], 1, NA);
cplan = c; rG = P.C_gpu_ratio; TG = P.T_gpu_life;
cplan(1) = P.C_train_fix * ((1-rG) + rG*sum(beta.^(0:TG:Lf(1)-1)));   % 含GPU周期重置
ctx = struct('WM',WMn,'critic',critic,'Dp',Dp,'ep',ep,'mp',mp,'Dn',Dn,'en',en,'mixn',mixn, ...
             'curn',curn,'pmn',pmn,'kbar',kbar,'c',c,'cplan',cplan,'beta',beta,'outd',P.out_dir, ...
             'year',year,'Y',Y,'Hh',Hh,'risk',g_('wm_risk',0.5));
zer = zeros(Hh, NA); trk = zeros(Hh, NA);
for t = 1:Hh; trk(t,1:6) = max(0, Dp(year+t)/Dp(year+t-1) - 1); end
u_myo = cem(ctx, Kn, umax, 'frz', P, {zer});
u_fwd = cem(ctx, Kn, umax, 'fwd', P, {zer, trk, u_myo});   % 前瞻规划可选近视计划→VoF≥0
[Jf, Jfm] = eval_plan(ctx, u_fwd, Kn, 'fwd');
[Jm, ~]   = eval_plan(ctx, u_myo, Kn, 'fwd');
vof = (Jf - Jm) / 1e4;                                                  % 亿元

% ── (4) 前瞻修正(单位边际生命周期价值: 前瞻 − 冻结) ─────────────────────
adj = zeros(NA,1); mvf_v = nan(1,NA);
for a = find(Kn > 1e-6)
    ea = 0.05*Kn(a); if a == 7; ea = 0.5; end
    K1 = Kn; K1(a) = K1(a) + ea;
    mvf = (eval_plan(ctx, u_fwd, K1, 'fwd') - Jf) / ea;
    mvf_v(a) = mvf;
    J0z = eval_plan(ctx, u_fwd, Kn, 'frz');
    mvz = (eval_plan(ctx, u_fwd, K1, 'frz') - J0z) / ea;
    cap_ = 0.5 * c(a) * crf(Lf(a));
    adj(a) = max(-cap_, min(cap_, (mvf - mvz) * crf(Lf(a))));
end
% ── 候选动作集: 世界模型(前瞻)/近视/力流(沿边际学习力的梯度流一步)/零扩容 ──
% 各候选只改首年动作, 其后沿用前瞻计划, 由世界模型给出预测价值(用于检验决策一致性)
eta_f = 0.15; if isfield(P,'force_step'); eta_f = P.force_step; end
u_force = zeros(1,NA);
for a = [1 2 3 6]
    if isfinite(Rcf(year,a)); u_force(a) = min(umax(a), max(0, eta_f * Rcf(year,a))); end
end
cand_u = [u_fwd(1,:); u_myo(1,:); u_force; zeros(1,NA)];
cand_J = zeros(1,4); cand_J1 = zeros(1,4);
for k = 1:4
    Uk = u_fwd; Uk(1,:) = cand_u(k,:);
    cand_J(k) = eval_plan(ctx, Uk, Kn, 'fwd');
    % 首年年化净价值(与真实子问题UB同口径: 运营价值 − 新增投资年金), 用于决策一致性检验
    K1c = step_K(Kn(:), cand_u(k,:)');
    x1c = featv(Dp(year+1), ep(year+1), mp(year+1), curn, pmn, K1c, kbar);
    cand_J1(k) = mean(reward_m(WMn, x1c, K1c, c), 2) - sum(capex_unit_annual(P, year+1)' .* max(0, K1c - Kn(:)));
end
% 基线计划下单位运营价值预测(供流积递演补齐Λ尾部)
m_fore = zeros(Hh, NA); Kt = Kn';
for t = 1:Hh
    Kt = step_K(Kt, u_fwd(t,:)');
    x = featv(Dp(year+t),ep(year+t),mp(year+t),curn,pmn,Kt,kbar);
    m_fore(t,:) = (min(3,max(-1,wm_mlp_predict(WMn, x))) .* c(:))';
end

% ── (5) 规划力学: 力—饱和律拟合、力平衡容量、下一年预测 ─────────────────
sh = nan(year, NA);
for y = 1:year
    sy = Smp(find([Smp.real] & [Smp.year] == y, 1));
    xy = wm_feat(sy.D, sy.eta, sy.mix, sy.cur, sy.pm, sy.K, kbar); sh(y,:) = xy(6:12)';
end
al = nan(1,NA); be = nan(1,NA); gm = zeros(1,NA); Keq = nan(1,NA);
lDh = nan(year,1);
for y = 1:year; lDh(y) = log(max(1, Smp(find([Smp.real] & [Smp.year] == y, 1)).D)); end
K1n = step_K(Kn', u_fwd(1,:)')';  D1 = Dp(year+1);
x1 = wm_feat(D1, ep(year+1), mp(year+1), curn, pmn, K1n, kbar); s1n = x1(6:12)';
rho_law = nan(1,NA);
for a = 1:NA
    v = isfinite(Rcf(1:year,a)) & A.K(1:year,a) > 1e-6;
    if sum(v) >= 3
        % 差分力学律: Δρ = β·Δs + γ·ΔlnD (β≤0饱和恢复力, γ需求牵引); β=γ=0时即持平预测,
        % 因此定律只有在真正刻画动力学时才会优于持平基线(可证伪)
        iv = find(v); dv = iv(2:end); pv = iv(1:end-1); ok = (dv - pv) == 1; dv = dv(ok); pv = pv(ok);
        b = [0; 0];
        if numel(dv) >= 2
            Xd = [sh(dv,a) - sh(pv,a), lDh(dv) - lDh(pv)]; yd = Rcf(dv,a) - Rcf(pv,a);
            b = (Xd'*Xd + 1e-3*eye(2)) \ (Xd'*yd);
            if b(1) > 0; b = [0; (Xd(:,2)'*yd) / max(1e-9, Xd(:,2)'*Xd(:,2) + 1e-3)]; end   % β≤0
        end
        be(a) = b(1); gm(a) = b(2); al(a) = Rcf(year,a) - be(a)*sh(year,a) - gm(a)*lDh(year);
        rho_law(a) = Rcf(year,a) + be(a)*(s1n(a) - sh(year,a)) + gm(a)*(log(D1) - lDh(year));
        if be(a) < 0
            ss = -(al(a) + gm(a)*log(Dn))/be(a);                   % 力平衡: ρ=0
            if ss > 0 && ss < 10
                if a <= 6; Keq(a) = Dn*kbar(a)*(exp(ss)-1); else; Keq(a) = exp(ss)-1; end
                if Kn(a) > 1e-6 && (Keq(a) > 20*Kn(a) || Keq(a) < 0.2*Kn(a)); Keq(a) = NaN; end   % 超出可信外推范围
            end
        end
    elseif Kn(a) > 1e-6
        rho_law(a) = rho_now(a);                                  % 数据不足: 持平预测
    end
end
rho_wm = nan(1,NA);
% 世界模型预测学习力: 前瞻计划下单位资产的生命周期边际价值(推演期+终端critic)/c − 1
if any(isfinite(mvf_v))
    rho_wm = mvf_v ./ c - 1;
elseif ~isempty(critic)
    xc1 = [x1; (Y-year-1)/Y]; v0 = mean(wm_mlp_predict(critic, xc1));
    for a = find(K1n > 1e-6)
        xp = xc1; xp(5+a) = xp(5+a) + 0.05;
        dVds = (mean(wm_mlp_predict(critic, xp)) - v0) / 0.05;         % 亿元/单位饱和
        if a <= 6; dKds = D1*kbar(a) + K1n(a); else; dKds = 1 + K1n(a); end
        rho_wm(a) = (1e4 * dVds / dKds) / c(a) - 1;
    end
end
live = K1n > 1e-6;
if numel(wmb.pred) < year+1; wmb.pred{year+1} = []; end
g_wm_next = nan(1,NA); if ~isempty(m_fore); g_wm_next = m_fore(1,:) ./ c; end
wmb.pred{year+1} = struct('rho_law',rho_law,'rho_wm',rho_wm,'live',live,'g_wm',g_wm_next);
wmb.law = struct('alpha',al,'beta',be,'gamma',gm,'Keq',Keq,'year',year);
if year >= 2
    for a = [1 2 3 6]                                  % 自愿投资资产(储能受备用强制约束, 路由为离散)
        if A.K(year-1,a) > 1e-6 && isfinite(Rcf(year-1,a))
            vv = (A.K(year,a) - A.K(year-1,a)) / A.K(year-1,a);
            gD = Dn / max(1, Smp(find([Smp.real] & [Smp.year] == year-1, 1)).D) - 1;   % 需求增速
            wmb.invlaw(end+1,:) = [year, a, Rcf(year-1,a), vv, gD];
        end
    end
end
wmb.log(year,:) = [numel(Smp), mean(WMn.r2,'omitnan'), ...
                   ifelse(isempty(critic), NaN, mean(critic.r2,'omitnan')), vof];

if ~isfield(wmb,'plan') || isempty(wmb.plan); wmb.plan = nan(Y,NA); wmb.plan_myo = nan(Y,NA); end
wmb.plan(year,:) = u_fwd(1,:); wmb.plan_myo(year,:) = u_myo(1,:);   % 逐年首步动作(供论文图)
wmb.net_last = WMn; wmb.critic_last = critic; wmb.c_unit = c; wmb.year_last = year;   % 供价值地形图
wm.active = true; wm.adj = adj; wm.plan = u_fwd; wm.plan_myopic = u_myo;
wm.rho_pred = rho_law; wm.rho_wm = rho_wm; wm.m_fore = m_fore; wm.vof = vof;
wm.rho_mg = Rcf(year,:);
wm.cand_u = cand_u; wm.cand_J = cand_J1; wm.cand_J_life = cand_J;   % 一致性检验用首年口径   % 候选动作及世界模型预测价值(万元)        % 本年边际学习力(真实运行反事实), 供主问题回收闭合项
wm.Jf_members = Jfm;

names = {'训练','推理','绿电','西储','东储','HVDC','通信'};
[~, iLead] = max(rho_law .* live - 1e9*(~live));
fprintf('  [VLM-WM] Y%d 样本%d | 世界模型R^2=%.2f critic R^2=%.2f | 首年计划增量%%=[%s] | 前瞻价值VoF=%.1f亿 | 预测Y%d主导:%s\n', ...
    year, numel(Smp), mean(WMn.r2,'omitnan'), wmb.log(year,3), ...
    num2str(round(100*u_fwd(1,1:6)),'%d '), vof, year+1, names{iLead});

if g_('wm_fig', true)
    try; plot_wm_year(year, rho_now, rho_law, Kn, u_fwd, u_myo, ctx, wmb); catch ME_f
        fprintf('     [VLM-WM] 出图跳过: %s\n', ME_f.message); end
end
end

% ════════════════════ 局部函数 ════════════════════
function u = cem(ctx, K0, umax, mode, P, seeds)
Hh = ctx.Hh; NA = 7; if nargin < 6; seeds = {}; end
Np = getp(P,'wm_cem_pop',64); Ne = getp(P,'wm_cem_elite',8); It = getp(P,'wm_cem_iter',6);
mu = zeros(Hh,NA);
for t = 1:Hh
    if strcmp(mode,'fwd'); g = ctx.Dp(ctx.year+t)/ctx.Dp(ctx.year+t-1) - 1; else; g = 0; end
    mu(t,1:6) = max(0, g);
end
sd = 0.25*ones(Hh,NA); sd(:,7) = 0.7;
rng(9000 + ctx.year + strcmp(mode,'frz'), 'twister');
best = mu; bJ = -inf;
for it = 1:It
    U = mu + sd .* randn(Hh, NA, Np);
    U = min(max(U, 0), repmat(umax, Hh, 1, Np));
    U = cat(3, U, mu, seeds{:});                          % 注入当前均值与种子计划
    J = eval_plan(ctx, U, K0, mode);
    [~, o] = sort(J, 'descend');
    if J(o(1)) > bJ; bJ = J(o(1)); best = U(:,:,o(1)); end   % 精英保留
    El = U(:,:,o(1:Ne));
    mu = 0.3*mu + 0.7*mean(El, 3);
    sd = 0.3*sd + 0.7*std(El, 0, 3) + 1e-3;
end
u = best;
end

function [J, Jm] = eval_plan(ctx, U, K0, mode)
% U: Hh×7×Np(相对增量); 返回风险调整目标J(Np×1)与各成员值Jm(Np×M)
Np = size(U,3); Hh = ctx.Hh; b = ctx.beta;
K = repmat(K0(:), 1, Np);
M = numel(ctx.WM.members); Jm = zeros(Np, M);
for t = 1:Hh
    Kn = step_K(K, reshape(U(t,:,:), 7, Np));
    capex = sum(ctx.cplan(:) .* max(0, Kn - K), 1)';                % Np×1
    K = Kn;
    if strcmp(mode,'fwd')
        x = featv(ctx.Dp(ctx.year+t), ctx.ep(ctx.year+t), ctx.mp(ctx.year+t), ctx.curn, ctx.pmn, K, ctx.kbar);
    else
        x = featv(ctx.Dn, ctx.en, ctx.mixn, ctx.curn, ctx.pmn, K, ctx.kbar);
    end
    Jm = Jm + b^t * reward_m(ctx.WM, x, K, ctx.c) - b^(t-1) * capex;
end
if ~isempty(ctx.critic)
    tf = (ctx.Y - ctx.year - Hh)/ctx.Y;
    if strcmp(mode,'fwd')
        xT = featv(ctx.Dp(ctx.year+Hh), ctx.ep(ctx.year+Hh), ctx.mp(ctx.year+Hh), ctx.curn, ctx.pmn, K, ctx.kbar);
    else
        xT = featv(ctx.Dn, ctx.en, ctx.mixn, ctx.curn, ctx.pmn, K, ctx.kbar);
    end
    Vt = wm_mlp_predict(ctx.critic, [xT; tf*ones(1,Np)]);           % 1×Np 亿元
    Jm = Jm + b^Hh * 1e4 * Vt(:);
end
J = mean(Jm, 2) - ctx.risk * std(Jm, 0, 2);
end

function R = reward_m(WM, x, K, c)
% 各集成成员的系统年运营价值(万元): Np×M
[~, ~, Yall] = wm_mlp_predict(WM, x);
Yall = min(3, max(-1, Yall));
Np = size(K,2); M = size(Yall,3);
R = reshape(sum(Yall .* (c(:) .* K), 1), Np, M);
end

function K = step_K(K, u)
K(1:6,:) = K(1:6,:) .* (1 + u(1:6,:));
K(7,:)   = K(7,:) + u(7,:);
end

function x = featv(D, eta, mix, cur, pm, K, kbar)
% 向量化状态编码: K为7×Np
Np = size(K,2);
s = zeros(7, Np);
for a = 1:6; s(a,:) = log(1 + max(0,K(a,:)) / (max(D,1)*max(kbar(a),1e-9))); end
s(7,:) = log(1 + max(0,K(7,:)));
x = [repmat([log(max(D,1)); log(max(eta,1)); mix; cur; pm], 1, Np); s];
end

function v = getp(P, f, d)
if isfield(P,f) && ~isempty(P.(f)); v = P.(f); else; v = d; end
end

function v = ifelse(c, a, b)
if c; v = a; else; v = b; end
end

function plot_wm_year(year, rho_now, rho_law, Kn, u_fwd, u_myo, ctx, wmb)
% 逐年可视化: (a)学习力场与下一年预测 (b)想象轨迹扇形(前瞻vs近视) (c)预测—实现检验
en = {'Train','Infer','Green','Stor-W','Stor-E','HVDC','Route'};
outd = fullfile(ctx.outd,'wm'); if ~exist(outd,'dir'); mkdir(outd); end
fg = figure('Visible','off','Color','w','Position',[60 60 1500 430]);
% (a)
subplot(1,3,1); lv = find(Kn > 1e-6);
bar(1:numel(lv), rho_now(lv), 0.6, 'FaceColor',[0.30 0.50 0.75]); hold on;
plot(1:numel(lv), rho_law(lv), 'kd', 'MarkerFaceColor',[0.95 0.6 0.1], 'MarkerSize',7);
yline(0,'k--'); set(gca,'XTick',1:numel(lv),'XTickLabel',en(lv)); grid on;
ylabel('\rho_a = \Lambda_a/c_a - 1'); title(sprintf('Y%d force field (bar) & Y%d forecast', year, year+1));
legend({'realized','forecast'},'Location','best');
% (b)
subplot(1,3,2); hold on; b = ctx.beta; M = numel(ctx.WM.members);
for pass = 1:2
    if pass == 1; U = u_fwd; col = [0.20 0.45 0.80]; else; U = u_myo; col = [0.85 0.35 0.25]; end
    K = Kn(:); cum = zeros(ctx.Hh+1, M);
    for t = 1:ctx.Hh
        Kn2 = step_K(K, U(t,:)'); capex = sum(ctx.cplan(:) .* max(0,Kn2-K)); K = Kn2;
        x = featv(ctx.Dp(ctx.year+t), ctx.ep(ctx.year+t), ctx.mp(ctx.year+t), ctx.curn, ctx.pmn, K, ctx.kbar);
        r = reward_m(ctx.WM, x, K, ctx.c);                      % 1×M
        cum(t+1,:) = cum(t,:) + (b^t*r - b^(t-1)*capex)/1e4;
    end
    plot(year:year+ctx.Hh, cum, '-', 'Color', [col 0.35]);
    plot(year:year+ctx.Hh, mean(cum,2), '-', 'Color', col, 'LineWidth', 2.2);
end
xlabel('Year'); ylabel('Cumulative discounted value (100M CNY)'); grid on;
title('Imagined rollouts: foresight (blue) vs myopic (red)');
% (c)
subplot(1,3,3); hold on;
if ~isempty(wmb.pairs)
    scatter(wmb.pairs(:,3), wmb.pairs(:,1), 28, [0.95 0.6 0.1], 'filled');
    ok = isfinite(wmb.pairs(:,2));
    if any(ok); scatter(wmb.pairs(ok,3), wmb.pairs(ok,2), 28, [0.3 0.5 0.75]); end
    lim = [min(wmb.pairs(:)) max(wmb.pairs(:))]; if all(isfinite(lim)) && diff(lim) > 0
        plot(lim, lim, 'k--'); end
    legend({'force law','world model','y=x'},'Location','best');
end
xlabel('Realized \rho'); ylabel('Forecast \rho'); grid on; title('Falsification: forecast vs realized');
try; set(findall(fg,'Type','axes'),'Toolbar',[]); catch; end
exportgraphics(fg, fullfile(outd, sprintf('fig_wm_Y%02d.png', year)), 'Resolution', 200);
close(fg);
end
