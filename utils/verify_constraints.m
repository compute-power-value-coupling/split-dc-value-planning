%% =========================================================================
%  verify_constraints.m  —  物理约束检查器
%  
%  对x_sol执行C1~C19约束检查, 不满足则警告并记录
%% =========================================================================
function ok = verify_constraints(x_sol, P, AEMF)

ok = true;
violations = {};

NI = P.N_west;

% C1: 选址容量边界
for i = 1:NI
    if x_sol.z(i) == 1
        if x_sol.W_T(i) < P.W_train_min - 1e-3
            violations{end+1} = sprintf('C1: 节点%d 容量%fMW低于下界%dMW', i, x_sol.W_T(i), P.W_train_min);
            ok = false;
        end
        if x_sol.W_T(i) > P.W_train_max + 1e-3
            violations{end+1} = sprintf('C1: 节点%d 容量%fMW超过上界%dMW', i, x_sol.W_T(i), P.W_train_max);
            ok = false;
        end
    else
        if x_sol.W_T(i) > 1e-3
            violations{end+1} = sprintf('C1: 节点%d未选址但容量非零', i);
            ok = false;
        end
    end
end

% C2: 节点数
if sum(x_sol.z) > P.K_max
    violations{end+1} = sprintf('C2: 选址节点数%d超过上限%d', sum(x_sol.z), P.K_max);
    ok = false;
end

% C4: 绿电覆盖率
for i = 1:NI
    if x_sol.W_T(i) > 0
        gw = x_sol.G(i) / x_sol.W_T(i);
        if gw < P.gamma_min - 1e-3
            violations{end+1} = sprintf('C4: 节点%d G/W=%.3f < %.2f', i, gw, P.gamma_min);
            ok = false;
        end
    end
end

% C16: 合同保障
for i = 1:NI
    if x_sol.z(i) == 1
        Pc_min = P.W_contract_D(i) / P.eta_PUE_west(i);
        if x_sol.W_T(i) < Pc_min - 1e-3
            violations{end+1} = sprintf('C16: 节点%d W_T=%.0f<合同保障%.0fMW', i, x_sol.W_T(i), Pc_min);
            ok = false;
        end
    end
end

% C17: 储能能量缺口
for i = 1:NI
    if x_sol.z(i) == 1 && x_sol.E_w(i) < AEMF.E_C17(i) - 1e-3
        violations{end+1} = sprintf('C17: 节点%d E_w=%.0f<缺口下界%.0fMWh', i, x_sol.E_w(i), AEMF.E_C17(i));
        ok = false;
    end
end

if ~ok
    fprintf('  [约束检查] 发现%d项违反:\n', length(violations));
    for k = 1:length(violations)
        fprintf('    - %s\n', violations{k});
    end
end
end
