function [Q_s, mu_out, info] = solve_subproblem_lp_fast(x, sd, P, SKU)
%% 规划运行子问题(价值驱动网络流LP, 论文2.5节) —— 全年12个月代表周 × 168h, 稀疏矩阵直接建模
%  时间分辨率: 每月一个代表周(季节因子来自历史8760h), 小时权重=当月天数/7, 全年合计8760h;
%  任务约束: A刚性逐时、B逐时(时延门控跨域)、C按24h窗口可延期、D合同按周可调度;
%  储能按周循环; HVDC只外送绿电盈余。规划变量只出现在右端 → 对偶为精确次梯度
%  与YALMIP版同一模型; 单次求解约0.2–0.5秒(YALMIP版约5秒且随调用累积变慢)。
%  对偶 π = ∂Q/∂rhs, 规划变量只出现在右端, 故 ∂Q/∂x = Σ π·∂rhs/∂x(已用有限差分验证)。
persistent sgn_
NI = P.N_west; NJ = P.N_east; NP = NI*NJ;
T0 = size(sd.CF_renew, 2);
eta = SKU.eta_token; pueW = P.eta_PUE_west(:); pueE = P.eta_PUE_east(:);
crw = 1.0; if isfield(P,'calib_rev_west');  crw = P.calib_rev_west;  end
cal = 1.0; if isfield(P,'calib_elec_east'); cal = P.calib_elec_east; end
vA = lpick(SKU.p_R, NJ) * 0.1 * eta ./ pueE;   vB = vA;
vC = lpick(SKU.p_B, NJ) * 0.1 * eta ./ pueE;
vD = crw * lpick(SKU.p_T, NI) * 0.1 * eta ./ pueW;
sdc = 0.65; if isfield(P,'spot_token_discount'); sdc = P.spot_token_discount; end
if isfield(P,'plan_value_mode') && strcmpi(P.plan_value_mode,'uniform')
    % 对比组A-I: 不区分SKU价值层级, 各类任务按需求能量加权的统一单位算力价值
    wv_ = [sum(sd.Lambda_A(:)), sum(sd.Lambda_B(:)), sum(sd.Lambda_C(:)), sum(sd.Lambda_D(:))];
    v_uni = (mean(vA)*wv_(1) + mean(vB)*wv_(2) + mean(vC)*wv_(3) + mean(vD)*wv_(4)) / max(1e-9, sum(wv_));
    vA = v_uni*ones(NJ,1); vB = vA; vC = vA; vD = v_uni*ones(NI,1);
end
vS = sdc * vD;                                                     % 训练算力现货: 训练价×折价(与实际层一致)
vM = crw * lpick(SKU.p_B_s, NI) * 0.1 * eta ./ pueW;              % 承接C类迁移: 迁移/现货价
if isfield(P,'plan_value_mode') && strcmpi(P.plan_value_mode,'uniform'); vM = v_uni*ones(NI,1); end
loss = 0.07; if isfield(P,'hvdc_loss'); loss = P.hvdc_loss; end
cop  = 12;   if isfield(P,'c_hvdc_op'); cop = P.c_hvdc_op; end
kB   = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
sm   = 1.5;  if isfield(P,'spot_market_mult'); sm = P.spot_market_mult; end
dts  = 2;    if isfield(P,'dt_stor'); dts = max(1, P.dt_stor); end
sB = lshare(P, 'east_B_share', NJ); sC = lshare(P, 'east_C_share', NJ);
sA = sB; if isfield(P,'east_A_share'); sA = lshare(P, 'east_A_share', NJ); end
nW = 1; if isfield(P,'lp_rep_weeks') && P.lp_rep_weeks > 1 && isfield(P,'season') && ~isempty(P.season); nW = min(12, P.lp_rep_weeks); end
if nW > 1
    S = P.season; CF = []; lw = []; le = []; LA = []; LB = []; LC = []; LD = []; wh = [];
    for mm = 1:nW
        CF = [CF, min(0.98, sd.CF_renew .* (S.cf(mm,:)' * ones(1,T0)))]; %#ok<AGROW>
        lw = [lw, sd.lam_w .* (S.pw(mm,:)' * ones(1,T0))];             %#ok<AGROW>
        le = [le, sd.lam_e .* (S.pe(mm,:)' * ones(1,T0))];             %#ok<AGROW>
        LA = [LA, sd.Lambda_A(:)' * S.dem(mm)]; LB = [LB, sd.Lambda_B(:)' * S.dem(mm)]; %#ok<AGROW>
        LC = [LC, sd.Lambda_C(:)' * S.dem(mm)]; LD = [LD, sd.Lambda_D(:)' * S.dem(mm)]; %#ok<AGROW>
        wh = [wh, (S.days(mm)/7) * ones(1,T0)];                          %#ok<AGROW>
    end
else
    CF = sd.CF_renew; lw = sd.lam_w; le = sd.lam_e;
    LA = sd.Lambda_A(:)'; LB = sd.Lambda_B(:)'; LC = sd.Lambda_C(:)'; LD = sd.Lambda_D(:)';
    wh = (8760/T0) * ones(1,T0);
end
T = size(CF,2);
wk = ceil((1:T)/T0);                                   % 所属代表周
prevh = (wk-1)*T0 + mod((1:T) - (wk-1)*T0 - 2, T0) + 1; % 周内循环的上一小时
if mod(T0,24) == 0; dy = ceil((1:T)/24); else; dy = wk; end   % C类24h窗口(典型周非24倍数时退化为周窗口)
nD = max(dy);
emax = max(le(:)) / 1e4;                                    % 多周电价序列构造之后再取最高价
piA = 3.0*vA + 2*emax; piB = 1.5*vB + 1.5*emax; piC = 1.2*vC + emax;
ii = repmat((1:NI)', NJ, 1); jj = kron((1:NJ)', ones(NI,1));          % 通道p=(i,j), i变化最快
% 时延可达与通信成本
dB = 20; if isfield(P,'d_max_B_mig'); dB = P.d_max_B_mig; end
if isfield(P,'plan_d_max_B') && ~isempty(P.plan_d_max_B); dB = P.plan_d_max_B; end   % 规划者假设的时延门限(A-I用固定工程值)
dred = 0.4; if isfield(P,'route_delay_reduction'); dred = P.route_delay_reduction; end
D0 = []; if isfield(P,'comm_delay_base'); D0 = P.comm_delay_base; elseif isfield(P,'comm_delay'); D0 = P.comm_delay; end
b0 = zeros(NP,1); bu = zeros(NP,1); cc = 0.002*ones(NP,1);
if ~isempty(D0) && size(D0,1) >= NI+NJ
    for p = 1:NP
        d = D0(ii(p), NI+jj(p)); b0(p) = d <= dB; bu(p) = (~b0(p)) && d*(1-dred) <= dB;
        cc(p) = max(0.001, 0.002 + 0.0003*(d - 5));
    end
end
if isfield(P,'enable_B_reach') && ~P.enable_B_reach; b0(:) = 0; bu(:) = 0; end
if isfield(P,'enable_route_invest') && ~P.enable_route_invest; bu(:) = 0; end
% 规划变量取值
WT = x.W_T(:); WI = x.W_I(:); G = x.G(:); Ew = x.E_w(:); Ee = x.E_e(:); z = double(x.z(:) > 0.5);
dL = zeros(NP,1); if isfield(x,'dL') && numel(x.dL) == NP; dL = x.dL(:); end
rt = zeros(NP,1); if isfield(x,'rt') && numel(x.rt) == NP; rt = x.rt(:); end
HV0 = P.HVDC_cap_per_node(:);
% ── 变量块 ──
K = struct('dT',1,'sp',2,'pg',3,'pc',4,'cw',5,'ow',6,'sw',7,'cm',8,'bo',9,'h',10, ...
           'a',11,'ua',12,'bl',13,'ub',14,'cl',15,'uc',16,'pe',17,'ce',18,'oe',19,'se',20);
br  = [NI NI NI NI NI NI NI NP NP NP NJ NJ NJ NJ NJ NJ NJ NJ NJ NJ];
off = [0 cumsum(br(1:end-1)*T)]; n = sum(br)*T;
ix  = @(b, r, t) off(b) + r + (t-1)*br(b);
[Ii, Ti] = ndgrid(1:NI, 1:T); Ii = Ii(:); Ti = Ti(:);
[Pp, Tp] = ndgrid(1:NP, 1:T); Pp = Pp(:); Tp = Tp(:);
[Jj, Tj] = ndgrid(1:NJ, 1:T); Jj = Jj(:); Tj = Tj(:);
nIT = NI*T; nPT = NP*T; nJT = NJ*T;
RR = {}; CC = {}; VV = {}; rhs = {}; sen = {}; seg = struct(); m = 0;
    function r0 = newrows(k, s, rh, tg)
        r0 = m + 1; m = m + k; rhs{end+1} = rh(:); sen{end+1} = repmat(s, k, 1); seg.(tg) = r0:(r0+k-1);
    end
    function add(rr, cl, vv)
        RR{end+1} = rr(:); CC{end+1} = cl(:); VV{end+1} = vv(:);
    end
% R1 西部算力容量
r0 = newrows(nIT, '<', WT(Ii), 'capW'); rr = r0 - 1 + (1:nIT)';
add(rr, ix(K.dT,Ii,Ti), ones(nIT,1)); add(rr, ix(K.sp,Ii,Ti), ones(nIT,1));
rp = r0 - 1 + ii(Pp) + (Tp-1)*NI;
add(rp, ix(K.cm,Pp,Tp), ones(nPT,1)); add(rp, ix(K.bo,Pp,Tp), ones(nPT,1));
% R2 西部功率平衡(右端 = G·CF)
r0 = newrows(nIT, '=', G(Ii).*CF(sub2ind(size(CF),Ii,Ti)), 'balW'); rr = r0 - 1 + (1:nIT)';
add(rr, ix(K.dT,Ii,Ti), 1); add(rr, ix(K.sp,Ii,Ti), 1); add(rr, ix(K.cw,Ii,Ti), 1); add(rr, ix(K.pc,Ii,Ti), 1);
add(rr, ix(K.pg,Ii,Ti), -1); add(rr, ix(K.ow,Ii,Ti), -1);
rp = r0 - 1 + ii(Pp) + (Tp-1)*NI;
add(rp, ix(K.cm,Pp,Tp), 1); add(rp, ix(K.bo,Pp,Tp), 1); add(rp, ix(K.h,Pp,Tp), 1);
% R3–R6 西部储能
Tm = prevh(Ti)';
r0 = newrows(nIT, '=', zeros(nIT,1), 'socW'); rr = r0 - 1 + (1:nIT)';
add(rr, ix(K.sw,Ii,Ti), 1); add(rr, ix(K.sw,Ii,Tm), -1); add(rr, ix(K.cw,Ii,Ti), -0.95); add(rr, ix(K.ow,Ii,Ti), 1/0.95);
r0 = newrows(nIT, '<', Ew(Ii), 'EwS');     add(r0 - 1 + (1:nIT)', ix(K.sw,Ii,Ti), 1);
r0 = newrows(nIT, '<', Ew(Ii)/dts, 'EwC'); add(r0 - 1 + (1:nIT)', ix(K.cw,Ii,Ti), 1);
r0 = newrows(nIT, '<', Ew(Ii)/dts, 'EwD'); add(r0 - 1 + (1:nIT)', ix(K.ow,Ii,Ti), 1);
% R7 HVDC通道
r0 = newrows(nPT, '<', HV0(Pp).*z(ii(Pp)) + dL(Pp), 'hv'); add(r0 - 1 + (1:nPT)', ix(K.h,Pp,Tp), 1);
% R7b HVDC只外送绿电盈余: 负荷+外送+充电−放电 ≤ 绿电出力(等价于外送时不购网电; 实际运行层同规则)
r0 = newrows(nIT, '<', G(Ii).*CF(sub2ind(size(CF),Ii,Ti)), 'hvG'); rr = r0 - 1 + (1:nIT)';
add(rr, ix(K.dT,Ii,Ti), 1); add(rr, ix(K.sp,Ii,Ti), 1); add(rr, ix(K.cw,Ii,Ti), 1); add(rr, ix(K.ow,Ii,Ti), -1);
rp = r0 - 1 + ii(Pp) + (Tp-1)*NI;
add(rp, ix(K.cm,Pp,Tp), 1); add(rp, ix(K.bo,Pp,Tp), 1); add(rp, ix(K.h,Pp,Tp), 1);
% R8–R10 训练合同(周内可调)与现货
LDw = accumarray(wk(:), LD(:), [nW 1]); LDm = accumarray(wk(:), LD(:), [nW 1], @max);
r0 = newrows(nW, '<', LDw, 'Den');                add(r0 - 1 + wk(Ti)', ix(K.dT,Ii,Ti), 1);
r0 = newrows(T, '<', LD(:), 'Dhr');               add(r0 - 1 + Ti, ix(K.dT,Ii,Ti), 1);   % 逐时不超过D类需求
r0 = newrows(T, '<', sm*LD(:), 'spot');           add(r0 - 1 + Ti, ix(K.sp,Ii,Ti), 1);   % 现货逐时上限(与实际层一致)
% R11 A类刚性
r0 = newrows(nJT, '=', sA(Jj).*LA(Tj)', 'A'); rr = r0 - 1 + (1:nJT)';
add(rr, ix(K.a,Jj,Tj), 1); add(rr, ix(K.ua,Jj,Tj), 1);
% R12 B类: 本地 + 跨域 + 未服务
r0 = newrows(nJT, '=', sB(Jj).*LB(Tj)', 'B'); rr = r0 - 1 + (1:nJT)';
add(rr, ix(K.bl,Jj,Tj), 1); add(rr, ix(K.ub,Jj,Tj), 1); add(r0 - 1 + jj(Pp) + (Tp-1)*NJ, ix(K.bo,Pp,Tp), 1);
% R13 B类跨域受时延可达门控(右端线性于 z 与路由)
r0 = newrows(nPT, '<', kB*(b0(Pp).*z(ii(Pp)) + bu(Pp).*rt(Pp)).*sB(jj(Pp)).*LB(Tp)', 'boR');
add(r0 - 1 + (1:nPT)', ix(K.bo,Pp,Tp), 1);
% R14 C类周内能量平衡
LCd = accumarray(dy(:), LC(:), [nD 1]);
rhsC = sC * LCd';                                        % NJ×nD
r0 = newrows(NJ*nD, '=', rhsC(:), 'C');
add(r0 - 1 + Jj + (dy(Tj)'-1)*NJ, ix(K.cl,Jj,Tj), 1); add(r0 - 1 + Jj + (dy(Tj)'-1)*NJ, ix(K.uc,Jj,Tj), 1);
add(r0 - 1 + jj(Pp) + (dy(Tp)'-1)*NJ, ix(K.cm,Pp,Tp), 1);
% R15 C类迁移仅至已选西部节点
r0 = newrows(nPT, '<', 3*z(ii(Pp)).*sC(jj(Pp)).*LC(Tp)', 'cmZ'); add(r0 - 1 + (1:nPT)', ix(K.cm,Pp,Tp), 1);
% R15b 迁移/跨域份额上限: 取实际运行实现的份额(逐年校准), 避免规划LP把东部负荷过度西移
psC = 0.3;  if isfield(P,'lp_mig_share');  psC = P.lp_mig_share;  end
psB = kB;   if isfield(P,'lp_boff_share'); psB = P.lp_boff_share; end
r0 = newrows(NJ, '<', psC*sC*sum(LC), 'cmCap'); add(r0 - 1 + jj(Pp), ix(K.cm,Pp,Tp), 1);
r0 = newrows(NJ, '<', psB*sB*sum(LB), 'boCap'); add(r0 - 1 + jj(Pp), ix(K.bo,Pp,Tp), 1);
% R16 东部推理容量
r0 = newrows(nJT, '<', WI(Jj), 'capE'); rr = r0 - 1 + (1:nJT)';
add(rr, ix(K.a,Jj,Tj), 1); add(rr, ix(K.bl,Jj,Tj), 1); add(rr, ix(K.cl,Jj,Tj), 1);
% R17 东部购电
r0 = newrows(nJT, '<', zeros(nJT,1), 'pwE'); rr = r0 - 1 + (1:nJT)';
add(rr, ix(K.a,Jj,Tj), 1); add(rr, ix(K.bl,Jj,Tj), 1); add(rr, ix(K.cl,Jj,Tj), 1);
add(rr, ix(K.ce,Jj,Tj), 1); add(rr, ix(K.oe,Jj,Tj), -1); add(rr, ix(K.pe,Jj,Tj), -1);
% R18–R21 东部储能
Tmj = prevh(Tj)';
r0 = newrows(nJT, '=', zeros(nJT,1), 'socE'); rr = r0 - 1 + (1:nJT)';
add(rr, ix(K.se,Jj,Tj), 1); add(rr, ix(K.se,Jj,Tmj), -1); add(rr, ix(K.ce,Jj,Tj), -0.95); add(rr, ix(K.oe,Jj,Tj), 1/0.95);
r0 = newrows(nJT, '<', Ee(Jj), 'EeS');     add(r0 - 1 + (1:nJT)', ix(K.se,Jj,Tj), 1);
rbk = 0.8; if isfield(P,'east_backup_reserve'); rbk = P.east_backup_reserve; end
r0 = newrows(nJT, '<', -rbk*Ee(Jj), 'EeR'); add(r0 - 1 + (1:nJT)', ix(K.se,Jj,Tj), -1);   % SOC ≥ 备用保有率×容量
r0 = newrows(nJT, '<', Ee(Jj)/dts, 'EeC'); add(r0 - 1 + (1:nJT)', ix(K.ce,Jj,Tj), 1);
r0 = newrows(nJT, '<', Ee(Jj)/dts, 'EeD'); add(r0 - 1 + (1:nJT)', ix(K.oe,Jj,Tj), 1);
% 组装
rI = []; cI = []; vI = [];
for q = 1:numel(RR)
    vq = VV{q}; if numel(vq) == 1; vq = vq*ones(numel(RR{q}),1); end
    rI = [rI; RR{q}]; cI = [cI; CC{q}]; vI = [vI; vq]; %#ok<AGROW>
end
A = sparse(rI, cI, vI, m, n); b = vertcat(rhs{:}); s = vertcat(sen{:});
% 目标(万元/年)
cvec = zeros(n,1);
    function setc(bk, M)
        cvec(off(bk)+1 : off(bk)+br(bk)*T) = M(:);
    end
WI_ = ones(NI,1)*wh; WP_ = ones(NP,1)*wh; WJ_ = ones(NJ,1)*wh;
setc(K.dT, -vD*wh); setc(K.sp, -vS*wh); setc(K.pg, (lw/1e4).*WI_);
setc(K.cm, (cc - vM(ii))*wh); setc(K.bo, (cc - vB(jj))*wh);
setc(K.h, -((le(jj,:)*(1-loss) - cop)/1e4).*WP_);
setc(K.a, -vA*wh); setc(K.ua, piA*wh); setc(K.bl, -vB*wh); setc(K.ub, piB*wh);
setc(K.cl, -vC*wh); setc(K.uc, piC*wh); setc(K.pe, (cal*le/1e4).*WJ_);
% 求解: Gurobi(π=∂obj/∂rhs) 或 linprog(π=−λ)
lpkey = sprintf('%d|%.6f|%.6f', T, sum(CF(:)) + sum(LA) + sum(LD), sum(le(:)) + sum(cvec));
[xs, Q_s, pi, ok] = lp_solve(cvec, A, b, s, lpkey);
if ~ok
    Q_s = 1e6; mu_out = struct('grad', []); info = struct('Q_west',0,'Q_east',0,'Q_route',0,'east_dbg',zeros(1,6),'lp_fail',1);
    return;
end
Ps = @(tg) pi(seg.(tg));
g.W_T = sum(reshape(Ps('capW'), NI, T), 2);
g.G   = sum(reshape(Ps('balW'), NI, T) .* CF, 2) + sum(reshape(Ps('hvG'), NI, T) .* CF, 2);
g.E_w = sum(reshape(Ps('EwS'), NI, T), 2) + sum(reshape(Ps('EwC') + Ps('EwD'), NI, T), 2) / dts;
hv    = sum(reshape(Ps('hv'), NP, T), 2);  g.dL = reshape(hv, NI, NJ);
boR   = reshape(Ps('boR'), NP, T); cmZ = reshape(Ps('cmZ'), NP, T);
gz = zeros(NI,1); grt = zeros(NP,1);
for p = 1:NP
    gz(ii(p)) = gz(ii(p)) + hv(p)*HV0(p) + sum(boR(p,:) .* (kB*b0(p)*sB(jj(p))*LB)) + sum(cmZ(p,:) .* (3*sC(jj(p))*LC));
    grt(p) = sum(boR(p,:) .* (kB*bu(p)*sB(jj(p))*LB));
end
g.z = gz; g.rt = reshape(grt, NI, NJ);
g.W_I = sum(reshape(Ps('capE'), NJ, T), 2);
g.E_e = sum(reshape(Ps('EeS'), NJ, T), 2) + sum(reshape(Ps('EeC') + Ps('EeD'), NJ, T), 2) / dts ...
      - rbk * sum(reshape(Ps('EeR'), NJ, T), 2);
% 一次性有限差分符号校验(对 G, 其梯度精确)
if isempty(sgn_)
    [gm, k] = max(abs(g.G));
    if gm > 1e-6
        dx = max(1, 0.02*G(k)); rows_k = seg.balW(Ii == k);
        rows_k2 = seg.hvG(Ii == k);
        b2 = b; b2(rows_k) = b2(rows_k) + dx * CF(k, Ti(Ii == k))'; b2(rows_k2) = b2(rows_k2) + dx * CF(k, Ti(Ii == k))';
        [~, Q2, ~, ok2] = lp_solve(cvec, A, b2, s, '');
        if ok2
            fd = (Q2 - Q_s)/dx;
            if abs(fd) > 1e-3*gm
                sgn_ = sign(fd)*sign(g.G(k));
                fprintf('  [LP对偶校验] G(%d): 有限差分%.2f / 对偶%.2f → 符号%+d(已固化)\n', k, fd, g.G(k), sgn_);
            end
        end
    end
end
sg = 1; if ~isempty(sgn_); sg = sgn_; end
fn = fieldnames(g); for q = 1:numel(fn); g.(fn{q}) = sg * g.(fn{q}); end
mu_out = struct('grad', g);
% 分解量(按小时权重折算为全年)
V  = @(bk) reshape(xs(off(bk)+1 : off(bk)+br(bk)*T), br(bk), T);
ws = @(M) sum(sum(M .* (ones(size(M,1),1)*wh)));
eRev = [ws((vA*ones(1,T)).*V(K.a)), ws((vB*ones(1,T)).*V(K.bl)), ws((vC*ones(1,T)).*V(K.cl)), 0, ...
        ws((vB(jj)*ones(1,T)).*V(K.bo)), cal*ws(le.*V(K.pe))/1e4];
revH = ws(V(K.h) .* ((le(jj,:)*(1-loss) - cop)/1e4));
info = struct();
info.east_dbg  = eRev;
info.Q_east    = cal*ws(le.*V(K.pe))/1e4 + ws((piA*ones(1,T)).*V(K.ua)) + ws((piB*ones(1,T)).*V(K.ub)) ...
                 + ws((piC*ones(1,T)).*V(K.uc)) - sum(eRev(1:5));
info.Q_west    = ws(lw.*V(K.pg))/1e4 - ws((vD*ones(1,T)).*V(K.dT)) - ws((vS*ones(1,T)).*V(K.sp)) - revH;
info.Q_route   = ws((cc*ones(1,T)).*(V(K.bo) + V(K.cm))) - ws((vM(ii)*ones(1,T)).*V(K.cm));
info.n_hours   = T; info.n_weeks = nW;
info.QW_primal = info.Q_west; info.lp = true;
end

function [xs, f, pi, ok] = lp_solve(c, A, b, s, key)
persistent has_grb bas
global LP_STATS
t0_ = tic;
if isempty(LP_STATS); LP_STATS = struct('n',0,'t',0,'fail',0,'solver','','nnz',0,'nvar',0); end
LP_STATS.n = LP_STATS.n + 1; LP_STATS.nnz = nnz(A); LP_STATS.nvar = numel(c);
if isempty(has_grb); has_grb = exist('gurobi','file') == 2 || exist('gurobi','file') == 3; end
xs = []; f = NaN; pi = []; ok = false;
if has_grb
    model.A = A; model.obj = c; model.rhs = b; model.sense = s; model.lb = zeros(size(c));
    model.modelsense = 'min';
    if isempty(bas); bas = containers.Map('KeyType','char','ValueType','any'); end
    if nargin >= 5 && ~isempty(key) && isKey(bas, key) && lp_warm_on()
        bb = bas(key);
        if numel(bb.v) == numel(c) && numel(bb.c) == numel(b); model.vbasis = bb.v; model.cbasis = bb.c; end
    end
    prm.OutputFlag = 0; prm.Method = 1;                  % 对偶单纯形, 对偶值稳定
    global GRB_THREADS
    if ~isempty(GRB_THREADS) && GRB_THREADS > 0; prm.Threads = GRB_THREADS; end   % 并行实验时限制线程
    try
        r = gurobi(model, prm);
        if strcmp(r.status, 'OPTIMAL'); xs = r.x; f = r.objval; pi = r.pi; ok = true; end
        if ok && nargin >= 5 && ~isempty(key) && isfield(r,'vbasis') && isfield(r,'cbasis')
            if bas.Count > 64; bas = containers.Map('KeyType','char','ValueType','any'); end
            bas(key) = struct('v', r.vbasis, 'c', r.cbasis);
        end
        LP_STATS.solver = 'gurobi'; LP_STATS.t = LP_STATS.t + toc(t0_); LP_STATS.fail = LP_STATS.fail + ~ok;
        return;
    catch
        has_grb = false;
    end
end
iL = s == '<'; iE = s == '=';
opt = optimoptions('linprog', 'Algorithm', 'dual-simplex', 'Display', 'none');
[xs, f, ef, ~, lam] = linprog(c, A(iL,:), b(iL), A(iE,:), b(iE), zeros(size(c)), [], opt);
if ef == 1
    pi = zeros(size(b)); pi(iL) = -lam.ineqlin; pi(iE) = -lam.eqlin; ok = true;
end
LP_STATS.solver = 'linprog'; LP_STATS.t = LP_STATS.t + toc(t0_); LP_STATS.fail = LP_STATS.fail + ~ok;
end

function v = lpick(p, n)
p = p(:); if numel(p) >= n; v = p(1:n); else; v = mean(p) * ones(n,1); end
end
function s = lshare(P, f, n)
if isfield(P, f) && numel(P.(f)) >= n; s = P.(f)(1:n); s = s(:) / sum(s); else; s = ones(n,1)/n; end
end

function tf = lp_warm_on()
global LP_WARM
tf = ~isempty(LP_WARM) && LP_WARM;
end
