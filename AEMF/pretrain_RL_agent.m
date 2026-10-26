%% =========================================================================
%  pretrain_RL_agent.m — DQN智能体离线预训练（首次运行前调用一次）
%
%  使用BendersRLEnvironment仿真环境进行500轮预训练
%  训练完成后保存 rl_agent_pretrained.mat，供15年主仿真加载
%
%  用法：
%    P = init_parameters();
%    pretrain_RL_agent(P, 500);   % 约5-10分钟
%    % 之后 main_15year_simulation 会自动加载预训练模型
%% =========================================================================
function pretrain_RL_agent(P, n_episodes)
if nargin < 2; n_episodes = 500; end

fprintf('================================================================\n');
fprintf('  DQN智能体离线预训练 (%d轮)\n', n_episodes);
fprintf('================================================================\n');

addpath(fileparts(mfilename('fullpath')));

%% 初始化智能体和环境
[agent, env] = init_RL_agent(P);

%% 训练选项
trainOpts = rlTrainingOptions(...
    'MaxEpisodes',          n_episodes, ...
    'MaxStepsPerEpisode',   15, ...         % 每轮最多15步（对应15年）
    'ScoreAveragingWindowLength', 50, ...   % 滑动平均窗口
    'StopTrainingCriteria', 'EpisodeCount', ...
    'Verbose',              true, ...
    'Plots',                'none', ...     % 不弹窗
    'SaveAgentCriteria',    'EpisodeReward', ...
    'SaveAgentValue',       -0.05);         % 奖励>-0.05（gap<5%）时保存

%% 开始训练
fprintf('\n开始训练...\n');
trainingStats = train(agent, env, trainOpts);

%% 保存预训练模型
save('rl_agent_pretrained.mat', 'agent', 'trainingStats');
fprintf('\n[预训练完成] 模型已保存: rl_agent_pretrained.mat\n');
fprintf('  训练轮数: %d\n', n_episodes);
fprintf('  最终平均奖励: %.4f\n', mean(trainingStats.EpisodeReward(end-50:end)));
end
