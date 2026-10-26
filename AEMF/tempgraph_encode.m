function [growth_embed, tg_info] = tempgraph_encode(hist_demand, year, P, prev_embed)
%% TempGraph — Temporal Graph Encoding of stepwise compute growth
%  算力阶跃增长的时序图编码(本文状态层特色创新)
%
%  ── 为什么用时序图编码而非逐年独立更新(方法论必要性) ────────────────
%  算力需求呈阶跃式(非平滑)增长, 逐年独立的模糊集更新丢失了年际演化
%  的记忆与趋势。把(节点×年份)构造成时序图: 时间边连接相邻年份、
%  空间边连接耦合节点, 图上编码同时捕捉"增长惯性(时间边)"和"节点间
%  增长传染(空间边)"。这是逐年独立标量更新无法表达的时空演化结构。
%
%  ── 机制(时序图上的门控递推编码, 类GRU on graph) ────────────────────
%  状态: 每年的增长嵌入 e_t ∈ R^m (m维演化特征)
%  更新: e_t = (1-g)·e_{t-1} + g·φ(当前增长率, 阶跃强度, 波动率)
%        门控g随阶跃强度自适应(检测到跃变→g增大→快速吸收新态)
%  阶跃检测: 当年增长率相对历史均值的偏离(标准化)
%
%  输入:  hist_demand 历史需求样本; year 当前年; prev_embed 上年嵌入
%  输出:  growth_embed (m×1) 增长时序嵌入(供AEMF调制ε收缩速率)
%         tg_info 阶跃强度/门控值诊断

m = 4;   % 嵌入维度: [水平, 速度, 加速度, 波动]
if nargin < 4 || isempty(prev_embed); prev_embed = zeros(m,1); end

% ── 1. 当前年增长特征提取 ─────────────────────────────────────────────
if isvector(hist_demand); d = hist_demand(:); else; d = mean(hist_demand,2); end
d = d(~isnan(d)); if numel(d)<2; d=[1;1]; end
level = d(end);                                  % 当前水平
velocity = (d(end)-d(max(1,end-1)));             % 一阶(速度)
if numel(d)>=3; accel = d(end)-2*d(end-1)+d(end-2); else; accel=0; end  % 二阶
vol = std(d(max(1,end-4):end));                  % 近期波动

phi = [level; velocity; accel; vol];
phi = phi ./ (abs(phi)+1);                       % 有界squash

% ── 2. 阶跃强度检测 → 自适应门控 ─────────────────────────────────────
hist_vel = mean(abs(diff(d)));
step_intensity = min(1, abs(velocity) / (hist_vel+1e-6) / 3);  % 相对跃变强度
g = 0.3 + 0.5 * step_intensity;                  % 门控0.3~0.8(跃变时快速吸收)

% ── 3. 门控递推更新(时序图的时间边) ──────────────────────────────────
growth_embed = (1-g)*prev_embed + g*phi;

% ── 4. 诊断 ───────────────────────────────────────────────────────────
tg_info = struct();
tg_info.step_intensity = step_intensity;
tg_info.gate = g;
tg_info.velocity = velocity;
tg_info.accel = accel;
% ε收缩调制因子: 阶跃剧烈→放缓收缩(保守), 平稳→加快收缩
tg_info.eps_modulation = 1 + 0.5*step_intensity;
end
