%% =========================================================================
%  BendersRLEnvironment.m — MATLAB RL Toolbox 自定义环境
%
%  将Benders割筛选问题定义为标准MDP，供rlDQNAgent学习最优策略
%
%  状态空间 (4维连续)：
%    s1 = gap_normalized ∈ [0,1]       当前Benders间隙(归一化)
%    s2 = cuts_normalized ∈ [0,1]      累计割数量(归一化)
%    s3 = eps_ratio ∈ [0,1]            Wasserstein半径相对变化
%    s4 = iter_progress ∈ [0,1]        迭代进度(iter/max_iter)
%
%  动作空间 (离散4个)：
%    a=1: keep_fraction=1.0  a=2: keep_fraction=0.8
%    a=3: keep_fraction=0.6  a=4: keep_fraction=0.5
%
%  奖励函数：
%    R = -gap_new/gap_old + conv_bonus × I(gap<tol) - time_penalty×(4-a)
%    → gap改善越多奖励越高; 收敛额外奖励; 丢割越多时间惩罚越少
%
%  使用方法：
%    env = BendersRLEnvironment(P);
%    agent = createDQNAgent(env);
%    [agent, trainingStats] = train(agent, trainOpts);
%% =========================================================================
classdef BendersRLEnvironment < rl.env.MATLABEnvironment

    properties
        P                   % 系统参数
        CurrentGap = 0.5    % 当前gap
        PrevGap    = 0.5    % 上一步gap
        CurrentCuts = 0     % 当前割数
        EpsRatio   = 1.0    % Wasserstein半径变化比
        IterProgress = 0     % 迭代进度
        MaxCuts    = 30      % 最大割数(归一化用)
        StepCount  = 0       % 当前episode步数
        MaxSteps   = 15      % 每episode最大步数(对应15年)
    end

    properties (Access = protected)
        IsDone = false
    end

    methods
        %% 构造函数
        function env = BendersRLEnvironment(P)
            % 观测空间：4维连续，均归一化到[0,1]
            obsInfo = rlNumericSpec([4 1], ...
                'LowerLimit', zeros(4,1), ...
                'UpperLimit', ones(4,1));
            obsInfo.Name        = 'Benders状态';
            obsInfo.Description = '[gap_norm, cuts_norm, eps_ratio, iter_prog]';

            % 动作空间：离散4个动作
            actInfo = rlFiniteSetSpec({1,2,3,4});
            actInfo.Name = 'keep_fraction_idx';

            % 调用父类构造
            env = env@rl.env.MATLABEnvironment(obsInfo, actInfo);
            env.P = P;
        end

        %% step函数：执行一步，返回(obs, reward, isDone, info)
        function [obs, reward, isDone, info] = step(env, action)
            % action ∈ {1,2,3,4} → keep_fraction
            keep_fracs = [1.0, 0.8, 0.6, 0.5];
            keep = keep_fracs(action);

            % 模拟Benders一步（用近似动态模型）
            % gap改善：保留割越少→计算越快但gap改善越少（权衡）
            gap_improve_factor = 0.3 + 0.4 * keep;   % keep=1.0→0.7改善；keep=0.5→0.5改善
            new_gap = env.CurrentGap * (1 - gap_improve_factor * 0.25 + 0.05*randn());
            new_gap = max(0, min(1, new_gap));

            % 计算奖励
            tol = env.P.tol_gap;
            gap_ratio = new_gap / max(env.CurrentGap, 1e-6);
            reward = (1 - gap_ratio) * 10;            % gap改善奖励
            if new_gap < tol; reward = reward + 5; end % 收敛额外奖励
            time_save = (1 - keep) * 0.5;             % 减少割 = 节省时间
            reward = reward + time_save;

            % 更新状态
            env.PrevGap     = env.CurrentGap;
            env.CurrentGap  = new_gap;
            env.CurrentCuts = min(env.MaxCuts, env.CurrentCuts + 1);
            env.StepCount   = env.StepCount + 1;
            env.IterProgress = env.StepCount / env.MaxSteps;

            % 终止条件
            isDone = (new_gap < tol) || (env.StepCount >= env.MaxSteps);
            env.IsDone = isDone;

            obs  = getObs(env);
            info = struct('gap', new_gap, 'keep_frac', keep);
        end

        %% reset函数：每个episode开始时重置
        function obs = reset(env)
            env.CurrentGap   = 0.4 + 0.3*rand();  % 随机初始gap [0.4,0.7]
            env.PrevGap      = env.CurrentGap;
            env.CurrentCuts  = round(5 + 10*rand());
            env.EpsRatio     = 0.8 + 0.4*rand();
            env.IterProgress = 0;
            env.StepCount    = 0;
            env.IsDone       = false;
            obs = getObs(env);
        end
    end

    methods (Access = private)
        function obs = getObs(env)
            obs = [min(1, env.CurrentGap);
                   env.CurrentCuts / env.MaxCuts;
                   min(1, env.EpsRatio);
                   env.IterProgress];
        end
    end
end
