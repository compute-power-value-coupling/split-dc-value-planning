%% =========================================================================
%  init_RL_agent.m — 初始化MATLAB RL Toolbox DQN智能体
%
%  网络结构: 4输入→64→32→4输出(Q值)
%  算法: DQN with Experience Replay + Target Network
%
%  用法:
%    [agent, env] = init_RL_agent(P);
%    % 预训练(可选，仿真加速):
%    trainOpts = rlTrainingOptions('MaxEpisodes',200,'StopTrainingCriteria','EpisodeCount');
%    trainingStats = train(agent, env, trainOpts);
%    % 保存:
%    save('rl_agent_pretrained.mat','agent');
%% =========================================================================
function [agent, env] = init_RL_agent(P)

env = BendersRLEnvironment(P);
obsInfo = getObservationInfo(env);
actInfo = getActionInfo(env);

%% ── DQN网络结构（论文式AEMF-RL部分）──────────────────────────────────
% 4输入 → FC64(ReLU) → FC32(ReLU) → FC_nActions(Q值输出)
% 关键：最后一层输出数 = 动作数量，用 numel(actInfo.Elements) 而非 prod(actInfo.Dimension)
% prod(actInfo.Dimension)对rlFiniteSetSpec返回1（单动作标量维），不是动作个数
nObs     = prod(obsInfo.Dimension);   % = 4
nActions = numel(actInfo.Elements);   % = 4（{1,2,3,4}共4个动作）

criticNet = [
    featureInputLayer(nObs, 'Normalization','none', 'Name','obs')
    fullyConnectedLayer(64,       'Name','fc1')
    reluLayer(                    'Name','relu1')
    fullyConnectedLayer(32,       'Name','fc2')
    reluLayer(                    'Name','relu2')
    fullyConnectedLayer(nActions, 'Name','qout')   % 必须=nActions(4)
];
criticDlNet = dlnetwork(criticNet);

%% ── 创建Critic（Q值函数）────────────────────────────────────────────
critic = rlVectorQValueFunction(criticDlNet, obsInfo, actInfo);

%% ── DQN Agent选项 ────────────────────────────────────────────────────
agentOpts = rlDQNAgentOptions(...
    'UseDoubleDQN',             true,   ...
    'TargetUpdateFrequency',    10,     ...
    'ExperienceBufferLength',   2000,   ...
    'MiniBatchSize',            64,     ...
    'DiscountFactor',           0.90);

% ε-贪心探索参数（先创建对象再赋值，兼容各MATLAB版本）
agentOpts.EpsilonGreedyExploration.Epsilon      = 0.30;
agentOpts.EpsilonGreedyExploration.EpsilonDecay = 0.995;
agentOpts.EpsilonGreedyExploration.EpsilonMin   = 0.05;

%% ── 创建DQN智能体 ────────────────────────────────────────────────────
agent = rlDQNAgent(critic, agentOpts);

fprintf('[RL-DQN] 智能体初始化完成\n');
fprintf('  观测空间: [%s] %s\n', num2str(obsInfo.Dimension), obsInfo.Name);
fprintf('  动作空间: %d个离散动作\n', numel(actInfo.Elements));
fprintf('  网络: 4→64(ReLU)→32(ReLU)→4, Double DQN, ε=0.30→0.05\n');
end
