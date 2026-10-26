function cf = shapley_marginal(state, AEMF, P, demand_y, year, SKU)
%% 对比组B-II: Shapley值分摊的资产边际价值(静态, 不做前后递演)
%  参与者 = 本年已有容量的资产类别; 联盟S中的资产容量各增加10%, 其余保持现值;
%  v(S) = 8760h实际运行的系统运营价值; φ_a = Σ_S |S|!(n−|S|−1)!/n!·[v(S∪a) − v(S)];
%  返回 cf(a) = φ_a / ΔK_a (万元/单位·年), 与反事实边际同单位, 便于在规划中直接替换
NA = 7; cf = nan(1, NA); f = 0.10;
K = [sum(state.W_T_cum), sum(state.W_I_cum), sum(state.G_cum), sum(state.E_w_cum), sum(state.E_e_cum), 0, 0];
if isfield(state,'dL_cum'); K(6) = sum(state.dL_cum(:)); end
players = find(K(1:6) > 1); n = numel(players); dK = f * K;
if n == 0; return; end
vcache = containers.Map('KeyType','double','ValueType','double');
    function v = val(mask)                       % mask: n位二进制, 1=该资产增加10%
        if isKey(vcache, mask); v = vcache(mask); return; end
        st = state; Pa = P;
        for q = 1:n
            if bitget(mask, q)
                switch players(q)
                    case 1; st.W_T_cum = state.W_T_cum * (1+f);
                    case 2; st.W_I_cum = state.W_I_cum * (1+f);
                    case 3; st.G_cum   = state.G_cum   * (1+f);
                    case 4; st.E_w_cum = state.E_w_cum * (1+f);
                    case 5; st.E_e_cum = state.E_e_cum * (1+f);
                    case 6; st.dL_cum  = state.dL_cum  * (1+f);
                end
            end
        end
        try
            act = simulate_actual_operation(st, AEMF, setfield(Pa,'quiet_actual',true), demand_y, year, SKU); %#ok<SFLD>
            As = compute_asset_attribution({struct('state', st, 'actual', act)}, Pa, true);
            v = sum(As.REV(1,:) - As.OPEX(1,:));
        catch
            v = NaN;
        end
        vcache(mask) = v;
    end
w = factorial(0:n-1) .* factorial(n-1-(0:n-1)) / factorial(n);   % 按联盟规模的权重
phi = zeros(1, n);
for q = 1:n
    for m = 0:(2^n - 1)
        if bitget(m, q); continue; end
        s = sum(bitget(m, 1:n));
        phi(q) = phi(q) + w(s+1) * (val(bitset(m, q)) - val(m));
    end
end
cf(players) = phi ./ dK(players);
fprintf('     [Shapley] %d类资产, 评估%d个联盟 | 边际价值=[%s] 万元/单位\n', n, vcache.Count, num2str(round(cf),'%d '));
end
