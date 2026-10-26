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
