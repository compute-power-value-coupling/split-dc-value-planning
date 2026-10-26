%% =========================================================================
%  compute_marginal_contribution.m  —  完整Benders次梯度计算
%  对应论文式(35)的严格对偶实现
%
%  Benders最优性割的次梯度来自Lagrangian松弛：
%    L(x, y, μ) = f(y) + μ_train^T(P_train - W_T)
%                       + μ_renew^T(P_renew - G·CF)
%                       + μ_stor^T(E_soc - E_w)
%
%  关于一阶段变量x的偏导数（次梯度）：
%    ∂Q/∂W_T(i) = -Σ_{t,s} w_s × μ_train(i,t,s)      [万元/MW]
%    ∂Q/∂G(i)   = -Σ_{t,s} w_s × μ_renew(i,t,s) × CF(i,t,s) [万元/MW]
%    ∂Q/∂E_w(i) = -Σ_{t,s} w_s × μ_stor(i,t,s)       [万元/MWh]
%
%  注意：次梯度为负数，增大容量放松约束使Q降低（改善）
%  T_planning放大：将168h情景次梯度换算为年度值
%% =========================================================================
function [dQ_dWT, dQ_dG, dQ_dEw] = compute_marginal_contribution(mu_all_scen, scen_weights, scen_data, P)

NI = P.N_west;
N_s = length(mu_all_scen);

dQ_dWT = zeros(NI, 1);   % ∂Q/∂W_T  [万元/MW/年]
dQ_dG  = zeros(NI, 1);   % ∂Q/∂G    [万元/MW/年]
dQ_dEw = zeros(NI, 1);   % ∂Q/∂E_w  [万元/MWh/年]

for s = 1:N_s
    w_s  = scen_weights(s);
    mu_s = mu_all_scen{s};

    % ── ∂Q/∂W_T: 训练容量约束乘子（式35a）──────────────────────────
    % 约束：P_train(i,t) ≤ W_T(i)，乘子μ_train≥0
    % 增大W_T → 放松约束 → ∂Q/∂W_T = -Σ_t μ_train（负数）
    for i = 1:NI
        dQ_dWT(i) = dQ_dWT(i) - w_s * sum(mu_s.train(i, :));
    end

    % ── ∂Q/∂G: 绿电装机约束乘子（式35b）────────────────────────────
    % 约束：P_renew(i,t) ≤ G(i)·CF(i,t)，乘子μ_renew≥0
    % ∂g/∂G(i) = -CF(i,t) → ∂Q/∂G(i) = -Σ_t μ_renew(i,t)·CF(i,t)
    if ~isempty(scen_data) && isfield(scen_data{s}, 'CF_renew')
        CF_s = squeeze(scen_data{s}.CF_renew);  % NI×T
        if size(CF_s,1) == NI
            for i = 1:NI
                dQ_dG(i) = dQ_dG(i) - w_s * sum(mu_s.renew(i,:) .* CF_s(i,:));
            end
        end
    end

    % ── ∂Q/∂E_w: 西部储能约束乘子（式35c）──────────────────────────
    % 约束：E_soc(i,t) ≤ E_w(i)，乘子μ_stor≥0
    % 增大E_w → 放松储能约束 → ∂Q/∂E_w = -Σ_t μ_stor（负数）
    for i = 1:NI
        dQ_dEw(i) = dQ_dEw(i) - w_s * sum(mu_s.stor(i, :));
    end
end

% ── 年化：将168h情景次梯度换算为年度值（×T_planning=52周）────────────
% 与solve_subproblem保持一致：Q已乘以T_planning=52，次梯度须同步放大
T_planning = 52;   % 168h典型周→年度（52周/年）
dQ_dWT = dQ_dWT * T_planning;
dQ_dG  = dQ_dG  * T_planning;
dQ_dEw = dQ_dEw * T_planning;

% ── 符号说明：次梯度均为非正数（≤0）──────────────────────────────
% 割用于Benders下界：θ ≥ Q_LR + dQ_dWT×ΔW_T + dQ_dG×ΔG + dQ_dEw×ΔE_w
% 当容量增大（Δ>0），割右侧减小（dQ<0×Δ>0<0）→ θ下界降低 → 允许更优θ
% 这正确反映了：更大的容量使子问题运营更容易，Q确实更低

% ── 量级保护：若乘子全为0（初始阶段），保持次梯度为0（不引入错误方向）──
% 注：不强制设为正值，零次梯度割退化为常数割，等待乘子更新后再收紧

end
