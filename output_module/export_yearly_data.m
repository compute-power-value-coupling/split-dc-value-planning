%% =========================================================================
%  export_yearly_data.m  —  输出30项数据文件
%  
%  按年份输出: hourly_operation/year_XX/ 子目录
%  全局数据: 累积到planning_results/, system_params/, market_data/
%% =========================================================================
function export_yearly_data(year, R, P)

NI = P.N_west; NJ = P.N_east;
year_str = sprintf('year_%02d', year);
year_dir = fullfile(P.out_dir, 'hourly_operation', year_str);
if ~exist(year_dir, 'dir'); mkdir(year_dir); end

state = R.state;
actual = R.actual;

%% ── 数据6: 弃电消纳功率 ───────────────────────────────────────────────
writematrix(actual.P_curt, fullfile(year_dir, 'curtailment.csv'));

%% ── 数据7: 电网购电功率(西+东) ────────────────────────────────────────
grid_purchase = zeros(P.N_hour_year, NI + NJ);
grid_purchase(:, 1:NI) = actual.P_grid;
% 东部购电(简化: A类刚性负载)
for j = 1:NJ
    P_A_demand = max(R.demand_y(1,:)) / NJ / P.eta_PUE_east(j);
    grid_purchase(:, NI+j) = P_A_demand;
end
writematrix(grid_purchase, fullfile(year_dir, 'grid_purchase.csv'));

%% ── 数据8: Token产出 ──────────────────────────────────────────────────
writematrix(actual.T_gen, fullfile(year_dir, 'token_output.csv'));
% 论文图用: 训练负荷与B类跨域外送的逐时记录
writematrix(actual.P_train, fullfile(year_dir, 'training_power.csv'));
if isfield(actual,'B_off');  writematrix(actual.B_off,  fullfile(year_dir, 'b_offload.csv'));  end
if isfield(actual,'P_Boff'); writematrix(actual.P_Boff, fullfile(year_dir, 'b_offload_power_west.csv')); end

%% ── 数据9: 三模式切换标记 ─────────────────────────────────────────────
writematrix(actual.mode, fullfile(year_dir, 'mode_switch.csv'));

%% ── 数据10-12: 模式时段索引 ──────────────────────────────────────────
writematrix(actual.curt_hours, fullfile(year_dir, 'curtailment_mode_hours.csv'));
writematrix(actual.grid_hours, fullfile(year_dir, 'grid_mode_hours.csv'));
writematrix(actual.load_red_hours, fullfile(year_dir, 'load_reduction_mode_hours.csv'));

%% ── 数据13: 储能SOC ───────────────────────────────────────────────────
writematrix(actual.SOC, fullfile(year_dir, 'soc_trajectory.csv'));

%% ── 数据14: C类迁移 ───────────────────────────────────────────────────
writematrix(actual.C_migration, fullfile(year_dir, 'c_migration.csv'));

%% ── 数据15: 积压水平 ──────────────────────────────────────────────────
backlog_all = [actual.B_B, actual.B_C];
writematrix(backlog_all, fullfile(year_dir, 'backlog_level.csv'));

%% ── 数据16: 服务率 ────────────────────────────────────────────────────
service_all = [actual.S_B, actual.S_C];
writematrix(service_all, fullfile(year_dir, 'service_rate.csv'));

%% ── 数据17: SLA违约事件(基本统计) ─────────────────────────────────────
viol_log = [year, actual.SLA_viol_count, actual.sla_B_viol_rate];
writematrix(viol_log, fullfile(year_dir, 'sla_violation_summary.csv'));

%% ── 数据18: PUE逐小时(常数填充) ──────────────────────────────────────
PUE_h = zeros(P.N_hour_year, NI + NJ);
PUE_h(:, 1:NI) = repmat(P.eta_PUE_west, P.N_hour_year, 1);
PUE_h(:, NI+1:end) = repmat(P.eta_PUE_east, P.N_hour_year, 1);
writematrix(PUE_h, fullfile(year_dir, 'pue_hourly.csv'));

%% ── 数据19: 电网应力(简化电压偏离) ───────────────────────────────────
% 仅记录关键节点
grid_stress = zeros(P.N_hour_year, NI+NJ);
% 用负载/容量比近似电压偏离
for i = 1:NI
    if state.W_T_cum(i) > 0
        grid_stress(:,i) = actual.P_train(:,i) ./ state.W_T_cum(i) * 0.05;
    end
end
writematrix(grid_stress, fullfile(year_dir, 'grid_stress.csv'));

%% ── 数据20: 套利信号 ──────────────────────────────────────────────────
writematrix(actual.arbitrage_signal, fullfile(year_dir, 'arbitrage_signal.csv'));

%% ── 数据21: 套利收益分解 ─────────────────────────────────────────────
arb_decomp = zeros(P.N_hour_year, 3*NI);
p_T_per_node = P.lambda_compute_base * (1+P.pi_service_T) * 0.04 * [1.575, 1.30, 1.434, 1.045];
for i = 1:NI
    for h = 1:P.N_hour_year
        rev = p_T_per_node(i) * actual.T_gen(h,i) * 0.1;
        elec = actual.price(h,i)/10000 * actual.P_grid(h,i);
        if actual.mode(h,i) == 1
            arb_decomp(h, i) = rev;   % 弃电模式收益
        elseif actual.mode(h,i) == 2
            arb_decomp(h, NI+i) = rev - elec;   % 购电模式
        elseif actual.mode(h,i) == 3
            arb_decomp(h, 2*NI+i) = -elec;   % 降载模式损失
        end
    end
end
writematrix(arb_decomp, fullfile(year_dir, 'arbitrage_decomposed.csv'));

%% ── 数据23/24: 风光CF ─────────────────────────────────────────────────
writematrix(actual.cf_wind, fullfile(year_dir, 'wind_cf.csv'));
writematrix(actual.cf_pv, fullfile(year_dir, 'pv_cf.csv'));

%% ── 数据26: 电力现货电价 ─────────────────────────────────────────────
writematrix(actual.price, fullfile(year_dir, 'electricity_price.csv'));

%% ── 数据28: 绿证价格(月度) ───────────────────────────────────────────
GEC_monthly = P.lambda_GEC * (1 + 0.05*randn(12, 1));
writematrix(GEC_monthly, fullfile(year_dir, 'gec_price.csv'));

%% ── 数据30: 情景概率权重 ─────────────────────────────────────────────
writematrix(R.AEMF.E_C17, fullfile(year_dir, 'scenario_weights.csv'));

end
