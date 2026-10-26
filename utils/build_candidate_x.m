function x_c = build_candidate_x(x_init, state, u1, demand_y, P, year)
%% 由"首年相对增量动作u1"构造候选规划解(叠加在可行初解之上, 不低于其下界), 并加需求上界护栏
u1 = max(0, u1(:)');
x_c = x_init;
sc = @(xi, cum, u) reshape(max(xi(:), cum(:)*(1+u)), size(xi));
x_c.W_T = sc(x_init.W_T, state.W_T_cum, u1(1));
x_c.W_I = sc(x_init.W_I, state.W_I_cum, u1(2));
x_c.G   = sc(x_init.G,   state.G_cum,   u1(3));
x_c.E_w = sc(x_init.E_w, state.E_w_cum, u1(4));
x_c.E_e = sc(x_init.E_e, state.E_e_cum, u1(5));
if isfield(x_init,'dL') && isfield(state,'dL_cum') && isequal(size(x_init.dL), size(state.dL_cum))
    x_c.dL = max(x_init.dL, state.dL_cum*(1+u1(6)));
end
s_h = 0.5; if isfield(P,'hub_share_max'); s_h = P.hub_share_max; end
b_h = 400; if isfield(P,'hub_base_MW');   b_h = P.hub_base_MW;   end
for it_ = 1:3                                            % 集中度投影: 超限枢纽的增量削回
    capH = max(x_init.W_T(:), s_h*sum(x_c.W_T) + b_h);
    x_c.W_T = reshape(min(x_c.W_T(:), capH), size(x_c.W_T));
end
ubT = max([3*max(demand_y(4,:)), sum(state.W_T_cum), sum(x_init.W_T)]);
if sum(x_c.W_T) > ubT
    x_c.W_T = x_init.W_T + (x_c.W_T - x_init.W_T) * max(0, ubT - sum(x_init.W_T)) / max(1e-9, sum(x_c.W_T - x_init.W_T));
end
ubI = max([1.5*(1+P.phi_reserve)*(max(demand_y(1,:)) + 0.8*median(demand_y(2,:))), sum(state.W_I_cum), sum(x_init.W_I)]);
if sum(x_c.W_I) > ubI
    x_c.W_I = x_init.W_I + (x_c.W_I - x_init.W_I) * max(0, ubI - sum(x_init.W_I)) / max(1e-9, sum(x_c.W_I - x_init.W_I));
end
% 西储能不低于绿电配储下界(与主问题C: E_w ≥ μ_min·G·dt 一致)
if isfield(P,'mu_min') && isfield(P,'dt_stor')
    x_c.E_w = reshape(max(x_c.E_w(:), P.mu_min * x_c.G(:) * P.dt_stor), size(x_c.E_w));
end
C_ie = P.C_infer_fix * max(0.65, (1 - 0.05*min(year-1, 8)));
x_c.F1_incremental = P.C_train_fix*sum(max(0, x_c.W_T(:) - state.W_T_cum(:))) ...
    + C_ie*sum(max(0, x_c.W_I(:) - state.W_I_cum(:))) ...
    + (P.C_renew_wind + P.C_renew_pv)*1000*sum(max(0, x_c.G(:) - state.G_cum(:)))*0.5 ...
    + P.C_stor*1000*(sum(max(0, x_c.E_w(:) - state.E_w_cum(:))) + sum(max(0, x_c.E_e(:) - state.E_e_cum(:))));
end
