function [route_pref, gat_info] = gat_migration_routing(east_state, west_state, P, h_ctx)
%% GAT-Route — Bipartite Graph Attention for compute-task Migration Routing
%  东-西二部图注意力迁移路由(本文运行层核心创新)
%
%  ── 为什么用注意力而非规则MCF(方法论必要性) ──────────────────────────
%  原五因素博弈用固定加权规则决定东j→西i的迁移倾向, 无法表达"路由偏好
%  应随实时上下文(电价/积压/绿电)动态重加权"。二部图注意力让每个东部
%  源节点j对每个西部目标节点i的迁移倾向, 由实时特征匹配度softmax决定:
%  route_{j→i} = softmax_i( (电价差, 绿电富余, 时延, 积压) 的注意力打分 )
%  这是随上下文自适应的软路由, 规则式硬阈值无法表达。
%
%  ── 机制(二部图交叉注意力, 解析前向) ────────────────────────────────
%  Query = 东部源节点需求特征(积压/紧迫度)
%  Key/Value = 西部目标节点供给特征(绿电富余/电价/空闲容量)
%  交叉注意力: 东部"查询"最匹配的西部"承接方", 得软路由分布
%
%  输入:  east_state 结构 (积压B_C, 紧迫度, 东部电价) 各NJ×1
%         west_state 结构 (绿电富余, 西部电价, 空闲容量, 时延) 各NI×1/NI×NJ
%  输出:  route_pref (NJ×NI) 东j→西i的软路由偏好(每行softmax归一)
%         gat_info   注意力诊断

NI = P.N_west; NJ = P.N_east;

% ── 1. 东部源Query特征(需求侧: 越积压越紧迫→越想迁出) ────────────────
Q = zeros(NJ, 3);
Q(:,1) = east_state.backlog(:);        % 积压量
Q(:,2) = east_state.urgency(:);        % 紧迫度
Q(:,3) = east_state.price(:);          % 东部电价(越高越想迁走)
zc = @(v)(v-mean(v))/(std(v)+1e-9);
for c=1:3; Q(:,c)=zc(Q(:,c)); end

% ── 2. 西部目标Key/Value特征(供给侧: 绿电富余+低电价+空闲=好承接方) ──
Kf = zeros(NI, 3);
Kf(:,1) = west_state.green_surplus(:); % 绿电富余(弃电量)
Kf(:,2) = -west_state.price(:);        % 西部电价(越低越优, 取负)
Kf(:,3) = west_state.spare_cap(:);     % 空闲容量
for c=1:3; Kf(:,c)=zc(Kf(:,c)); end

% ── 3. 二部图交叉注意力打分(东j × 西i) ───────────────────────────────
% 时延作为注意力偏置(可达性差→打分惩罚)
d_k = 3;
scores = (Q * Kf') / sqrt(d_k);        % NJ×NI
for jj=1:NJ
    for ii=1:NI
        Dji = P.comm_delay(P.east_hub_idx(jj), P.west_hub_idx(ii));
        scores(jj,ii) = scores(jj,ii) - 0.05*Dji;   % 时延惩罚偏置
        if isfield(west_state,'reachable') && ~west_state.reachable(ii,jj)
            scores(jj,ii) = -inf;                     % 超时延上限不可达
        end
    end
end
% 行softmax(每个东部源的西部承接偏好分布)
scores = scores - max(scores,[],2);
E = exp(scores); E(isnan(E))=0;
route_pref = E ./ max(sum(E,2),1e-9);

gat_info = struct();
gat_info.scores = scores;
gat_info.route_pref = route_pref;
gat_info.entropy = -sum(route_pref.*log(route_pref+1e-9),2);  % 路由集中度
end
