%% =========================================================================
%  scale_demand_by_growth.m  —  按增长率缩放算力需求时序
%  
%  逻辑: 以基准峰值(D_peak)起步, 按growth曲线累积到当前年份, 再按4类时序模板
%        与典型周(168h)展开生成该年的算力需求时序
%  
%  输出: demand(4×T) — 4类任务的逐小时需求(MW)
%% =========================================================================
function [demand, fac] = scale_demand_by_growth(template, rho_growth, year, P, fac_prev)

% 基准峰值需求 D_peak (Y0)
D_peak_0 = 1000;                       % MW (Y0基准)
T = P.N_hour_typical;                  % 168小时

% 累积增长至本年: D_peak(y) = D_peak_0 * (1+rho1)*(1+rho2)*...*(1+rho_y)
% 注: rho_growth已经是year年的预测增速
% 这里使用从Y1起到year的乘积放大
persistent demand_cum_factor;
if isempty(demand_cum_factor) || length(demand_cum_factor) ~= P.N_year || year == 1
    demand_cum_factor = ones(P.N_year, 1);
end
if year == 1
    demand_cum_factor(year) = 1 + rho_growth;
elseif nargin >= 5 && ~isempty(fac_prev)
    demand_cum_factor(year) = fac_prev * (1 + rho_growth);   % 显式传入上年因子(检查点续跑)
else
    demand_cum_factor(year) = demand_cum_factor(year-1) * (1 + rho_growth);
end
fac = demand_cum_factor(year);

D_peak_y = D_peak_0 * demand_cum_factor(year);

% 4类任务的峰值份额(按论文设定 35/25/25/15)
task_peak = D_peak_y * P.task_ratio;     % [A,B,C,D]

% 展开168小时(=7天x24小时), 每天用同一模板
demand = zeros(4, T);
for d = 1:7
    for hod = 1:24
        t_idx = (d-1)*24 + hod;
        for k = 1:4
            demand(k, t_idx) = task_peak(k) * template(k, hod);
        end
    end
end

% 周末调节(B类周末稍低, A类相似, C类周末略高)
for d = 1:7
    if d == 6 || d == 7   % 周末
        idx = (d-1)*24+1 : d*24;
        demand(1, idx) = demand(1, idx) * 0.85;   % A周末弱
        demand(2, idx) = demand(2, idx) * 0.80;   % B周末弱
        demand(3, idx) = demand(3, idx) * 1.15;   % C周末强(批量任务集中)
    end
end

end
