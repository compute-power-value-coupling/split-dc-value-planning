%% =========================================================================
%  BSASP_precision_allocation.m — 基于GBR的情景精度自适应分配(论文式28-29)
%
%  使用MATLAB fitrensemble('LSBoost')训练梯度提升回归器(GBR)
%  预测各情景的积压违约风险评分，依据风险水平差异化分配拉格朗日迭代精度
%
%  GBR特征向量 φ_s = [CF_std, CF_mean_dev, price_dev, demand_dev, extreme_frac]
%  GBR目标变量 = 上一年该类情景的子问题Q值（归一化，体现风险大小）
%
%  论文对应：公式(28) r_s = GBR(φ_s)
%            公式(29) Prec(s) = 三档精度分配
%% =========================================================================
function precisions = BSASP_precision_allocation(scenarios, iter, P, current_gap, gbr_model)
%  gbr_model: GBR模型(由update_AEMF传入，首次为空用初始化模型)

N_s = scenarios.N_scen;
precisions = cell(N_s, 1);

%% ── 前3轮全高精度（Benders割质量关键期）─────────────────────────────
if iter <= 3
    for s = 1:N_s; precisions{s} = 'high'; end
    return;
end

%% ── 特征提取（φ_s，论文式28）─────────────────────────────────────────
cf_global_mean  = mean(scenarios.cf_combined(:));
price_global_mean = mean(scenarios.price_west(:));
X_feat = zeros(N_s, 5);   % [CF_std, CF_dev, price_dev, demand_dev, extreme_frac]

for s = 1:N_s
    cf_s = scenarios.cf_combined(s,:);
    X_feat(s,1) = std(cf_s);                                      % CF时序标准差
    X_feat(s,2) = abs(mean(cf_s) - cf_global_mean);               % CF均值偏离
    p_s = mean(scenarios.price_west(s,:),'all');
    X_feat(s,3) = max(0, p_s - price_global_mean)/max(1,price_global_mean); % 电价偏离
    if isfield(scenarios,'demand_factor')
        X_feat(s,4) = abs(scenarios.demand_factor(s) - 1);        % 需求偏离
    end
    X_feat(s,5) = sum(cf_s < 0.08) / max(1,length(cf_s));        % 极端低出力比例
end

%% ── GBR风险预测（论文式28：r_s = GBR(φ_s)）──────────────────────────
if nargin >= 5 && ~isempty(gbr_model) && isa(gbr_model,'RegressionEnsemble')
    % 使用训练好的GBR模型预测（在线使用阶段）
    risk_score = predict(gbr_model, X_feat);
else
    % 模型未就绪时：用特征加权直接计算风险评分（bootstrap阶段）
    risk_score = 0.30*X_feat(:,1)/max(eps,max(X_feat(:,1))) ...
               + 0.25*X_feat(:,2)/max(eps,max(X_feat(:,2))) ...
               + 0.20*X_feat(:,3) ...
               + 0.15*X_feat(:,4) ...
               + 0.10*X_feat(:,5);
end
risk_score = risk_score(:);
risk_score = (risk_score - min(risk_score)) / max(eps, max(risk_score)-min(risk_score));

%% ── 精度分配（论文式29，三档：high/mid/low）─────────────────────────
% gap信号调节：gap越大→更多高精度情景；gap越小→降低精度节省算力
gap_factor = 0;
if nargin >= 4 && isnumeric(current_gap)
    gap_factor = min(1.0, current_gap / 0.10);
    if current_gap < 0.02
        for s=1:N_s; precisions{s}='low'; end; return;
    elseif current_gap < 0.05
        for s=1:N_s; precisions{s}='mid'; end; return;
    end
end

progress = min(1.0, (iter-3)/20);
n_high = max(1, round(N_s * (0.40 - 0.15*progress + 0.15*gap_factor)));
n_mid  = max(1, round(N_s * (0.35 + 0.10*progress)));
n_low  = max(0, N_s - n_high - n_mid);

[~, sorted_idx] = sort(risk_score,'descend');
for k = 1:N_s
    s = sorted_idx(k);
    if     k <= n_high;           precisions{s} = 'high';
    elseif k <= n_high + n_mid;   precisions{s} = 'mid';
    else;                         precisions{s} = 'low';
    end
end
end


%% =========================================================================
%  train_BSASP_GBR — 训练/更新GBR模型（每年调用一次）
%
%  输入:
%    X_history: 历史情景特征矩阵 (N_total × 5)
%    Y_history: 对应的情景Q值（归一化风险评分）
%  输出:
%    gbr_model: 训练好的RegressionEnsemble
%% =========================================================================
function gbr_model = train_BSASP_GBR(X_history, Y_history)

if size(X_history,1) < 5
    gbr_model = [];  % 样本不足，返回空（使用启发式兜底）
    return;
end

% fitrensemble with LSBoost = 梯度提升回归（MATLAB RL工具箱外的ML）
% NumLearningCycles=50：50棵树；LearnRate=0.1：学习率；MaxNumSplits=4：浅树防过拟合
template = templateTree('MaxNumSplits', 4, 'MinLeafSize', 2);
try
    gbr_model = fitrensemble(X_history, Y_history, ...
        'Method',           'LSBoost', ...
        'NumLearningCycles', 50, ...
        'Learners',          template, ...
        'LearnRate',         0.10, ...
        'CrossVal',          'off');
    fprintf('  [BSASP-GBR] 模型训练完成：%d样本, MSE=%.4f\n', ...
        size(X_history,1), resubLoss(gbr_model));
catch ME
    warning('GBR训练失败(%s)，使用启发式兜底', ME.message);
    gbr_model = [];
end
end
