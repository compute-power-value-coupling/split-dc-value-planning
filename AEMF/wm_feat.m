function x = wm_feat(D, eta, mix, cur, pm, K, kbar)
%% 物理—价值联合状态编码(12维)
%  [log需求, log效率, 推理占比, 弃电率, 价格出清乘子, 7类资产饱和度]
%  饱和度 s_a = log(1 + K_a/(D·k̄_a)); 通信路由为计数型, s_7 = log(1+K_7)
s = zeros(7,1);
for a = 1:6
    s(a) = log(1 + max(0, K(a)) / (max(D,1) * max(kbar(a),1e-9)));
end
s(7) = log(1 + max(0, K(7)));
x = [log(max(D,1)); log(max(eta,1)); mix; cur; pm; s];
end
