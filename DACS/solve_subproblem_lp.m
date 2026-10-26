function [Q_s, mu_out, info] = solve_subproblem_lp(x, sd, P, SKU)
%% 线性化运行子问题: 价值驱动网络流LP(论文2.5节)
%  容量与选址作为右端参数 → 其对偶即运行成本对规划变量的精确次梯度, Benders割精确有效,
%  主问题(MILP)+子问题(LP)的分解在有限步内收敛, gap可收敛到容差。
%  详细运行(三模式、Sinkhorn迁移、8760h)仍由实际运行层承担, 用于校验与价值分析。
%  输出: Q_s 年运行成本(万元, 负=盈利); mu_out.grad 为 ∂Q/∂x; info 为分解量
persistent sgn_
yalmip('clear');
NI = P.N_west; NJ = P.N_east;
T  = size(sd.CF_renew, 2); Wy = 8760 / T;                       % 典型时段 → 全年
eta = SKU.eta_token;
pueW = P.eta_PUE_west(:); pueE = P.eta_PUE_east(:);
pick = @(v, n) local_pick(v, n);
% ── 单位设施电量的服务价值(万元/MWh) ──
vA = pick(SKU.p_R, NJ) * 0.1 * eta ./ pueE;
vB = vA;
vC = pick(SKU.p_B, NJ) * 0.1 * eta ./ pueE;                       % C批量: 批量价
vD = crw * pick(SKU.p_T, NI) * 0.1 * eta ./ pueW;
vS = crw * pick(SKU.p_B_s, NI) * 0.1 * eta ./ pueW;             % 现货/迁移价
vM = vS;
emax = max(sd.lam_e(:)) / 1e4;                                   % 最高东部电价(万元/MWh)
piA = 3.0*vA + 2*emax; piB = 1.5*vB + 1.5*emax; piC = 1.2*vC + emax;   % SLA违约罚 > 服务价值+电价
loss = 0.07; if isfield(P,'hvdc_loss'); loss = P.hvdc_loss; end
cop  = 12;   if isfield(P,'c_hvdc_op'); cop = P.c_hvdc_op; end   % 元/MWh
kB   = 0.35; if isfield(P,'kappa_B_mig'); kB = P.kappa_B_mig; end
sm   = 1.5;  if isfield(P,'spot_market_mult'); sm = P.spot_market_mult; end
cal  = 1.0;  if isfield(P,'calib_elec_east'); cal = P.calib_elec_east; end
crw  = 1.0;  if isfield(P,'calib_rev_west');  crw = P.calib_rev_west;  end
dts  = 2;    if isfield(P,'dt_stor'); dts = max(1, P.dt_stor); end
% ── 需求分配 ──
sB = local_share(P, 'east_B_share', NJ); sC = local_share(P, 'east_C_share', NJ);
sA = local_share(P, 'east_A_share', NJ); if ~isfield(P,'east_A_share'); sA = sB; end
LA = sd.Lambda_A(:)'; LB = sd.Lambda_B(:)'; LC = sd.Lambda_C(:)'; LD = sd.Lambda_D(:)';
lw = sd.lam_w; le = sd.lam_e; CF = sd.CF_renew;
% ── 时延可达(B类): 基准可达 β0 与"建路由后可达" βu ──
dB = 20; if isfield(P,'d_max_B_mig'); dB = P.d_max_B_mig; end
D0 = []; if isfield(P,'comm_delay_base'); D0 = P.comm_delay_base; elseif isfield(P,'comm_delay'); D0 = P.comm_delay; end
b0 = zeros(NI,NJ); bu = zeros(NI,NJ); cc = 0.002*ones(NI,NJ);
dred = 0.4; if isfield(P,'route_delay_reduction'); dred = P.route_delay_reduction; end
if ~isempty(D0) && size(D0,1) >= NI+NJ
    for i = 1:NI
        for j = 1:NJ
            d = D0(i, NI+j); b0(i,j) = d <= dB; bu(i,j) = ~b0(i,j) && d*(1-dred) <= dB;
            cc(i,j) = max(0.001, 0.002 + 0.0003*(d - 5));         % 通信成本(万元/MWh)
        end
    end
end
if isfield(P,'enable_B_reach') && ~P.enable_B_reach; b0(:) = 0; bu(:) = 0; end
if isfield(P,'enable_route_invest') && ~P.enable_route_invest; bu(:) = 0; end
% ── 规划变量(右端参数, 以等式固定以取对偶) ──
xWT = x.W_T(:); xWI = x.W_I(:); xG = x.G(:); xEw = x.E_w(:); xEe = x.E_e(:);
xz = double(x.z(:) > 0.5); xdL = zeros(NI,NJ); if isfield(x,'dL') && isequal(size(x.dL),[NI NJ]); xdL = x.dL; end
xrt = zeros(NI,NJ); if isfield(x,'rt') && isequal(size(x.rt),[NI NJ]); xrt = x.rt; end
WT = sdpvar(NI,1); WI = sdpvar(NJ,1); Gv = sdpvar(NI,1); Ew = sdpvar(NI,1); Ee = sdpvar(NJ,1);
zv = sdpvar(NI,1); HV = sdpvar(NI,NJ,'full'); RT = sdpvar(NI,NJ,'full');
F1 = [WT == xWT]; F2 = [WI == xWI]; F3 = [Gv == xG]; F4 = [Ew == xEw]; F5 = [Ee == xEe];
F6 = [zv == xz];  F7 = [HV(:) == xdL(:)]; F8 = [RT(:) == xrt(:)];
% ── 运行变量 ──
NP = NI*NJ; ii = repmat((1:NI)', NJ, 1); jj = kron((1:NJ)', ones(NI,1));   % 通道p=(i,j)
Si = sparse(ii, 1:NP, 1, NI, NP); Sj = sparse(jj, 1:NP, 1, NJ, NP);
dT = sdpvar(NI,T,'full'); sp = sdpvar(NI,T,'full'); pg = sdpvar(NI,T,'full'); pc = sdpvar(NI,T,'full');
cw = sdpvar(NI,T,'full'); ow = sdpvar(NI,T,'full'); sw = sdpvar(NI,T,'full');
cm = sdpvar(NP,T,'full'); bo = sdpvar(NP,T,'full'); h  = sdpvar(NP,T,'full');
a  = sdpvar(NJ,T,'full'); ua = sdpvar(NJ,T,'full'); bl = sdpvar(NJ,T,'full'); ub = sdpvar(NJ,T,'full');
cl = sdpvar(NJ,T,'full'); uc = sdpvar(NJ,T,'full'); pe = sdpvar(NJ,T,'full');
ce = sdpvar(NJ,T,'full'); oe = sdpvar(NJ,T,'full'); se = sdpvar(NJ,T,'full');
C = [dT >= 0, sp >= 0, pg >= 0, pc >= 0, cw >= 0, ow >= 0, sw >= 0, cm >= 0, bo >= 0, h >= 0, ...
     a >= 0, ua >= 0, bl >= 0, ub >= 0, cl >= 0, uc >= 0, pe >= 0, ce >= 0, oe >= 0, se >= 0];
oT = ones(1,T);
% 西部: 算力容量、功率平衡、储能、HVDC
C = [C, dT + sp + Si*cm + Si*bo <= WT*oT];
C = [C, (Gv*oT).*CF + pg + ow == dT + sp + Si*cm + Si*bo + cw + pc + Si*h];
C = [C, sw(:,2:T) == sw(:,1:T-1) + 0.95*cw(:,2:T) - ow(:,2:T)/0.95, sw(:,1) == sw(:,T) + 0.95*cw(:,1) - ow(:,1)/0.95];
C = [C, sw <= Ew*oT, cw <= (Ew/dts)*oT, ow <= (Ew/dts)*oT];
capH = HV(:) + P.HVDC_cap_per_node(:) .* zv(ii);
C = [C, h <= capH*oT];
% 训练合同(周内可调度) + 现货上限
C = [C, sum(dT(:)) <= sum(LD), sum(dT,1) <= 1.5*max(LD)*oT, sum(sp(:)) <= sm*sum(LD)];
% 东部: A刚性、B本地+跨域(时延门控)、C本地+迁移(周内能量平衡)
C = [C, a + ua == sA*LA];
C = [C, bl + Sj*bo + ub == sB*LB];
R = b0(:) .* zv(ii) + bu(:) .* RT(:);                              % 可达度(线性于z、路由)
C = [C, bo <= ((kB * R) * oT) .* (sB(jj) * LB)];
C = [C, sum(cl,2) + Sj*sum(cm,2) + sum(uc,2) == sC*sum(LC)];
C = [C, cm <= (zv(ii)*oT) .* (sC(jj)*LC) * 3];                    % 仅已选西部节点可承接迁移
C = [C, a + bl + cl <= WI*oT];
C = [C, pe >= a + bl + cl + ce - oe];
C = [C, se(:,2:T) == se(:,1:T-1) + 0.95*ce(:,2:T) - oe(:,2:T)/0.95, se(:,1) == se(:,T) + 0.95*ce(:,1) - oe(:,1)/0.95];
C = [C, se <= Ee*oT, ce <= (Ee/dts)*oT, oe <= (Ee/dts)*oT];
% ── 目标(万元/年) ──
leP = le(jj,:);                                                     % 通道对应东部电价
revH = sum(sum(h .* ((leP*(1-loss) - cop)/1e4)));
rev  = sum(sum((vA*oT).*a)) + sum(sum((vB*oT).*bl)) + sum(sum((vB(jj)*oT).*bo)) + sum(sum((vC*oT).*cl)) ...
     + sum(sum((vM(ii)*oT).*cm)) + sum(sum((vD*oT).*dT)) + sum(sum((vS*oT).*sp)) + revH;
cost = sum(sum(lw.*pg))/1e4 + cal*sum(sum(le.*pe))/1e4 + sum(sum((cc(:)*oT).*(bo + cm))) ...
     + sum(sum((piA*oT).*ua)) + sum(sum((piB*oT).*ub)) + sum(sum((piC*oT).*uc));
obj = Wy * (cost - rev);
ops = sdpsettings('verbose', 0, 'cachesolvers', 1);
if isfield(P,'solver_lp'); ops = sdpsettings(ops, 'solver', P.solver_lp); end
Fx = [F1, F2, F3, F4, F5, F6, F7, F8];
dg = optimize([Fx, C], obj, ops);
if dg.problem ~= 0
    Q_s = 1e6; mu_out = struct('grad', []); info = struct('Q_west',0,'Q_east',0,'Q_route',0,'east_dbg',zeros(1,6),'lp_fail',dg.problem);
    return;
end
Q_s = value(obj);
gr = struct('W_T', dual(F1), 'W_I', dual(F2), 'G', dual(F3), 'E_w', dual(F4), 'E_e', dual(F5), ...
            'z', dual(F6), 'dL', reshape(dual(F7), NI, NJ), 'rt', reshape(dual(F8), NI, NJ));
% ── 对偶符号校验(有限差分): 保证 grad = ∂Q/∂x; 仅在结论明确时固化, 否则下次调用再验 ──
sg_use = 1; if ~isempty(sgn_); sg_use = sgn_; end
if isempty(sgn_)
    try
        cand_f = {'W_I','W_T','G'}; best_ = 0; fld = ''; k = 0;
        for q = 1:3
            v_ = abs(gr.(cand_f{q})); [m_, kk_] = max(v_);
            if m_ > best_; best_ = m_; fld = cand_f{q}; k = kk_; end
        end
        if best_ > 1e-6
            x2v = x.(fld)(:); dx = max(1, 0.02*abs(x2v(k))); x2v(k) = x2v(k) + dx;
            switch fld
                case 'W_I'; Fx2 = [F1, WI == x2v, F3, F4, F5, F6, F7, F8];
                case 'W_T'; Fx2 = [WT == x2v, F2, F3, F4, F5, F6, F7, F8];
                otherwise;  Fx2 = [F1, F2, Gv == x2v, F4, F5, F6, F7, F8];
            end
            dg2 = optimize([Fx2, C], obj, ops);
            if dg2.problem == 0
                fd = (value(obj) - Q_s) / dx; an = gr.(fld)(k);
                if abs(fd) > 1e-3*abs(an) && abs(an) > 1e-6
                    sgn_ = sign(fd) * sign(an); sg_use = sgn_;
                    fprintf('  [LP对偶校验] %s(%d): 有限差分%.2f / 对偶%.2f → 符号%+d(已固化)\n', fld, k, fd, an, sgn_);
                end
            end
            optimize([Fx, C], obj, ops); Q_s = value(obj);       % 恢复原点解(后续分解量取原点)
        end
    catch
    end
end
fn = fieldnames(gr); for q = 1:numel(fn); gr.(fn{q}) = sg_use * gr.(fn{q}); end
mu_out = struct('grad', gr);
% ── 分解量(与原子问题输出字段一致) ──
eRev = [sum(sum((vA*oT).*value(a))), sum(sum((vB*oT).*value(bl))), sum(sum((vC*oT).*value(cl))), 0, ...
        sum(sum((vB(jj)*oT).*value(bo))), cal*sum(sum(le.*value(pe)))/1e4] * Wy;
info = struct();
info.east_dbg = eRev;                                              % [A B C 调峰 B跨域 电费]
info.Q_east   = Wy*(cal*sum(sum(le.*value(pe)))/1e4 + sum(sum((piA*oT).*value(ua))) + sum(sum((piB*oT).*value(ub))) ...
                + sum(sum((piC*oT).*value(uc)))) - sum(eRev(1:5));
info.Q_west   = Wy*(sum(sum(lw.*value(pg)))/1e4 - sum(sum((vD*oT).*value(dT))) - sum(sum((vS*oT).*value(sp))) - value(revH));
info.Q_route  = Wy*(sum(sum((cc(:)*oT).*(value(bo) + value(cm)))) - sum(sum((vM(ii)*oT).*value(cm))));
info.QW_primal = info.Q_west; info.lp = true;
end

function v = local_pick(p, n)
p = p(:); if numel(p) >= n; v = p(1:n); else; v = mean(p) * ones(n,1); end
end
function s = local_share(P, f, n)
if isfield(P, f) && numel(P.(f)) >= n; s = P.(f)(1:n); s = s(:) / sum(s(1:n)); else; s = ones(n,1)/n; end
end
