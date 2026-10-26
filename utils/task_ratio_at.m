function [r, fam] = task_ratio_at(year, P)
%% 任务结构逐年演化: 三类负荷族(非AI / AI推理 / AI训练) → 四个SLA类(A实时/B交互/C批量/D训练)
%  负荷族份额按行业预测标定(McKinsey数据中心需求模型: 2025年训练23.1GW、推理20.9GW、非AI38.3GW;
%  2030年训练62.2GW、推理93.3GW、非AI63.5GW), Y1≈2025、Y6≈2030; Y6之后为情景外推(须做敏感性)。
%  由此训练在前期略高于推理, 约Y2交叉, 之后推理持续超过训练 —— "先训练、后推理"的结构转移
%  fam = [非AI, AI推理, AI训练] 占总需求份额
if ~isfield(P,'use_workload_mix') || ~P.use_workload_mix
    r1 = P.task_ratio; if isfield(P,'task_ratio_Y1'); r1 = P.task_ratio_Y1; end
    r = r1; fam = [NaN NaN NaN];
    if isfield(P,'enable_task_evolution') && P.enable_task_evolution && isfield(P,'task_ratio_end')
        k = 0.55; m = 7; N = P.N_year; sg = @(t) 1./(1+exp(-k*(t-m)));
        w = max(0, min(1, (sg(year)-sg(1)) / max(1e-9, sg(N)-sg(1))));
        r = (1-w)*r1(:)' + w*P.task_ratio_end(:)'; r = r/sum(r);
    end
    return;
end
F1  = [0.466 0.254 0.280];   % Y1(2025): 38.3/82.3, 20.9/82.3, 23.1/82.3
F6  = [0.290 0.426 0.284];   % Y6(2030): 63.5/219, 93.3/219, 62.2/219
F15 = [0.22  0.56  0.22];    % Y15: 情景外推(推理继续上升、前沿训练增速放缓)
if isfield(P,'wl_share_Y1');  F1  = P.wl_share_Y1;  end
if isfield(P,'wl_share_Y6');  F6  = P.wl_share_Y6;  end
if isfield(P,'wl_share_end'); F15 = P.wl_share_end; end
if year <= 6
    w = (year-1)/5;  fam = (1-w)*F1 + w*F6;
else
    w = (year-6)/max(1, P.N_year-6); fam = (1-w)*F6 + w*F15;
end
fam = fam / sum(fam);
M_nonAI = [0.50 0.30 0.20];   % 非AI负荷的SLA构成(A/B/C)
M_inf   = [0.40 0.35 0.25];   % AI推理的SLA构成(强实时/交互/批量推理)
if isfield(P,'sla_mix_nonAI'); M_nonAI = P.sla_mix_nonAI; end
if isfield(P,'sla_mix_inf');   M_inf   = P.sla_mix_inf;   end
r = [fam(1)*M_nonAI + fam(2)*M_inf, fam(3)];
r = r / sum(r);
end
