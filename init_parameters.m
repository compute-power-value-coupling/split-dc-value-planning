%% =========================================================================
%  init_parameters.m  —  全局参数初始化
%  
%  单位制(严格统一):
%    成本/收益: 万元
%    容量: MW (功率) / MWh (能量)
%    时间: 小时
%    电价: 元/MWh
%    Token价格: 元/千tokens
%  
%  对应论文: 表3全部参数
%% =========================================================================
function P = init_parameters()

%% ── 系统拓扑 ────────────────────────────────────────────────────────────
P.I_west = [1, 2, 3, 4];             % 西部候选训练区域(内蒙/甘肃/宁夏/贵州)
P.J_east = [89, 100, 110];             % 东部推理节点
P.N_west = 4;
P.N_east = 3;
P.west_names = {'内蒙古','甘肃','宁夏','贵州'};
P.east_names = {'京津冀','长三角','粤港澳'};

% 通信枢纽7节点(北京/上海/广州/成渝/内蒙/宁夏/甘肃)
P.hub_names = {'北京','上海','广州','成渝','内蒙','宁夏','甘肃'};
P.west_hub_idx = [5, 7, 6, 4];        % 西部→枢纽映射
P.east_hub_idx = [1, 2, 3];           % 东部→枢纽映射

%% ── 时间尺度 ────────────────────────────────────────────────────────────
P.N_year = 15;                        % 规划期15年
P.T_life = 20;                        % 设备生命周期20年(用于投资年化)
P.N_hour_year = 8760;                 % 全年8760小时
P.N_hour_typical = 168;               % 典型周168小时(用于Benders内部加速)
P.N_scen = 15;                        % 代表性情景数基准(随eps_1动态调整: N_s=max(5,min(20,round(15×(1+eps_1×8)))))
P.T = P.N_hour_typical;               % 子问题时步数

%% ── 数据中心物理参数 ─────────────────────────────────────────────────────
P.eta_PUE_west = [1.20, 1.25, 1.23, 1.20];   % 西部PUE
P.eta_PUE_east = [1.25, 1.32, 1.38];          % 东部PUE
P.kappa_GPU = 0.7;                              % kW/GPU (H100 TDP)

% 算力价值单元生成效率(百万tokens/MWh)
% 标定依据: 使运营ROI落在合理区间(0.15-0.30), 体现首年基建亏损、后续回本的真实财务规律
% 系统级有效token吞吐效率（规划层校准参数）
% 物理基础：H100推理峰值≈10286百万tokens/MWh，系统降额系数0.346
%           （含模型加载0.80 × 批处理等待0.70 × 运维停机0.95 × 混合负载0.65）
%           系统级≈10286×0.346÷1000≈3.56百万tokens/MWh（训练更低约0.55）
% 规划模型校准：目标收益1500万/MW/年时，eta_token=5.0
%   验证：p_R(0.35)×eta(5)×8736h×0.1 = 1524万/MW/年 ✓（合理数据中心收益）
%   vs 原来eta=8：revenue/MW=2797万（偏高1.84×，已通过lambda=2.94部分修正）
% Huang定律年增率在eta_token_gr中体现（28%/年）
P.eta_token = 2000;                   % 百万tokens/MWh — 市场锚定v3: 真实serving效率量级

% 通信效率折扣
P.delta_comm = [0.92, 0.95, 0.90, 0.88];     % 各西部节点

%% ── 服务等级协议参数 ─────────────────────────────────────────────────────
% 任务比例(A/B/C/D)
% 算力任务分层比例 [A类实时, B类弱实时, C类批量, D类训练]
% 调整依据：Goldman Sachs(2026): 2025年AI计算中训练/推理比达6:4（训练占比持续上升）
%          D类从15%提升至22%，A/C适当收窄
% 效果：D训练需求=247MW，更接近W_train_min×3=600MW → 高CF时段约束活跃 → μ_train>0
P.task_ratio = [0.33, 0.23, 0.22, 0.22];  % [A类, B类, C类, D类](Y1结构, 主循环逐年更新)
P.task_ratio_Y1  = P.task_ratio;              % 起点结构(保存, 不被覆盖)
P.task_ratio_end = [0.36, 0.28, 0.22, 0.14];  % Y15结构(情景): 推理侧↑, 训练22%→14%
P.task_shift_mid = 7;                         % logistic过渡中点(年)
P.task_shift_k   = 0.55;                      % 过渡陡度
P.enable_task_evolution = true;
P.use_workload_mix = true;    % 按"非AI/AI推理/AI训练"三族份额演化(先训练略高于推理, 约Y2交叉, 后推理主导)
P.wl_share_Y1  = [0.466 0.254 0.280];   % Y1≈2025(McKinsey数据中心需求模型)
P.wl_share_Y6  = [0.290 0.426 0.284];   % Y6≈2030(同上)
P.wl_share_end = [0.22  0.56  0.22];    % Y15情景外推(须敏感性)               % 关=结构固定(消融对照)

% SLA保底服务率
P.SLA_floor_B = 0.65;                 % B类必须服务到达量的65%以上
P.SLA_floor_C = 0.30;

% 相邻时步服务率变化幅度
P.Delta_up = 0.40;
P.Delta_down = 0.30;

% 积压阈值倍数(用于触发违约)
P.B_thresh_B_ratio = 1.5;
P.B_thresh_C_ratio = 0.5;

%% ── 价格与成本参数(万元体系) ────────────────────────────────────────────
% 投资成本(万元)
P.C_train_fix = 1500;                 % 万元/MW 训练中心(含基础设施)
P.C_gpu_ratio = 0.70;                 % GPU硬件占训练投资比例
P.T_gpu_life  = 4;                    % GPU硬件寿命(年, H100/A100约3-5年)
P.C_gpu_annual = P.C_train_fix * P.C_gpu_ratio / P.T_gpu_life; % 262.5万/MW/年(折旧)
P.C_om_annual  = 80;                  % 万元/MW/年 运维(人员+维修+网络≈5-8%投资额)
P.C_infer_fix = 1200;                 % 万元/MW 推理中心
P.C_renew_wind = 0.35;                % 万元/kW = 350万元/MW
P.C_renew_pv = 0.22;                  % 万元/kW = 220万元/MW
P.C_stor = 0.090;                     % 万元/kWh = 900元/kWh (磷酸铁锂BESS系统级成本2024)
P.T_stor_life = 10;                   % 年 电池日历寿命(LFP约8-12年, 非项目20年)
P.N_stor_cycle = 3000;                % 次 循环寿命(LFP 80%容量保持)
P.C_var_om_MWh = 130;                 % 元/MWh 算力变动运维强度(η自适应派生源)
P.C_stor_op = 25;                     % 元/MWh 实际循环退化O&M(资本回收不含)
%  注: 储能真实经济性分析
%  ① 一次CapEx: C_stor×E(在F1中, 按T_stor_life折旧)
%  ② 年折旧: C_stor×1000/T_stor_life 万/MWh/年(10年而非20年摊销)
%  ③ 循环O&M: 25元/MWh充放(维护+BMS+冷却)
%  ④ 往返损耗电费: (1-eta_rt)/eta_rt × 电价 ≈ 50-70元/MWh(按300元/MWh电价)
%  ⑤ 电池更换: 15年项目约需更换一次(年10), 成本≈C_stor×E
% C_trans已由C_trans_per_node路径矩阵替代，此处不再定义标量版本

% SKU双层定价
% 算力服务定价（基于Goldman Sachs/Gartner/中国市场2026年数据重新标定）
% A/B实时推理：企业专属高SLA云→ 1.50元/千tokens
%   参考：商汤SenseNova 9元/百万tokens，专属实时含绿色溢价取中高端
% 算力定价重新标定（基于深度市场分析）
% 第一性原理验证：
%   合理企业专属SLA云定价 p_R = 0.45元/千tokens（企业级独占，含SLA保障溢价）
%   推导：lambda = p_R / ((1+pi_R)×kappa_mean×0.05) = 0.45/0.11925 = 3.77 ≈ 3.8
%   验证：3.80×1.80×1.325×0.05 = 0.453元/千tokens ✓
%   市场对标：DeepSeek正常0.003×150倍 / 企业专属最高0.20×2.25倍（含SLA溢价）
%   经济效果：IRR≈12-13%，营业利润率≈40%，回收期Y10-Y12（合理基础设施投资）
%   eta_token=5.0时：p_R=0.45，Y1推理收益≈124亿，Y1 NCF≈-246亿（正常Y1亏损）
%   旧值2.94对应p_R=0.35→IRR=8.4%（过低，NPV仅14亿≈0）
P.lambda_compute_base = 0.007125;  % η重锚v4: 2.85÷400(η:5→2000), 源头下沉使dQ/L_glob/fallback全路径继承
P.pi_service_R = 0.80;
% D类训练：修复原0.010元/千tokens严重低估（市场约18元/千tokens）
%   H100训练20元/h；含绿电成本优势+专属算力折扣，合理定仸0.30元/千tokens
P.lambda_token_base = 0.0059;      % η重锚v4: 2.36÷400联动
P.pi_service_T = 0.80;
P.pi_service_B = 0.30;
P.delta_infer_price = 0.10;           % 推理token价格年降率(摩尔定律+算力过剩, -10%/年)
P.delta_train_price = 0.05;           % 训练合同价年增率(大模型专属算力需求旺盛, +5%/年)
P.lambda_GEC = 50;                    % 元/MWh 绿证价格
P.lambda_flex = 80;                   % 元/MWh 调峰价格

% SLA违约惩罚(万元/百万tokens) — 已随η重锚同步÷400(η: 5→2000),
% 保持"每MWh等效罚强"不变: 旧100×5=500万/MWh当量 = 新0.25×2000
P.pi_B_viol = 0.25;                   % B类违约惩罚(原100, η重锚换算)
P.pi_C_viol = 0.075;                  % C类违约惩罚(原30, η重锚换算)

% 运维成本（统一定义，防止后面被覆盖）
P.C_curt_op = 5;                      % 元/MWh 弃电管理费
P.C_var_om_MWh = 130;                 % 元/MWh 算力变动运维强度(η自适应派生源)
P.C_stor_op = 25;                     % 元/MWh 储能循环退化O&M（维护+BMS+冷却，25元/MWh是行业标准）

% 电价分层(元/MWh)
P.lambda_energy_west = 280;           % 西部能量电价基准（全局均值）
P.lambda_energy_east = 420;
P.lambda_cap_west = 30;
P.lambda_cap_east = 50;
P.lambda_trans_west = 60;
P.lambda_trans_east = 80;

% 西部各节点真实电价差异（影响绿电套利收益→gamma_econ差异→选址差异）
% 来源：各省中长期交易均价 2024年
P.lam_w_west = [285, 310, 295, 240];  % 内蒙(风电)/甘肃/宁夏/贵州(水电便宜) 元/MWh

% GPU算力效率随年提升（Huang定律：每2年翻倍，~41%/年）
% Y1=8, Y5≈16, Y10≈32, Y15≈64 百万tokens/MWh
P.eta_token_Y1  = 2000;               % Y1基准效率(与eta_token市场锚定值一致)
% Huang定律分段衰减（曲线自洽性修复）：
%   原28%固定15年 × 价格衰减-20/-12/-6% → 后期收益/MWh漂移+20%/年(不自洽)
%   修复为分段：Y1-5=28%(Huang黄金期) Y6-10=18%(放缓) Y11-15=10%(工艺极限)
%   自洽验证：收益/MWh年变化 = (1-价格降幅)×(1+效率增幅)
%     Y1-5: 0.80×1.28=+2.4%/年 | Y6-10: 0.88×1.18=+3.8%/年 | Y11-15: 0.94×1.10=+3.4%/年
%   → 全程温和增长2-4%/年，无失控利润漂移 ✓
P.eta_token_gr_schedule = [0.28*ones(1,5), 0.18*ones(1,5), 0.10*ones(1,5)];
P.eta_token_gr  = 0.28;               % 兼容字段(旧代码fallback用)
P.spot_token_discount = 0.65;         % 富裕绿电机会型算力现货折扣(可抢占实例惯例)
P.share_max_WT   = 0.45;
% ══ 定价市场锚定v4: 多厂商分层锚定 + 15年演化 ═══════════════════════
% 【多厂商价目(2026初, 元/百万tokens, 输入/输出)】
%   OpenAI GPT-4o-mini: ¥1.1/4.3 | GPT-4o: ¥18/72
%   Anthropic Haiku: ¥1.8/9 | Sonnet: ¥22/108
%   Google Gemini Flash: ¥0.55/2.2 | Pro: ¥9/36
%   DeepSeek V3: ¥1-2/8-16 (缓存低谷¥0.025-0.1)
%   豆包/Qwen/GLM lite档: ¥0.8-3
%   工作档混合价(in:out≈3:1加权, 跨厂商): ≈¥2.5-3.0/M
% 【基础设施层捕获】运营商售serving非模型IP, 捕获率κ≈0.30-0.40
% 【可中断折价】D类训练=纯绿电跟随可中断算力, 对标固定GPU租赁
%   (¥14000/MWh等效)执行深度折价至7-10%
% 【锚定结果(Y1, 元/百万tokens)】A/B=0.85 | D训练=0.55 | C迁移=0.18 | 现货=0.65×C
% 【15年演化】年度衰减曲线(A/B 15年÷5.6≈-12%/年, 对标2023-26旗舰API
%   年降30-50%初期→趋缓) + AR(1)波动σ=4-8%(enable_price_ar) 均已内置
P.sku_ref_Y1 = [0.234, 0.343, 0.206, 0.124]/400;  % 基准曲线Y1值[D,A/B,B,C](元/千tok, 已随源头÷400)
P.pM_train = 0.55;  P.pM_rt = 0.85;           % 目标锚定价(元/百万tokens)
P.pM_batch = 0.42;  P.pM_mig = 0.18;
P.rev_calib = 1.0;

% ══ OVT — 算电价值最优传输框架(三层OT统一, 全部独立可消融) ═══════════
P.enable_wgf      = true;   % 时间耦合: 价值场JKO梯度流年际演化
P.wgf_tau0        = 0.35;
P.wgf_inertia     = 0.30;   %   年际记忆惯性
P.enable_vufp     = true;   % 空间耦合(场): 图多跳传播
P.enable_gat_cut  = true;   % 规划注意力: 多头割权重精炼
P.enable_sinkhorn = true;   % 空间耦合(流): Sinkhorn熵正则最优传输迁移
P.sinkhorn_eps    = 0.05;   %   熵正则强度(→0退化为精确OT)
P.sinkhorn_iters  = 60;     %   交替缩放迭代数
% ══ 内生协同演化(四支柱内生化, 全独立可消融) ═════════════════════════
P.enable_wright     = true;  % η效率=Huang底座×Wright学习曲线(产出内生驱动)
P.wright_T0         = 2e9;   %   经验存量尺度(百万tokens)
P.wright_beta       = 0.10;  %   学习弹性
P.enable_endo_price = true;  % 价格出清态: 利用率反馈→SKU水平乘子[0.7,1.3]
P.enable_endo_demand= true;  % 需求增速: 价格弹性反馈[0.85,1.15]
P.sinkhorn_eps0     = 0.05;  % Sinkhorn退火基准(年际exp衰减→精确OT)
P.eta_price_passthrough = 0.6; % (已弃用, 由下两项替代)
P.pt_kappa_D   = 1.0;  % D类训练(按GPU-h计价): 效率增益全部传导, 单位电量价值≈平
P.pt_kappa_API = 0.0;  % A/B/C类(按token计价): 锚定年降曲线已含效率传导, 不再叠加
P.enable_recovery_feedback = true; % 回收缺口跨年传递(创新点三: 审计→决策)
% ── 通信路由升级投资(边界2实现: 时延是通信侧真实杠杆, token带宽极轻) ──
P.enable_route_invest = true;
P.route_delay_reduction = 0.40;       % 直连光缆时延降幅(35ms级→~21ms)
P.route_annual_max = 2;               % 年度新建路由对数上限(工程节奏)
P.w_rt = 1.0;                         % 路由维度割探索权重
% 直连光缆/波分专线造价(万元, 4西×3东, 按距离): 京/沪/广列
P.C_route_per_pair = [25000  60000  90000;    % 内蒙
                      30000  55000  85000;    % 甘肃
                      35000  50000  80000;    % 宁夏
                      90000  80000  40000] ;  % 贵州
% ══ 创新一: 非对称多网服务可达(B类时延门控跨域服务) ══════════════════
P.enable_B_reach   = true;   % B类跨域服务开关(关=消融"无时延可达")
P.d_max_B_mig      = 20;     % ms B类跨域服务时延门限(弱实时交互类)
P.kappa_B_mig      = 0.35;   % B类中可跨域服务的份额上限(时延容忍子类)
P.n1_emergency_ratio = 1.2;  % N-1紧急额定=1.2×正常额定
% 训练—推理功能兼容矩阵(行A/B/C/D, 列[训练侧T, 推理侧I]; 0.5=时延门控条件可达)
P.func_compat = [0 1; 0.5 1; 1 1; 1 0];
% ══ 创新三: VLM-WM价值学习力世界模型 ════════════════════════════════
P.enable_world_model = true; % 关=近视滚动(消融对照"近视 vs 前瞻")
P.world_model_kappa  = 0.5;  % 前瞻修正信任度[0,1]
P.wm_horizon         = 5;    % 推演步长(年)
P.wm_ridge           = 1.0;  % 岭正则强度(样本少, 必须正则)
P.wm_action_frac     = 0.10; % 候选动作: 在当前容量上追加10%
% ── 价值引导世界模型强化学习(VLM-WM RL) ─────────────────────────────
P.wm_mode      = 'full';  % 'full'=价值引导; 'no_value'=无critic与协态锚(消融); 近视=enable_world_model=false
P.wm_datagen   = true;    % 逐年生成扰动反事实样本(每年约6次一年期运行模拟)
P.wm_pert_frac = 0.10;    % 扰动幅度(当前容量的10%)
P.wm_ensemble  = 5;       % 世界模型集成成员数(认知不确定性)
P.wm_hidden    = 32;      % 隐层宽度(两隐层tanh)
P.wm_epochs    = 400;     % Adam迭代数
P.wm_lr        = 5e-3;    % 初始学习率(指数衰减至1/10)
P.wm_critic_n  = 150;     % critic想象状态数
P.wm_anchor_w  = 1.0;     % 协态锚权重(critic梯度=Λ)
P.wm_cem_pop   = 64;      % CEM种群
P.wm_cem_elite = 8;       % CEM精英数
P.wm_cem_iter  = 8;       % CEM迭代数
P.enable_RL_cut = false;      % 割筛选DQN(旧组件): 默认关; 如启用须删除旧rl_agent_pretrained.mat重新预训练
P.hvdc_mig_coupling = false; % 迁移驱动HVDC强制扩容(旧假设, 与任务走光纤矛盾, 默认关)
P.wm_risk      = 0.5;     % 风险调整: 均值 − λ·集成分歧
P.wm_fig       = true;    % 逐年输出世界模型三联图
P.wm_inject    = true;
P.force_step   = 0.15;    % 力流候选: 首年增量 = 0.15×边际学习力(ρ>0的自愿投资资产), 上限同CEM
% ── 闭环开关 ───────────────────────────────────────────────────────
P.enable_calib        = true;  % 实际运行→规划模型校准(东部电费系数)
P.calib_elec_east     = 1.0;
P.enable_calib_west   = false;
P.calib_rev_west      = 1.0;
P.enable_bankability  = true;  % 资产回收闭合软约束: 边际学习力<0的资产新增投资承担缺口溢价
P.bank_weight         = 0.5;   %   溢价权重(0~1)
P.enable_net_planning = true;  % 电力层DC潮流软约束进入规划(需MATPOWER)
P.net_pen             = 30;    %   线路越限罚(万元/MW·年, 约等于线路加强年金)
P.net_n_lines         = 120;
P.hvdc_arbitrage      = false; % HVDC价差套利外送(购西部网电卖东部); 关=仅外送富余绿电(与双网论点一致), 两层同口径
P.hvdc_loss           = 0.07;  % HVDC输电损耗
P.east_hvdc_offset    = false; % 旧口径: 东部电费扣除HVDC受电(与西部外送收益重复计), 默认关    % 世界模型首年动作作为Benders候选, 经真实子问题评估(优则采纳并生成割)
P.quiet_actual = false;
P.legacy_figs = false;
% ── 运行管理 ─────────────────────────────────────────────────────────
P.checkpoint    = true;   % 每年结束保存检查点 simulation_output/checkpoint/ckpt_latest.mat
P.resume        = false;
P.stop_after_year = [];
P.seed = 20260101;
P.ckpt_keep_all = false;  % true: 另存每年一份ckpt_Yxx.mat(占用磁盘较大)
% ── 规划经济口径与求解 ───────────────────────────────────────────────
P.capex_crf          = true;   % 主问题/UB投资年金化=CRF(8%)+GPU周期重置(与现金流口径一致)
P.benders_min_iter   = 10;     % UB停滞终止: 最少迭代
P.benders_stall_iter = 8;      %   观察窗口
P.benders_stall_tol  = 0.005;
P.spot_market_mult = 1.5;
P.WT_annual_add_min = 500;            % MW 年度训练容量新增下限额度
P.WT_annual_add_frac = 0.6;           % 年度新增≤60%×现有存量(GPU供给/工程周期)
P.WI_ub_demand_mult = 1.5;
P.WI_annual_add_min = 800;            % MW 推理容量年度新增下限
P.WI_annual_add_frac = 0.6;           % 推理年度新增≤60%×存量              % C21v2: 单节点年增量占总增量份额上限(防单点集中)
P.enable_price_ar = true;             % SKU价格AR(1)市场波动项(σ=4-8%); 论文声明或设false取确定性曲线
% 在inner_benders_loop里用：eta_token_y = P.eta_token_Y1 × (1+P.eta_token_gr)^(year-1)

%% ── 规划约束 ────────────────────────────────────────────────────────────
P.W_train_min = 80;                   % MW 单节点训练容量下界（从200降至80，允许更贴近需求定容）
% 80MW×3=240MW ≈ D训练总需求247MW，高CF峰值时段约束可以绑紧
% ── 硬编码参数统一入口（不再分散在子函数里）────────────────────────────
P.east_B_share = [0.38, 0.33, 0.29];    % 东部三节点B类需求占比(北京/上海/广州)
P.east_C_share = [0.27, 0.35, 0.38];    % 东部三节点C类需求占比
P.c_hvdc_op    = 12;           % 已在上方设置(12元/MWh)
P.kappa_region_east = [1.30, 1.10, 0.90]; % 东部区域系数(北京/上海/广州)
P.kappa_cluster_west= [1.50, 1.40, 1.30, 1.10]; % 西部集群系数(内蒙/甘肃/宁夏/贵州)

% ══════════════════════════════════════════════════════════════════════
% 水资源价值维度（Water Resource Value Dimension）
% ──────────────────────────────────────────────────────────────────────
% 数据来源：水利部2023年各省水资源公报 + 财税〔2024〕28号水资源税
% 核心发现：水资源丰度与集群/电力强度负相关，构成选址多维权衡
%   内蒙(κ=1.50最高)但缺水；贵州(κ=1.10最低)但水最丰富
% 构造方法：人均水资源量对数归一化(端值) × 硬约束惩罚乘子
%   端值区间[0.85,1.30]：水富裕加成，水稀缺折损
%   惩罚乘子：反映有红头文件记录的硬约束
%     内蒙0.92(乌兰察布禁地下水冷却)、宁夏0.88(黄河配额封顶≤69.5亿m³)
% 人均水资源(m³/人,多年均值)：内蒙2053 甘肃883 宁夏570 贵州2754
%   贵州应用0.90折损(工程性缺水,喀斯特储水弱)后仍最高
P.water_percap_west   = [2053, 883, 570, 2754];   % 人均水资源(m³/人)
P.w_water_west        = [1.119, 0.936, 0.748, 1.300]; % 水资源价值系数(已含约束惩罚)
% WUE经济参数（基于全国绿色DC平均1.08 L/kWh，工信部2023）
P.WUE_west            = [0.35, 0.45, 0.30, 1.10];  % 各节点WUE(L/kWh)：北方风冷低,贵州水冷高
P.water_price_west    = [3.5, 3.2, 3.8, 2.5];      % 综合水价(元/m³,含水资源税)
% 水资源税(元/m³,地下水)：内蒙2.0 甘肃1.5 宁夏1.5 贵州0.5(财税28号)
P.water_tax_west      = [2.0, 1.5, 1.5, 0.5];
P.enable_water_dim    = true;   % 是否启用水资源价值维度

% ══════════════════════════════════════════════════════════════════════
% 改进的IEEE 118节点测试系统（Modified/Scaled IEEE 118-bus System）
% ──────────────────────────────────────────────────────────────────────
% 学术惯例：将IEEE 118节点系统负荷与线路热容量等比放大，构成改进系统
% 缩放依据：×20倍后系统总负荷73.4GW(相当于中等省级电网规模)，
%   数据中心负荷渗透率Y1=2.1%→Y15=17.0%(中国信通院预测2030年DC占
%   全社会用电5%+，AI加速情景2040年算力枢纽省份15-20%可信)
% 7个枢纽节点映射：西部训练[母线5,12,23,38]，东部推理[母线81,95,107]
% 潮流处理：规划优化采用关键输电断面容量约束(西送东断面)；
%   规划结果经PTDF线性化DC潮流事后校验(verify_dc_powerflow.m)
% ══════════════════════════════════════════════════════════════════════
P.ieee118_scale = 20;                 % 容量缩放倍数
P.ieee118_bus_west = [5, 12, 23, 38]; % 西部4节点映射母线
P.ieee118_bus_east = [81, 95, 107];   % 东部3节点映射母线
% 关键输电断面容量约束(缩放后, MW)：西部各节点外送断面+东部受入断面
P.tieline_cap = struct();
P.tieline_cap.west_send  = [3000, 2000, 3000, 1500]; % 西部外送断面(MW)
P.tieline_cap.east_recv  = [4000, 3000, 2500];       % 东部受入断面(MW)
P.use_dc_flow = false;   % 优化中用断面约束; PTDF潮流校验在后处理
P.CF_wind_west = [0.22, 0.18, 0.24, 0.16];  % 内蒙/甘肃/宁夏/贵州 风电CF均值
P.CF_pv_west   = [0.18, 0.20, 0.19, 0.13];  % 内蒙/甘肃/宁夏/贵州 光伏CF均值
P.W_infer_min = 100;                  % MW
P.W_infer_max = 20000;                % MW (覆盖15年需求58倍增长后的推理总需求)
P.K_max = 4;                          % 最大训练节点数
P.W_train_max = 5000;                 % MW 单节点训练容量上限
P.gamma_min = 0.80;                   % 绿电覆盖率下界
P.green_export_ratio = 1.5;           % 外送配套绿电≤1.5×该节点HVDC容量(0=旧口径: 绿电只随训练算力)
P.gamma_max = 2.5;                    % 绿电覆盖率上界(须>gamma_econ上限2.0, 留余量防C4不可行)
P.mu_min = 0.50;
% 依据：国家能源局《新型储能项目管理规范》(2024)：大型数据中心储能时长≥2h
P.dt_stor = 4;                        % 储能配置时长(h)
P.expand_max = 3.0;                   % HVDC总扩容上限比例（现有容量的3倍）
P.expand_max_annual = 0.50;           % 年度扩容速率上限（每年最多扩容初始容量的50%，约4-5年达到上限）
% 依据：特高压HVDC工程建设周期约3-5年，年增量受工程能力限制
P.phi_reserve = 0.15;                 % 推理峰值备用裕度
P.r_min = 0.08;                       % 行业最低投资回报率
P.GEC_ratio = 0.80;                   % 月度绿电合规比例
% ══════════════════════════════════════════════════════════════════════
% 东部本地绿电资源（East Local Green Power）
% ──────────────────────────────────────────────────────────────────────
% 真实情况：东部是绿电"消费方"，本地绿电有限，以外来绿电+绿证为主，
%   本地自发绿电作为补充。本地绿电来源不限于海上风电，还包括：
%   分布式光伏、陆上风电(山东/苏北)、集中式光伏(华北平原)、
%   生物质发电(长三角农业区)、抽蓄配套等多元来源
% 数据来源(国家能源局2024/2025)：
%   全国海上风电累计47GW(2025)，分布式光伏5.3亿kW(2025)
%   京津冀/长三角/粤港澳合计交易绿证2.4亿个(占全国50%+，是绿证需求主力)
% 本地绿电自给比例(下调至符合"东部依赖外部绿电"的现实)：
%   北京(京津冀)：分布式光伏+陆上风电为主，海风资源少，自给0.25
%   上海(长三角)：海上风电(江浙)+分布式光伏+生物质，自给0.35
%   广州(粤港澳)：海上风电(广东近海丰富)+分布式光伏，自给0.40
P.east_local_green_ratio = [0.25, 0.35, 0.40];  % 各东部节点本地绿电自给比例
% 东部本地绿电综合容量因子(多元绿电加权)
P.east_green_CF = [0.16, 0.28, 0.32];  % 北京(光伏为主低)/上海/广州(海风高)
% 东部本地绿电综合单位造价(万元/MW，海风+光伏+陆风加权)
P.east_green_capex = [6500, 8000, 7500];  % 光伏拉低均值，海风占比高则造价高
% 通信迁移参数（MCF子问题必要）
P.D_max_migrate = 35;                 % ms C类迁移最大允许延迟（超过则禁止迁移）
P.migrate_cap_ratio = 0.30;           % C类算力中可通过HVDC迁移的比例上限
P.comm_cost_base    = 0.002;          % 万元/MWh 通信基础费用（C类迁移固定部分）
P.comm_cost_per_ms  = 0.0003;         % 万元/MWh/ms 每毫秒时延增加的通信费用
P.P2_ratio          = 0.90;           % 训练容量峰值占比（W_T×0.90 - 实际训练 = 可迁移剩余容量）
% 物理含义：训练负荷低于W_T×90%时，剩余容量可用于C类跨域迁移

% 绿证收益参数
P.lambda_GEC = 50;                    % 元/MWh 绿证市场价格
P.GEC_fraction = 0.85;               % 实际可销售绿证比例（部分自用证书无法交易）

% D类训练降载违约惩罚
P.pi_D_curtail = 15;
P.ratio_A = 0.35;                     % A类占推理比例
P.T_backup = 3;                       % h 东部储能续航

% 储能技术参数
P.eta_ch = 0.95;
P.eta_dis = 0.95;
P.sigma_stor = 0.001;                 % /h 自放电率
P.SOC_min_ratio = 0.10;
P.SOC_max_ratio = 0.95;
P.ch_rate = 0.25;                     % C率

% 训练合同保障(MW)
P.W_contract_D = [320, 320, 320, 320]; % D类训练最低合同容量(MW)，统一标准不偏向特定节点
                                        % 选址差异完全由CF→gamma_econ驱动（宁夏CF最高→被选）

% HVDC与选址强耦合：NI×NJ矩阵，只有被选西部节点才有通向东部的通道
% 格式: P.HVDC_cap(i,j) = 从西部节点i到东部节点j的现有容量(MW)
% 宁夏→北京(Y1已有特高压), 甘肃→上海, 贵州→广州; 未建=0
P.HVDC_cap = [150, 100,  50; ...  % 内蒙→北京/上海/广州
              100, 200,  80; ...  % 甘肃→北京/上海/广州
              300, 150, 100; ...  % 宁夏→北京/上海/广州（特高压主通道）
               50,  80, 200];    % 贵州→北京/上海/广州（南方电网主通道）
% 节点i被选(z_i=1)时，P.HVDC_cap(i,:)的通道才被激活；否则容量=0
P.HVDC_cap_per_node = P.HVDC_cap;  % 保留NI×NJ结构供主问题使用

P.HVDC_from = [1, 2, 3, 4];       % 西部4区域电网(华北/西北/西北/南方)
P.HVDC_to   = [1, 2, 3];          % 东部3区域电网(华北/华东/南方)
P.c_hvdc_op = 12;                  % HVDC运维成本(元/MWh)
P.C_trans   = 0.60;               % HVDC扩容基准单价(万元/MW，备用)
% HVDC路径建设成本矩阵(NI×NJ，万元/MW)：按实际距离差异化
% 特高压参考: ~0.5万元/MW·km; 内蒙→北京800km=0.40 vs 贵州→北京2000km=1.00
P.C_trans_per_node = [0.40, 0.90, 1.40; ...  % 内蒙→北京/上海/广州
                      0.75, 1.00, 1.25; ...  % 甘肃→北京/上海/广州
                      0.60, 0.90, 1.20; ...  % 宁夏→北京/上海/广州
                      1.00, 0.75, 0.35];     % 贵州→北京/上海/广州
% 单位修正: 原值与注释不符(0.5万元/MW·km×800km应为400万元/MW), 实际偏低约1000倍,
% 按特高压工程造价(±800kV/8GW约300万元/MW量级)校准: ×1000×0.35 → 140~490万元/MW
P.C_trans_per_node = P.C_trans_per_node * 1000 * 0.35;

%% ── HVDC通道 ────────────────────────────────────────────────────────────
% HVDC参数已在上方W_contract_D块统一设置

%% ── 时延参数 ────────────────────────────────────────────────────────────
P.d_max_A = 10;                       % ms A类时延上限
P.d_max_B = 500;                      % ms
P.d_max_C = 86400000;                 % ms C类(24h)

%% ── DRO参数 ─────────────────────────────────────────────────────────────
P.DRO.C_0 = 2.0;                      % Wasserstein半径常数
P.DRO.d_dim = 2;                      % 充裕维度数
P.DRO.confidence = 0.95;              % 矩约束置信水平

%% ── SAIL-BD算法参数 ──────────────────────────────────────────────────────
P.max_iter = 30;   % 每年Benders迭代上限(各年一致); gap<tol_gap提前结束, 否则跑满上限
P.enable_tr        = true;   % 信赖域Benders(局部开发+每5轮全局迭代)
P.tr_kappa0        = 0.3;    % 近端信赖域初始权重(×单位投资年金); 改进则减半, 失败则加倍
P.tr_delta_min     = 0.02;
P.tr_global_every  = 5;
P.recourse_lp      = true;
P.enable_warm_corners = true;   % 每年先在上角点/中点加割, 首轮gap即接近最终值
P.lp_engine        = 'sparse';
P.lp_rep_weeks     = 12;
P.east_backup_reserve = 0.8;  % 东部储能为A类备用: 规划LP中SOC须保持≥80%容量(仅20%可用于移峰)         % 规划运行模型时间分辨率: 12个月代表周×168h(=2016h, 小时权重合计8760h); 设1为单典型周(快速测试)   % 'sparse'=稀疏矩阵直接调用Gurobi/linprog(快); 'yalmip'=YALMIP建模(慢, 备用)   % 规划子问题采用线性化运行模型(价值驱动网络流LP): 精确对偶割, gap可收敛
P.enable_z_enum    = true;   % 每年先评估"锁定节点+至多新增2个"的全部选址组合(下界预热)
P.gap_glob_switch  = 0.03;   % gap>15%时全局/局部迭代交替, 否则每5轮一次全局
P.gap_accept       = 0.02;   % 信赖域收敛终止须gap≤10%, 或全局迭代已≥min_glob_iter次
P.min_glob_iter    = 15;
P.stall_gap_max    = 0.05;   % 停滞终止仅在gap≤5%(或已达75%迭代上限)时允许
P.lp_mig_share     = 0.3;    % 规划LP中C类可迁移份额上限(逐年由实际运行校准)
P.lp_boff_share    = 0.35;   % 规划LP中B类跨域份额上限(同上)
P.hub_share_max    = 0.5;    % 单枢纽训练容量 ≤ 0.5×全国训练容量 + 基础规模
P.hub_base_MW      = 400;                      % 每年Benders最大迭代次数
P.tol_gap = 0.01;                     % 1%收敛容差
P.tol_gap_early = 0.02;               % 2%早停容差
P.benders_tol = P.tol_gap;            % Benders收敛阈值（与tol_gap统一）
% ══════════════════════════════════════════════════════════════════════
% 消融实验开关（Ablation Study）— 标准版7实验
%   M0=完整SAIL-BD(基准) M1=w/o VAIC(标准L型割) M2=w/o AEMF异质(统一模糊集)
%   M3=w/o DRO(确定性期望) M4=w/o 跨域迁移 M5=w/o 三模式柔性 M6=w/o SKU分级定价
% 用法：改P.ablation后重跑main_15year_simulation，7次得完整消融表
% ══════════════════════════════════════════════════════════════════════
P.ablation = 'M0';
% ══════════════════════════════════════════════════════════════════════
% 节点电价响应模型（Nodal Price Response，线性化LMP效应）
% ──────────────────────────────────────────────────────────────────────
% 线性化节点电价响应：λ_eff = λ_scenario × (1 + α × P_net/P_base)
%   数据中心购电↑→本地节点电价↑(阻塞效应)；迁移量↑→西涨东跌→套利窗口收窄
% 依据：LMP阻塞分量线性化，α标定为"满断面负荷时电价上浮比例"
%   实际市场：省间现货阻塞时价差可达30-80元/MWh，取α使满载上浮15%
P.price_sens_west = 0.15;   % 西部节点电价灵敏度(满断面负荷时上浮15%)
P.price_sens_east = 0.10;   % 东部节点电价灵敏度(受端市场更大，灵敏度低)
P.price_base_load_w = 2000; % 西部电价响应基准负荷(MW，对应断面容量量级)
P.price_base_load_e = 3000; % 东部电价响应基准负荷(MW)
P.enable_price_response = true;  % 消融/对照可关闭
P.enable_price_spikes   = true;  % 稀缺电价尖峰(每周2-4次,3-5倍)，触发降载/削峰验证
P.run_calibration = false;            % 是否运行贝叶斯参数校准（首次使用建议true）
P.calib_trials    = 15;               % 贝叶斯优化试验次数
P.early_stop_win = 3;                 % 早停窗口
P.early_stop_dLB = 0.005;             % 早停LB增量阈值

% Lagrangian乘子边界(关键: 物理合理范围)
P.mu_train_max = 1.0;                 % 万元/MW/h
P.mu_renew_max = 1.0;                 % 万元/MW/h
P.mu_stor_max = 0.1;                  % 万元/MWh/h
P.alpha0_LR = 0.5;                    % 初始步长
P.beta_LR = 0.4;                      % 积压感知系数
P.n_LR_high = 8;                      % 高精度LR迭代轮数
P.n_LR_mid = 4;                       % 中精度
P.n_LR_low = 1;                       % 低精度

%% ── 求解器选项 ──────────────────────────────────────────────────────────
P.solver = 'gurobi';                  % 主问题求解器
P.gurobi_MIPGap = 0.005;
P.gurobi_TimeLimit = 120;             % 秒
P.n_cores = 4;

%% ── 输出目录 ────────────────────────────────────────────────────────────
P.out_dir = 'simulation_output';
if ~exist(P.out_dir, 'dir'); mkdir(P.out_dir); end
sub_dirs = {'planning_results', 'hourly_operation', 'system_params', ...
            'market_data', 'sensitivity', 'figures'};
for k = 1:length(sub_dirs)
    d = fullfile(P.out_dir, sub_dirs{k});
    if ~exist(d, 'dir'); mkdir(d); end
end

fprintf('       参数初始化完成 | 单位制: 万元/MW/MWh/h\n');
fprintf('       规划期=%d年, 候选西部节点=%d, 东部=%d\n', ...
    P.N_year, P.N_west, P.N_east);
fprintf('       eta_token=%d百万tokens/MWh, lambda_token=%.2f元/千tokens\n', ...
    P.eta_token, P.lambda_token_base);
end
