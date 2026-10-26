function [S, cf] = wm_sample_generator(state, AEMF, P, demand_y, year, SKU, actual_base, A_att)
%% 世界模型训练样本生成(阶段A) + 反事实边际价值(补齐创新二)
%  以当年锁定状态为基线, 对7类资产逐一追加扰动ΔK, 调用一年期实际运行模拟,
%  经资产归因得到各资产运营价值F_a, 形成(状态,容量)→价值 的转移样本。
%  反事实边际: cf_a = [ΣF(K+ΔK_a) − ΣF(K)] / ΔK_a  (万元/单位/年)
f = 0.10; if isfield(P,'wm_pert_frac'); f = P.wm_pert_frac; end
Ps = P; Ps.quiet_actual = true;
tr = task_ratio_at(year, P); mix = tr(1) + tr(2);
D = max(sum(demand_y,1)); eta = SKU.eta_token;
pm = 1; if isfield(P,'price_endo_mult'); pm = P.price_endo_mult; end
F0 = A_att.REV(year,:) - A_att.OPEX(year,:);
K0 = A_att.K(year,:);
cur0 = sum(actual_base.P_curt(:)) / max(1, sum(actual_base.P_renew(:)));
S = mk(D, eta, mix, cur0, pm, K0, F0, true, year, 0, zeros(1,7));
cf = nan(1,7);
if isfield(P,'wm_datagen') && ~P.wm_datagen; return; end
for a = 1:7
    st = state; Pa = Ps; ok = true; dK = zeros(1,7);
    switch a
        case 1; st.W_T_cum = state.W_T_cum * (1+f); dK(1) = f*sum(state.W_T_cum); ok = dK(1) > 1;
        case 2; st.W_I_cum = state.W_I_cum * (1+f); dK(2) = f*sum(state.W_I_cum); ok = dK(2) > 1;
        case 3; st.G_cum   = state.G_cum   * (1+f); dK(3) = f*sum(state.G_cum);   ok = dK(3) > 1;
        case 4; st.E_w_cum = state.E_w_cum * (1+f); dK(4) = f*sum(state.E_w_cum); ok = dK(4) > 1;
        case 5; st.E_e_cum = state.E_e_cum * (1+f); dK(5) = f*sum(state.E_e_cum); ok = dK(5) > 1;
        case 6
            ok = isfield(state,'dL_cum') && sum(state.dL_cum(:)) > 1;
            if ok; st.dL_cum = state.dL_cum * (1+f); dK(6) = f*sum(state.dL_cum(:)); end
        case 7
            ok = false;
            if isfield(state,'rt_cum') && isfield(P,'comm_delay_base')
                [~, Ur] = reach_potential(P);
                base = (state.rt_cum < 0.5) & (repmat(state.z_cum(:),1,P.N_east) > 0.5);
                [ii, jj] = find(base & (Ur > 0), 1);              % 优先: 路由可解锁B类可达
                if isempty(ii); [ii, jj] = find(base, 1); end
                if ~isempty(ii)
                    st.rt_cum(ii,jj) = 1; dK(7) = 1; ok = true;
                    Pa.comm_delay = route_delay_apply(P, st.rt_cum);
                end
            end
    end
    if ~ok; continue; end
    try
        act = simulate_actual_operation(st, AEMF, Pa, demand_y, year, SKU);
        Ra = struct('state', st, 'actual', act);
        As = compute_asset_attribution({Ra}, Pa, true);
        Fa = As.REV(1,:) - As.OPEX(1,:);
        cura = sum(act.P_curt(:)) / max(1, sum(act.P_renew(:)));
        S(end+1) = mk(D, eta, mix, cura, pm, As.K(1,:), Fa, false, year, a, dK); %#ok<AGROW>
        cf(a) = (sum(Fa) - sum(F0)) / dK(a);
    catch ME
        fprintf('     [WM样本] 资产%d扰动跳过: %s\n', a, ME.message);
    end
end
end

function s = mk(D, eta, mix, cur, pm, K, F, real, year, a, dK)
s = struct('D',D,'eta',eta,'mix',mix,'cur',cur,'pm',pm,'K',K(:)','F',F(:)', ...
           'real',real,'year',year,'a',a,'dK',dK(:)');
end
