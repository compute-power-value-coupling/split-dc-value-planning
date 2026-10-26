function net = wm_mlp_train(X, Y, opts)
%% 深度集成网络训练(世界模型与critic共用) — Deep Learning Toolbox自动微分
%  X: d×N 原始特征;  Y: k×N 目标(NaN=缺失, 按掩码忽略)
%  损失 = 加权预测误差
%       + 物理一致性: 自身饱和特征↑时对应输出不增(边际收益递减)
%       + 价值一致性(可选锚): 在锚点处输出对指定特征的斜率 = 给定目标斜率(协态Λ换算)
%       + L2正则
%  集成: M个成员, 自助法重采样 → 均值与标准差(认知不确定性)
%  无Deep Learning Toolbox时退化为随机特征岭回归集成(无物理项, 打印提示)
[d, N] = size(X); k = size(Y,1);
M = gv(opts,'M',5); H = gv(opts,'H',32); E = gv(opts,'epochs',400);
lr = gv(opts,'lr',5e-3); l2 = gv(opts,'l2',1e-4); w = gv(opts,'w',ones(1,N));
pidx = gv(opts,'phys_idx',zeros(1,k)); pw = gv(opts,'phys_w',1.0); dl_ = gv(opts,'delta',0.5);

mu = mean(X,2); sd = std(X,0,2); sd(sd < 1e-9) = 1;
Xs = (X - mu) ./ sd;
ymu = mean(Y,2,'omitnan'); ysd = std(Y,0,2,'omitnan');
ymu(isnan(ymu)) = 0; ysd(isnan(ysd) | ysd < 1e-9) = 1;
Ys = (Y - ymu) ./ ysd; mask = ~isnan(Ys); Ys(~mask) = 0;

anc = [];
if isfield(opts,'anchor') && ~isempty(opts.anchor)
    a = opts.anchor;
    anc.xs = (a.x_raw(:) - mu) ./ sd;
    anc.fidx = a.fidx; anc.out = a.out; anc.w = a.w;
    anc.slope = a.slope_raw(:)' .* sd(a.fidx)' ./ ysd(a.out)';   % 换算到标准化空间
end

use_dl = ~isempty(which('dlgradient')) && ~isempty(which('adamupdate'));
members = cell(M,1);
for m = 1:M
    rng(100 + m, 'twister');
    idx = randi(N, 1, N);
    bw = accumarray(idx(:), 1, [N 1])' .* w;             % 自助法样本权
    if use_dl
        p = init_params(d, H, k);
        p = structfun(@dlarray, p, 'UniformOutput', false);
        Xd = dlarray(Xs); Yd = dlarray(Ys); Md = dlarray(double(mask)); Wd = dlarray(bw);
        o = struct('pidx',pidx,'pw',pw,'delta',dl_,'l2',l2,'anc',anc);
        if ~isempty(anc); o.anc.xs = dlarray(anc.xs); end
        aG = []; aS = [];
        for it = 1:E
            [~, g] = dlfeval(@loss_fn, p, Xd, Yd, Md, Wd, o);
            lr_it = lr * (0.1 ^ (it / E));                % 指数衰减
            [p, aG, aS] = adamupdate(p, g, aG, aS, it, lr_it);
        end
        members{m} = structfun(@extractdata, p, 'UniformOutput', false);
    else
        members{m} = fit_rff(Xs, Ys, mask, bw, H*4, m);    % 退化: 随机特征岭回归
    end
end
net = struct('members',{members}, 'mu',mu, 'sd',sd, 'ymu',ymu, 'ysd',ysd, ...
             'dl',use_dl, 'k',k, 'd',d);
% 训练集拟合优度(集成均值, 仅有效目标)
[Yh, ~] = wm_mlp_predict(net, X);
r2 = nan(k,1);
for j = 1:k
    v = ~isnan(Y(j,:));
    if sum(v) > 2
        r2(j) = 1 - sum((Y(j,v) - Yh(j,v)).^2) / max(1e-12, sum((Y(j,v) - mean(Y(j,v))).^2));
    end
end
net.r2 = r2;
if ~use_dl
    fprintf('     [WM] 未检测到dlgradient, 退化为随机特征岭回归集成(无物理一致性项)\n');
end
end

% ─────────────────────────────────────────────────────────────────────
function [L, g] = loss_fn(p, X, Y, Mk, W, o)
Yp = wm_fwd(p, X);
se = sum(Mk .* (Yp - Y).^2, 1);
L = sum(W .* se) / max(1, extractdata(sum(W .* sum(Mk,1))));
for kk = 1:numel(o.pidx)                                   % 物理一致性
    f = o.pidx(kk); if f == 0; continue; end
    Xp = X; Xp(f,:) = Xp(f,:) + o.delta;
    Yq = wm_fwd(p, Xp);
    L = L + o.pw * mean(max(Yq(kk,:) - Yp(kk,:), 0).^2);
end
if ~isempty(o.anc)                                         % 价值一致性(协态锚)
    a = o.anc; y0 = wm_fwd(p, a.xs);
    for m2 = 1:numel(a.fidx)
        x1 = a.xs; x1(a.fidx(m2)) = x1(a.fidx(m2)) + o.delta;
        s = (wm_fwd(p, x1) - y0) / o.delta;
        L = L + a.w * (s(a.out(m2)) - a.slope(m2)).^2;
    end
end
L = L + o.l2 * (sum(p.W1(:).^2) + sum(p.W2(:).^2) + sum(p.W3(:).^2));
g = dlgradient(L, p);
end

function p = init_params(d, H, k)
p.W1 = randn(H,d) * sqrt(1/d);  p.b1 = zeros(H,1);
p.W2 = randn(H,H) * sqrt(1/H);  p.b2 = zeros(H,1);
p.W3 = randn(k,H) * sqrt(1/H) * 0.1; p.b3 = zeros(k,1);
end

function mdl = fit_rff(Xs, Ys, mask, bw, F, seed)
rng(200 + seed, 'twister');
[d, ~] = size(Xs); k = size(Ys,1);
Wr = randn(F,d); br = 2*pi*rand(F,1);
Phi = [tanh(Wr*Xs + br); ones(1,size(Xs,2))];
B = zeros(k, F+1);
for j = 1:k
    ww = bw .* double(mask(j,:));
    A = (Phi .* ww) * Phi' + 1e-2*eye(F+1);
    B(j,:) = (A \ ((Phi .* ww) * Ys(j,:)'))';
end
mdl = struct('rff',true,'Wr',Wr,'br',br,'B',B);
end

function v = gv(s, f, dflt)
if isfield(s,f) && ~isempty(s.(f)); v = s.(f); else; v = dflt; end
end
