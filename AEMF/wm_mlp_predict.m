function [Ymean, Ystd, Yall] = wm_mlp_predict(net, X)
%% 集成预测: 均值、标准差(认知不确定性)、各成员结果(k×N×M)
Xs = (X - net.mu) ./ net.sd;
M = numel(net.members); N = size(X,2);
Yall = zeros(net.k, N, M);
for m = 1:M
    Yall(:,:,m) = wm_fwd(net.members{m}, Xs) .* net.ysd + net.ymu;
end
Ymean = mean(Yall, 3);
Ystd  = std(Yall, 0, 3);
end
