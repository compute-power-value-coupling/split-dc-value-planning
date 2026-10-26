%% =========================================================================
%  update_AEMF.m  —  AEMF年度更新主入口
%  
%  功能:
%    1. 基于扩充后的历史数据重新构建Wasserstein球(充裕维度)
%    2. 重新估计矩约束(稀疏维度)
%    3. 生成本年代表性情景集(15个典型周)
%    4. 计算C17储能能量缺口约束的逐节点下界
%  
%  对应论文: 式(1)-(3), 式(10)
%% =========================================================================
function AEMF = update_AEMF(hist_data, year, P, prev_AEMF)
if nargin < 4 || isempty(prev_AEMF); prev_AEMF = struct(); end

% ── 1. 充裕维度Wasserstein球半径(式2) ──────────────────────────────────
AEMF.N_1 = size(hist_data.cf_wind, 1);   % 累计样本量
% epsilon_1 = C_0 * N_1^(-1/d)
AEMF.epsilon_1 = P.DRO.C_0 * AEMF.N_1^(-1/P.DRO.d_dim);
% TempGraph: 阶跃增长时序编码调制ε收缩(检测到需求跃变→放缓收缩→更保守)
if isfield(hist_data,'demand_yearly')
    prev_e = []; if isstruct(prev_AEMF)&&isfield(prev_AEMF,'growth_embed'); prev_e=prev_AEMF.growth_embed; end
    [g_embed, tg_info] = tempgraph_encode(hist_data.demand_yearly, year, P, prev_e);
    AEMF.growth_embed = g_embed;
    AEMF.epsilon_1 = AEMF.epsilon_1 * tg_info.eps_modulation;   % 阶跃时放大ε
    AEMF.step_intensity = tg_info.step_intensity;
    fprintf('     [TempGraph] 阶跃强度=%.2f 门控=%.2f ε调制=×%.2f\n', ...
        tg_info.step_intensity, tg_info.gate, tg_info.eps_modulation);
end

% ── 2. 稀疏维度矩约束(式3) ─────────────────────────────────────────────
% 基于已实现的年度需求样本估计均值区间与方差上界(自举法)
demand_samples = hist_data.demand_yearly;
N_sparse = length(demand_samples);
mu_hat = mean(demand_samples);
sigma_hat = std(demand_samples);

% 95%置信水平的均值区间(t分布)
if N_sparse >= 2
    t_alpha = tinv(0.975, N_sparse-1);
    margin = t_alpha * sigma_hat / sqrt(N_sparse);
else
    margin = 0.5 * mu_hat;
end

AEMF.mu_rho_L = max(0, mu_hat - margin) / mu_hat;
AEMF.mu_rho_U = (mu_hat + margin) / mu_hat;
AEMF.sigma2_max = sigma_hat^2 * (1 + 2/sqrt(max(1,N_sparse-1)));
AEMF.N_sparse = N_sparse;

% ── 消融M2：w/o AEMF异质 → 统一模糊集 ────────────────────────────────
% 关闭"充裕Wasserstein/稀疏矩约束"的异质区分：矩区间退化为近似点估计，
% 全部不确定性统一由Wasserstein球处理，验证异质建模贡献
if isfield(P,'ablation') && strcmp(P.ablation,'M2')
    AEMF.mu_rho_L = 0.98; AEMF.mu_rho_U = 1.02;   % 矩区间退化
    AEMF.sigma2_max = sigma_hat^2;                  % 无方差膨胀
end

% Token价格矩区间
AEMF.mu_lambda_L = 0.08;
AEMF.mu_lambda_U = 0.20;

% ── 3. 生成代表性情景(基于历史数据聚类) ────────────────────────────────
% N_scen动态调整: 不确定性越大(eps_1越大)→需要更多情景覆盖分布尾部
P_dyn = P;
P_dyn.N_scen = max(5, min(20, round(P.N_scen * (1 + AEMF.epsilon_1 * 8))));
AEMF.scenarios = generate_representative_scenarios(hist_data, P_dyn);

% ── 4. C17储能能量缺口下界(各节点) ────────────────────────────────────
AEMF.E_C17 = compute_C17_storage_lower(hist_data, P);

% ── 4b. 经济最优绿电配比(基于历史CF与电价的物理经济推导) ──────────────
% 西部CF低(~0.19), 绿电需超额配置才能有效消纳并替代购电
% 经济最优配比: 使"边际绿电套利收益 = 边际投资成本"的配比
AEMF.gamma_econ = compute_economic_gamma(hist_data, P);

% 价值密度向量（供主问题价值偏好项使用，每年更新）
% 使用统一基准SKU（Y1价格）计算，消除年际价格变化干扰
SKU_base = struct('p_T', P.lambda_token_base*(1+P.pi_service_T)*P.kappa_cluster_west(:)*0.04, ...
                  'p_R', P.lambda_compute_base*(1+P.pi_service_R)*P.kappa_region_east(:)*0.05, ...
                  'sla_viol_rate', zeros(P.N_west,1));
AEMF.w_density = compute_value_density([], [], P, SKU_base, AEMF);  % NI×1

% ── 4c. 记录历史CF均值和电价均值(供dQ/dG年度计算使用) ───────────────────
% 这些值随历史数据逐年更新 → dQ/dG随年份真正变化
if isfield(hist_data, 'cf_renew') && ~isempty(hist_data.cf_renew)
    AEMF.CF_avg_hist = mean(hist_data.cf_renew(:));   % 西部历史综合CF均值
else
    AEMF.CF_avg_hist = 0.19;
end
if isfield(hist_data, 'price') && ~isempty(hist_data.price)
    AEMF.lam_w_avg_hist = mean(hist_data.price(:, 1:P.N_west), 'all') / 10000;  % 万元/MWh
    AEMF.lam_e_avg_hist = mean(hist_data.price(:, P.N_west+1:end), 'all') / 10000;
else
    AEMF.lam_w_avg_hist = P.lambda_energy_west / 10000;
    AEMF.lam_e_avg_hist = P.lambda_energy_east / 10000;
end

% ── 5. 矩约束精确化(t分布置信区间替代正态近似) ──────────────────────────
% t分布对小样本更准确(尤其N<30时): t_alpha = tinv(0.95, N-1)
N_hist = length(hist_data.demand_yearly);
if N_hist > 2
    t_alpha = tinv(0.95, N_hist - 1);   % t分布分位数(精确)
    demand_std = std(hist_data.demand_yearly);
    demand_mean = mean(hist_data.demand_yearly);
    margin_t = t_alpha * demand_std / sqrt(N_hist);
    rho_L = max(0.1, 1 - margin_t/max(demand_mean, 1));
    rho_U = 1 + margin_t/max(demand_mean, 1);
    AEMF.mu_rho_L = rho_L;
    AEMF.mu_rho_U = min(rho_U, 3.0);
end

% ── 6. RL割筛选策略（MATLAB RL Toolbox DQN，论文式11-12）──────────────
% 使用rlDQNAgent替代手写Q表，实现更强的泛化能力和连续状态空间处理
% 动作空间: keep_fraction ∈ {1.0, 0.8, 0.6, 0.5} (离散4个)
% 状态空间: [gap_norm, cuts_norm, eps_ratio, iter_prog] (连续4维)
KEEP_FRACS = [1.0, 0.8, 0.6, 0.5];

if isfield(prev_AEMF, 'last_gap')
    current_gap = prev_AEMF.last_gap;
    n_cuts      = prev_AEMF.last_n_cuts;
else
    current_gap = 0.5; n_cuts = 10;
end
if isfield(prev_AEMF, 'epsilon_1') && prev_AEMF.epsilon_1 > 0
    eps_ratio = min(2.0, AEMF.epsilon_1 / prev_AEMF.epsilon_1);
else
    eps_ratio = 1.0;
end

% 构造当前观测向量
obs_vec = [min(1,current_gap);
           min(1, n_cuts/30);
           min(1, eps_ratio);
           min(1, year/P.N_year)];

% RL智能体动作选择（DQN或回退到ε-贪心）
rl_on = isfield(P,'enable_RL_cut') && P.enable_RL_cut;
a_new = 1;
if ~rl_on
    % 关闭: 不初始化、不加载预训练模型, 割全部保留
    AEMF.RL = struct('agent',[],'keep_fraction',1.0,'last_obs',[],'last_action',1);
    if year == 1
        fprintf('  [RL-DQN] 已关闭(enable_RL_cut=false): 割全部保留, 不加载预训练模型\n');
    end
elseif isfield(prev_AEMF,'RL') && isfield(prev_AEMF.RL,'agent') ...
        && ~isempty(prev_AEMF.RL.agent)
    AEMF.RL = prev_AEMF.RL;
    % 用DQN选择动作（getAction返回1-4的整数）
    try
        a_new = getAction(AEMF.RL.agent, {obs_vec});
        a_new = a_new{1};
    catch
        a_new = randi(4);
    end
    AEMF.RL.last_obs    = obs_vec;
    AEMF.RL.last_action = a_new;
else
    % 首次运行：初始化DQN智能体
    AEMF.RL = struct();
    try
        [agent, ~] = init_RL_agent(P);
        % 若存在预训练模型则加载
        if exist('rl_agent_pretrained.mat','file')
            loaded = load('rl_agent_pretrained.mat','agent');
            agent = loaded.agent;
            fprintf('  [RL-DQN] 加载预训练模型\n');
        end
        AEMF.RL.agent = agent;
    catch ME
        warning('[RL-DQN] 初始化失败(%s)，回退到ε-贪心',ME.message);
        AEMF.RL.agent = [];
    end
    AEMF.RL.last_obs    = [];
    AEMF.RL.last_action = 1;
    a_new = 1;   % 首年全保留
end

if rl_on
    AEMF.RL.keep_fraction = KEEP_FRACS(max(1,min(4,a_new)));
    fprintf('     [RL-DQN] gap=%.3f n_cuts=%d → 保留%.0f%%\n', ...
        current_gap, n_cuts, AEMF.RL.keep_fraction*100);
end

% 同步GBR模型（BSASP用，从prev_AEMF传递）
if isfield(prev_AEMF,'gbr_model')
    AEMF.gbr_model = prev_AEMF.gbr_model;
else
    AEMF.gbr_model = [];
end

end


%% ── 经济最优绿电配比计算 ──────────────────────────────────────────────
function gamma_econ = compute_economic_gamma(hist_data, P)
% 节点差异化gamma_econ：直接用P.CF_wind/pv_west（可靠），不依赖hist_data列顺序
% 宁夏CF最高(0.24+0.19)/2=0.215 → gamma最小 → F1最低 → 主问题优先选宁夏
% 贵州CF最低(0.16+0.13)/2=0.145 → gamma最大 → F1最高 → 主问题最后选

NI = P.N_west;
gamma_econ = zeros(NI, 1);

lam_w_avg = mean(hist_data.price(:, 1:min(P.N_west, size(hist_data.price,2))), 'all');
C_per_MW = (P.C_renew_wind + P.C_renew_pv) / 2 * 1000;   % 万元/MW
train_demand = 1 * 8760 * 0.7;

for i = 1:NI
    % 直接从P参数读取节点CF（可靠，避免hist_data列顺序问题）
    if isfield(P,'CF_wind_west') && length(P.CF_wind_west) >= NI
        CF_i = (P.CF_wind_west(i) + P.CF_pv_west(i)) / 2;
    else
        CF_i = max(0.08, mean(hist_data.cf_renew(:)));
    end

    E_per_MW_year = CF_i * 8760;

    gamma_candidates = 0.8 : 0.1 : 5.5;
    net_value = zeros(size(gamma_candidates));
    for k = 1:length(gamma_candidates)
        g = gamma_candidates(k);
        consumed = min(g * E_per_MW_year, train_demand);
        curtailed = max(0, g * E_per_MW_year - train_demand);
        arb_revenue   = consumed  * lam_w_avg / 10000;
        curt_loss     = curtailed * P.C_curt_op / 10000;
        invest_annual = g * C_per_MW / P.T_life;
        net_value(k)  = arb_revenue - curt_loss - invest_annual;
    end
    [~, best_idx] = max(net_value);
    g_econ = gamma_candidates(best_idx);

    % 物理下界：绿电年发电量 >= 60%训练用电（CF越低→下界越大）
    g_physical = 0.60 * train_demand / E_per_MW_year;

    gamma_econ(i) = max(max(1.8, g_physical), min(P.gamma_max - 0.5, g_econ));
end
end
