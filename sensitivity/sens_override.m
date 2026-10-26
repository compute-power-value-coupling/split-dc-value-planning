function ov = sens_override(p, lev, P0)
%% 参数扰动 → 需覆盖的 P 字段(P0 为 init_parameters 基准值)
ov = struct();
switch p
    case 'disc'     % 折现率: 主问题年金化、summary现金流、资产归因统一读取 P.r_min
        ov.r_min = lev;
    case 'stor'     % 储能投资成本
        ov.C_stor = P0.C_stor * lev;
    case 'comp'     % 算力投资成本: 训练中心与推理中心
        ov.C_train_fix = P0.C_train_fix * lev;
        ov.C_infer_fix = P0.C_infer_fix * lev;
        ov.C_gpu_annual = P0.C_gpu_annual * lev;
    case 'green'    % 绿电投资成本: 风电与光伏
        ov.C_renew_wind = P0.C_renew_wind * lev;
        ov.C_renew_pv = P0.C_renew_pv * lev;
    case 'demand'   % 算力需求增速(仅重规划模式)
        ov.growth_scale = lev;
    case 'token'    % token效率增速(仅重规划模式)
        ov.eta_token_gr_schedule = P0.eta_token_gr_schedule * lev;
        ov.eta_token_gr = P0.eta_token_gr * lev;
    otherwise
        error('sens:param', '未知参数: %s', p);
end
end
