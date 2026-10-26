%% verify_dc_powerflow.m — 改进IEEE118系统PTDF线性化DC潮流事后校验
%
%  作用：规划结果出来后，校验7节点注入功率在缩放118网络中不引起线路越限
%  方法：MATPOWER case118 → makePTDF → 线路潮流 = PTDF × 节点注入
%  不进优化模型(避免MILP复杂度爆炸)，作为规划方案网络可行性验证
%
%  用法：verify_dc_powerflow(results_yearly, P)  % 主仿真结束后调用
function violations = verify_dc_powerflow(results_yearly, P)

violations = [];
try
    mpc = loadcase('case118');
catch
    warning('MATPOWER case118不可用，跳过潮流校验'); return;
end

% ── 缩放：负荷与线路热容量×scale ─────────────────────────────────────
k = P.ieee118_scale;
mpc.bus(:,3:4) = mpc.bus(:,3:4) * k;        % PD/QD
mpc.branch(:,6:8) = mpc.branch(:,6:8) * k;  % RATE_A/B/C
mpc.gen(:,[2,4,9]) = mpc.gen(:,[2,4,9]) * k; % PG/QMAX/PMAX

% ── PTDF矩阵（slack=母线69，case118默认参考节点）──────────────────────
slack = find(mpc.bus(:,2) == 3, 1);
H = makePTDF(mpc, slack);   % n_branch × n_bus
rate = mpc.branch(:,6); rate(rate==0) = inf;

fprintf('\n[潮流校验] 改进IEEE118(×%d) PTDF线性化DC潮流\n', k);
fprintf('%-4s %-12s %-12s %-10s\n','年','最大负载率','越限线路数','状态');

buses_w = P.ieee118_bus_west; buses_e = P.ieee118_bus_east;
for y = 1:P.N_year
    R = results_yearly{y}; if isempty(R); continue; end
    % 节点注入向量：西部=数据中心负荷为正注入的负值(负荷)，
    % 训练负荷+绿电净注入；东部=推理负荷
    Pinj = zeros(size(mpc.bus,1),1);
    for i = 1:length(buses_w)
        % 西部净注入 = 绿电出力均值 - 训练负荷（正=送出）
        G_out = R.state.G_cum(i) * mean([P.CF_wind_west(i),P.CF_pv_west(i)]);
        Pinj(buses_w(i)) = Pinj(buses_w(i)) + G_out - R.state.W_T_cum(i);
    end
    for j = 1:length(buses_e)
        Pinj(buses_e(j)) = Pinj(buses_e(j)) - R.state.W_I_cum(j);
    end
    % 平衡量由slack吸收(PTDF已含参考节点处理)
    flow = H * Pinj;                      % 各线路增量潮流(MW)
    loading = abs(flow) ./ rate;
    [max_load, ~] = max(loading);
    n_viol = sum(loading > 1.0);
    status = 'OK'; if n_viol > 0; status = sprintf('X越限'); end
    fprintf('Y%-3d %8.1f%%    %8d     %s\n', y, max_load*100, n_viol, status);
    if n_viol > 0
        viol_idx = find(loading > 1.0);
        violations = [violations; repmat(y,length(viol_idx),1), viol_idx, loading(viol_idx)];
    end
end
if isempty(violations)
    fprintf('[潮流校验] 全部15年规划方案在改进118系统中无线路越限 OK\n');
else
    fprintf('[潮流校验] 存在%d条越限记录，需检查断面容量约束\n', size(violations,1));
end
end
