function [w_att, att_info] = gat_cut_weights(w_local, P, x_sol, SKU, AEMF, year)
%% GAT-VAIC — Graph Attention for Value-Aware Cut weight generation
%  图注意力割权重生成(本文规划层核心创新)
%
%  ── 为什么用注意力而非启发式加权(方法论必要性) ──────────────────────
%  原dQ权重是人工设定的kappa/CF乘积, 无法表达"节点i的割权重应取决于
%  它在整个算电价值网络中的相对重要性"——这是一个需要节点两两比较的量。
%  缩放点积注意力(Transformer同源机制)天然计算这种相对重要性:
%  att_{ij} = softmax(q_i·k_j/√d), 让每个节点的价值权重由它与所有
%  其他节点的价值-资源匹配度决定, 而非孤立的物理禀赋。
%
%  ── 机制(多头缩放点积注意力, 解析前向无需训练) ──────────────────────
%  特征嵌入: 每节点构造d维价值特征向量 h_i = [价值密度, CF, 集群κ,
%            通信可达, 需求份额, 不确定性]
%  Q/K/V投影: 用物理先验构造投影(非随机权重, 保证可复现可解释)
%  多头注意力: H个头捕捉不同价值维度(经济/物理/网络)的重要性
%  输出: 注意力增强的割权重 w_att, 融合节点自身价值与网络位置价值
%
%  输入:  w_local (NI×1) 逐节点局部价值密度
%  输出:  w_att   (NI×1) 注意力增强的割权重
%         att_info 注意力矩阵/头贡献等(可视化+论文图)

NI = P.N_west;
d_model = 6;          % 特征维度
n_head  = 3;          % 多头(经济/物理/网络三视角)

% ── 1. 节点价值特征嵌入 h_i ∈ R^d ────────────────────────────────────
H = zeros(NI, d_model);
CF = 0.19*ones(NI,1);
if isfield(P,'CF_wind_west')&&isfield(P,'CF_pv_west')
    CF = (P.CF_wind_west(:)+P.CF_pv_west(:))/2;
end
kap = P.kappa_cluster_west(:);
del = P.delta_comm(:);
wd  = ones(NI,1); if isfield(P,'w_water_west'); wd = P.w_water_west(:); end
% 需求份额(节点承接的算力需求占比, 用合同容量代理)
dem_share = P.W_contract_D(:) / max(1, sum(P.W_contract_D));
unc = ones(NI,1); if isstruct(AEMF)&&isfield(AEMF,'epsilon_1'); unc = unc*AEMF.epsilon_1; end
% 标准化组装
zc = @(v) (v - mean(v)) / (std(v)+1e-9);
H(:,1)=zc(w_local(:)); H(:,2)=zc(CF); H(:,3)=zc(kap);
H(:,4)=zc(del);        H(:,5)=zc(dem_share); H(:,6)=zc(unc);

% ── 2. 多头缩放点积注意力(物理先验投影, 解析前向) ────────────────────
% 三个头各强调不同价值维度: 头1经济(价值×需求) 头2物理(CF×集群) 头3网络(通信×不确定)
head_proj = { [1 0 0 0 1 0; 0 0 0 0 1 0; 1 0 0 0 0 0],  ...  % 经济头 Q,K,V选择
              [0 1 1 0 0 0; 0 1 1 0 0 0; 0 1 0 0 0 0],  ...  % 物理头
              [0 0 0 1 0 1; 0 0 0 1 0 1; 0 0 0 0 0 1] };     % 网络头
d_k = 2;
att_stack = zeros(NI, NI, n_head);
v_out = zeros(NI, n_head);
for hh = 1:n_head
    Wq = head_proj{hh}(1,:); Wk = head_proj{hh}(2,:); Wv = head_proj{hh}(3,:);
    Q = H * diag(Wq);  K = H * diag(Wk);  V = H * Wv';
    scores = (Q * K') / sqrt(d_k);              % NI×NI相似度
    % softmax行归一(注意力权重)
    scores = scores - max(scores,[],2);
    E = exp(scores); Att = E ./ sum(E,2);
    att_stack(:,:,hh) = Att;
    v_out(:,hh) = Att * V;                       % 注意力加权价值
end
% 多头融合(平均)
v_fused = mean(v_out, 2);

% ── 3. 注意力增强割权重(残差: 保留原始价值+注意力网络修正) ────────────
beta_att = 0.25;                                 % 注意力修正强度
v_fused_pos = v_fused - min(v_fused) + 0.1;      % 平移至正
v_fused_norm = v_fused_pos / mean(v_fused_pos);  % 归一化(均值1)
w_att = w_local(:) .* ((1-beta_att) + beta_att * v_fused_norm);
w_att = max(w_att, 0.1 * w_local(:));            % 下界保护

% ── 4. 诊断输出 ───────────────────────────────────────────────────────
att_info = struct();
att_info.att_matrix = mean(att_stack, 3);        % 平均注意力矩阵(可画热力图)
att_info.head_att = att_stack;
att_info.w_shift = w_att - w_local(:);
att_info.v_fused = v_fused_norm;
end
