%% =========================================================================
%  pack_year_results.m  —  年度结果打包
%% =========================================================================
function R = pack_year_results(year, state, x_new, ben_info, actual_y, AEMF, demand_y)

R = struct();
R.year = year;
R.state = state;                   % 累计状态
R.x_new = x_new;                   % 本年决策
R.ben_info = ben_info;             % Benders信息
R.actual = actual_y;               % 实际运行
R.AEMF = struct('epsilon_1', AEMF.epsilon_1, ...
                'N_1', AEMF.N_1, ...
                'mu_rho_L', AEMF.mu_rho_L, ...
                'mu_rho_U', AEMF.mu_rho_U, ...
                'sigma2_max', AEMF.sigma2_max, ...
                'E_C17', AEMF.E_C17);
R.demand_y = demand_y;
R.timestamp = now;
end
