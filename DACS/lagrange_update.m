%% =========================================================================
%  lagrange_update.m  —  Lagrangian乘子次梯度更新(Polyak自适应步长)
%  对应论文式(32-33)
%
%  Polyak步长: α_k = 0.7×(UB-LB) / max(||g||², 1e-6)
%  优势: 自适应收紧(间距缩小时步长自动减小), 无需手动设α_0
%% =========================================================================
function mu_new = lagrange_update(mu, solW, x_sol, scen_s, r_viol, lr_k, P, UB, LB)
if nargin < 8 || isempty(UB); UB = 0;    end
if nargin < 9 || isempty(LB); LB = -1e6; end

NI = P.N_west;
T  = P.T;

% 次梯度（NI×T矩阵）
g_train = solW.P_train - repmat(x_sol.W_T(:), 1, T);   % x_sol.W_T强制列向量
g_renew = solW.P_renew - repmat(x_sol.G(:),   1, T) .* squeeze(scen_s.CF_renew);
g_stor  = solW.E_soc(:, 1:T) - repmat(x_sol.E_w(:), 1, T);

% Polyak步长：强制所有中间量为标量，防止UB/LB是向量时传播为向量
gap_val  = max(abs(UB(1) - LB(1)), 1e-3);          % UB(1)/LB(1)取第一元素
g_norm2  = sum(g_train(:).^2) + sum(g_renew(:).^2) + sum(g_stor(:).^2);  % 等价Frobenius^2且确保标量
% 原来只有P.alpha0_LR=0.5上界，当gap_val=100亿、g_norm2=1e-6时alpha_k=7e16
alpha_k  = 0.7 * gap_val / max(g_norm2, 1e-6);
alpha_k  = max(1e-5, min(alpha_k, P.alpha0_LR(1)));       % 上界1: 绝对上限
alpha_k  = min(alpha_k, 1.0 / max(sqrt(g_norm2), 1.0));   % 上界2: 相对步长（次梯度标准化）

% 乘子更新：用.*（按元素），彻底避免矩阵乘法歧义
mu_new = mu;
mu_new.train = max(0, min(P.mu_train_max, mu.train + alpha_k .* g_train));
mu_new.renew = max(0, min(P.mu_renew_max, mu.renew + alpha_k .* g_renew));
mu_new.stor  = max(0, min(P.mu_stor_max,  mu.stor  + alpha_k .* g_stor));
end
