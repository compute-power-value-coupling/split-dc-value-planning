function wm = vlm_world_model(A, V, results_yearly, P, year, growth_forecast)
%% VLM-WM — 价值学习力世界模型(创新点三): 动作条件的物理—价值联合推演
%
%  问题: 主问题 = 年化投资 + 本年运营θ, 隐含"本年状态代表全寿命"(近视滚动)
%  (1) 编码  x_{a,y} = [log D, log η, 推理占比mix, 自身饱和s_a, 对侧饱和s_cross]
%            s = log(1 + K/(D·k̄)), k̄为已实现年份的典型容量/需求比(归一化)
%            对侧耦合: 训练侧资产读推理饱和, 推理侧资产读训练饱和 → 跨资产效应
%  (2) 学习  单位投资年收益率 g_{a,y}=m_{a,y}/c_a ≈ θ_a·[1, x̃]  (标准化岭回归)
%            价值一致性: 拟合FBR给出的m;  物理一致性: 自身饱和系数≤0(投影), 预测截断[-0.5,1]
%  (3) 推演  对每个候选方向b: 在基线容量路径上追加ΔK_b, 滚动H年(外生驱动: 权威增长
%            预测/效率趋势/任务结构演化), 计算系统价值差 ΔW_b(τ)=Σ_a V_a(K+ΔK_b)-V_a(K)
%            → 单位边际生命周期价值 MV_b(含饱和递减与跨资产效应)
%  (4) 对照  同一模型在"冻结当年状态"下推演得 MV_b^frz (近视等价)
%            前瞻修正 adj_b = (MV_b^fwd − MV_b^frz)·CRF(L_b), 截断±0.5·年金
%            只进入下一年主问题一阶段目标, 不改Benders割; 下一年DACS运行即物理校正器
%  身份声明: 学习型代理上的动作条件模型预测控制; 低维结构化回归, 非深度网络;
%            样本=已实现年份(≥3年才启用), 早期系数弱辨识, 靠岭正则与截断约束
NA = numel(A.assets);
wm = struct('active',false,'adj',zeros(NA,1),'mv_fwd',zeros(NA,1),'mv_frz',zeros(NA,1), ...
            'rho_hat',zeros(NA,1),'m_fore',[],'year',year,'coef',[], ...
            'rank_fwd',[],'rank_frz',[]);
H = 5;      if isfield(P,'wm_horizon'); H = P.wm_horizon; end
lam_r = 1;  if isfield(P,'wm_ridge');   lam_r = P.wm_ridge; end
dKf = 0.10; if isfield(P,'wm_action_frac'); dKf = P.wm_action_frac; end
Yr = min(year, size(A.REV,1));
if Yr < 3; return; end

% ── (1) 已实现状态 ─────────────────────────────────────────────────────
D = zeros(Yr,1); eta = zeros(Yr,1); mix = zeros(Yr,1);
for y = 1:Yr
    R = results_yearly{y};
    D(y) = max(1, max(sum(R.demand_y,1)));
    eta(y) = P.eta_token_Y1;
    if isfield(R,'ben_info') && isfield(R.ben_info,'SKU') && isfield(R.ben_info.SKU,'eta_token')
        eta(y) = R.ben_info.SKU.eta_token;
    end
    tr = task_ratio_at(y, P); mix(y) = tr(1) + tr(2);
end
c = A.c_unit(:)'; K = A.K(1:Yr,:); Lf = A.life(:)';
g = V.m(1:Yr,:) ./ max(c, 1e-9);
live = find(any(K > 1e-6, 1));
kbar = ones(1,NA);
for a = live
    rr = K(:,a) ./ D; kbar(a) = max(1e-6, mean(rr(rr > 0)));
end
cross_of = [2 1 2 2 1 2 2];     % 训练侧资产读W_I饱和, 推理侧资产(W_I,E_e)读W_T饱和

% ── (2) 学习(投影岭回归) ─────────────────────────────────────────────────
coef = zeros(NA,6); mu = zeros(NA,5); sd = ones(NA,5);
for a = live
    X = zeros(Yr,5);
    for y = 1:Yr; X(y,:) = feat(D(y), eta(y), mix(y), K(y,:), a, kbar, cross_of); end
    mu_ = mean(X,1); sd_ = std(X,0,1); sd_(sd_ < 1e-9) = 1;
    Xs = [ones(Yr,1), (X - mu_) ./ sd_];
    Rg = lam_r*eye(6); Rg(1,1) = 0;
    b = (Xs'*Xs + Rg) \ (Xs'*g(:,a));
    if b(5) > 0                                        % 物理一致性: 自身饱和递减
        kp = [1 2 3 4 6];
        b2 = (Xs(:,kp)'*Xs(:,kp) + Rg(kp,kp)) \ (Xs(:,kp)'*g(:,a));
        b = zeros(6,1); b(kp) = b2;
    end
    coef(a,:) = b'; mu(a,:) = mu_; sd(a,:) = sd_;
end
M = struct('coef',coef,'mu',mu,'sd',sd,'c',c,'live',live,'kbar',kbar,'cross_of',cross_of);

% ── (3) 外生驱动路径(前瞻) ───────────────────────────────────────────────
Ntot = numel(growth_forecast);
Dp = zeros(H,1); ep = zeros(H,1); mp = zeros(H,1);
eg = (eta(Yr)/eta(Yr-2))^(1/2);
Dc = D(Yr); ec = eta(Yr);
for h = 1:H
    t = year + h;
    gr = growth_forecast(min(t, Ntot));
    Dc = Dc * (1 + gr);  ec = ec * max(1, 1 + (eg - 1) * 0.85^h);
    Dp(h) = Dc; ep(h) = ec;
    tr = task_ratio_at(min(t, P.N_year), P); mp(h) = tr(1) + tr(2);
end
beta = 1/(1+A.r);
crf = @(n) A.r*(1+A.r)^n/((1+A.r)^n-1);

% ── (3)+(4) 动作条件推演: 前瞻 vs 冻结 ────────────────────────────────────
mvf = zeros(NA,1); mvz = zeros(NA,1);
for b = live
    dK = dKf * K(Yr,b); if dK <= 0; continue; end
    for mode = 1:2                                     % 1=前瞻, 2=冻结(近视等价)
        dW = zeros(H,1);
        for h = 1:H
            if mode == 1
                Kb = K(Yr,:) * (Dp(h)/D(Yr)); Kb(7) = K(Yr,7);   % 容量随需求, 路由不随
                Dv = Dp(h); ev = ep(h); mx = mp(h);
            else
                Kb = K(Yr,:); Dv = D(Yr); ev = eta(Yr); mx = mix(Yr);
            end
            Ka = Kb; Ka(b) = Ka(b) + dK;
            dW(h) = sysval(Ka, Dv, ev, mx, M) - sysval(Kb, Dv, ev, mx, M);
        end
        tailw = sum(beta.^((H+1):Lf(b)));
        PV = sum(beta.^(1:H)' .* dW) + dW(H) * tailw;
        if mode == 1; mvf(b) = PV / dK; else; mvz(b) = PV / dK; end
    end
end
adj = zeros(NA,1); rho_hat = zeros(NA,1);
for b = live
    cap_ = 0.5 * c(b) * crf(Lf(b));
    adj(b) = max(-cap_, min(cap_, (mvf(b) - mvz(b)) * crf(Lf(b))));
    rho_hat(b) = mvf(b)/max(c(b),1e-9) - 1;
end
% 基线路径单位运营价值预测(供FBR补齐Λ)
m_fore = zeros(H, NA);
for h = 1:H
    Kb = K(Yr,:) * (Dp(h)/D(Yr)); Kb(7) = K(Yr,7);
    for a = live
        m_fore(h,a) = predict(a, feat(Dp(h), ep(h), mp(h), Kb, a, kbar, cross_of), M) * c(a);
    end
end
[~, o1] = sort(rho_hat(live), 'descend');            rank_fwd = live(o1);
[~, o2] = sort(mvz(live)./max(c(live)',1e-9), 'descend'); rank_frz = live(o2);
wm.active = true; wm.adj = adj; wm.mv_fwd = mvf; wm.mv_frz = mvz; wm.rho_hat = rho_hat;
wm.m_fore = m_fore; wm.coef = coef; wm.rank_fwd = rank_fwd; wm.rank_frz = rank_frz;

names = {'训练','推理','绿电','西储','东储','HVDC','通信'};
fmt = @(rk, vals) strjoin(arrayfun(@(a) sprintf('%s%+.2f', names{a}, vals(a)), ...
                   rk(1:min(4,numel(rk))), 'Uni', 0), ' > ');
fprintf('  [VLM-WM] Y%d 前瞻学习力: %s\n', year, fmt(rank_fwd, rho_hat));
if ~isequal(rank_fwd(1:min(3,end)), rank_frz(1:min(3,end)))
    fprintf('  [VLM-WM] 前瞻与近视排序不同(近视: %s) → 前瞻修正生效\n', ...
        strjoin(names(rank_frz(1:min(3,end))), ' > '));
end
end

% ═════════════════ 局部函数 ═════════════════
function x = feat(Dv, ev, mx, Kv, a, kbar, cross_of)
ca = cross_of(a);
x = [log(Dv), log(ev), mx, log(1 + Kv(a)/(Dv*kbar(a))), log(1 + Kv(ca)/(Dv*kbar(ca)))];
end

function gh = predict(a, x, M)
xs = (x - M.mu(a,:)) ./ M.sd(a,:);
gh = min(1.0, max(-0.5, M.coef(a,:) * [1, xs]'));
end

function W = sysval(Kv, Dv, ev, mx, M)
W = 0;
for a = M.live
    W = W + predict(a, feat(Dv, ev, mx, Kv, a, M.kbar, M.cross_of), M) * M.c(a) * Kv(a);
end
end
