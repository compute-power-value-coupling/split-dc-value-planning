%% compute_value_density.m — 节点SKU价值密度系数 w_i（论文式34）
%
%  w_i = (年化训练收益 / 年化标准投资) × w_water_i × 水成本修正
%
%  三维价值构成：
%    kappa_cluster（集群规模/市场价值）→ 决定训练收益p_T
%    投资成本（含CF通过gamma_econ体现）→ 分母
%    w_water（水资源禀赋）→ 水-电负相关的多维权衡（贵州水补偿电劣势）
%  CF不直接进入w（CF已在F1里通过gamma_econ体现，不能双重计入）
%
function w = compute_value_density(x_sol, scen_s, P, SKU, AEMF)

NI = P.N_west;
w  = zeros(NI, 1);

% gamma_econ（供未选节点估算invest用）
if nargin >= 5 && isstruct(AEMF) && isfield(AEMF,'gamma_econ') && length(AEMF.gamma_econ) >= NI
    gamma_est = AEMF.gamma_econ(:);
else
    % 用CF物理下界估算
    if isfield(P,'CF_wind_west') && isfield(P,'CF_pv_west')
        CF = (P.CF_wind_west(:) + P.CF_pv_west(:)) / 2;
    else
        CF = 0.20 * ones(NI,1);
    end
    gamma_est = max(1.8, 0.60 * 0.7 ./ CF);
end

for i = 1:NI
    eta_i = P.eta_PUE_west(i);
    del_i = P.delta_comm(i);

    % 统一用Pc_min作为评估基准容量（已选/未选一致，消除口径差异）
    Pc_min_i = P.W_contract_D(i) / eta_i;
    Wi_base  = max(P.W_train_min, Pc_min_i);

    % 训练token年化收益（由kappa_cluster决定，与CF无关）
    p_T_i = SKU.p_T(i);   % 已含kappa_cluster影响
    T_gen = P.eta_token * Wi_base / eta_i * del_i * 0.5;
    annual_rev = p_T_i * T_gen * 0.1 * 8760;   % 万元/年

    % 标准化投资（用gamma_econ，不用gamma_min）
    G_est  = gamma_est(i) * Wi_base;
    E_est  = P.mu_min * G_est * P.dt_stor;
    invest = P.C_train_fix * Wi_base ...
           + (P.C_renew_wind + P.C_renew_pv) * 1000 * G_est * 0.5 ...
           + P.C_stor * 1000 * E_est;

    if invest < 1; w(i) = 0; continue; end

    w(i) = annual_rev * P.T_life / invest;

    % ── 水资源价值维度（论文式：多维资源禀赋权衡）─────────────────────
    % 水系数w_water_i乘入价值密度：水富裕节点(贵州)获正向加成，
    % 水稀缺节点(内蒙/宁夏)受折损，体现水-电-集群三维权衡
    if isfield(P,'enable_water_dim') && P.enable_water_dim ...
            && isfield(P,'w_water_west') && length(P.w_water_west) >= NI
        w(i) = w(i) * P.w_water_west(i);

        % 水成本扣减：冷却水耗对运营收益的实际影响
        % 年冷却水耗(m³) = WUE(L/kWh) × IT年耗电(kWh) / 1000
        if isfield(P,'WUE_west') && isfield(P,'water_price_west')
            IT_annual_kWh = Wi_base * 8760 * 1000;   % MW→kWh
            water_m3 = P.WUE_west(i) * IT_annual_kWh / 1000;
            water_cost = water_m3 * P.water_price_west(i) / 1e4;  % 万元/年
            % 水成本占年收益比例，从价值密度中扣除
            w(i) = w(i) * max(0.85, 1 - water_cost / max(annual_rev, 1));
        end
    end

    % SLA历史违约率修正
    if nargin >= 4 && isstruct(SKU) && isfield(SKU,'sla_viol_rate')
        vr = SKU.sla_viol_rate(min(i, length(SKU.sla_viol_rate)));
        w(i) = w(i) * max(0.70, 1.0 - 2.5 * vr);
    end
end

% 归一化到[0,10]
if max(w) > 1e-6
    w = w / max(w) * 10.0;
end
end
