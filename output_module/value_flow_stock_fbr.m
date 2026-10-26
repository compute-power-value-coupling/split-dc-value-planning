function V = value_flow_stock_fbr(A, P, year_now, wm, quiet)
%% AFZ-VFS-FBR — 非对称分区价值流—存量双态前后递演(创新点二)
%
%  输入A来自compute_asset_attribution(预算平衡的资产级归因, 含Γ侧×类张量)
%  ── 四类输出(与论文符号对应) ─────────────────────────────────────────
%   F_{a,y}  价值流   = 归因收入 − 运维/电费/变动(不含资本年金), 万元/年
%   S_{a,y}  价值存量 = (1+r)·S_{a,y-1} + F_{a,y}           (前向递演)
%   R_{a→(f,k)}^{y→τ} 跨网跨期资产—服务响应(单位资产, 按在役vintage份额)
%   Λ_{a,y}  未来生命周期边际价值(协态): 后向递演
%            Λ_y = m_y + β·Λ_{y+1} − β^{L_a}·m_{y+L_a},  β=1/(1+r)
%            即寿命窗口内单位资产运营价值的折现和; 超出已实现年份的
%            m由世界模型预测(VLM-WM)补齐, 无预测时按末年平稳外推
%   ρ_{a,y} = Λ_{a,y}/c_a − 1  单位投资生命周期净价值(约化成本/价值学习力)
%  ── 数学身份声明 ─────────────────────────────────────────────────────
%   Λ是容量累积系统的协态变量(动态规划/Pontryagin伴随); ρ是资产约化成本。
%   R在"同年在役各vintage单位产出相同"假设下由Γ与容量计算(非逐元反事实重跑)
%
%  非对称(AFZ): 训练侧资产对推理侧价值的响应R^{T→I}与反向R^{I→T}由数据
%  产生而非预设; 输出非对称指数AI=ΣR^{T→I}/ΣR^{I→T}
if nargin < 4; wm = []; end
if nargin < 5; quiet = true; end
NY_real = min(year_now, size(A.REV,1));
NA = numel(A.assets);  r = A.r;  beta = 1/(1+r);
L = A.life(:)';  c = A.c_unit(:)';
K = A.K(1:NY_real,:);  F = A.REV(1:NY_real,:) - A.OPEX(1:NY_real,:);

% ── 前向: 价值流→价值存量, 投入存量, 回收比 ──────────────────────────
S = zeros(NY_real,NA); I = zeros(NY_real,NA);
Kprev = zeros(1,NA);
for y = 1:NY_real
    dK = max(0, K(y,:) - Kprev); Kprev = max(Kprev, K(y,:));
    if y == 1
        S(y,:) = F(y,:);  I(y,:) = dK .* c;
    else
        S(y,:) = (1+r)*S(y-1,:) + F(y,:);
        I(y,:) = (1+r)*I(y-1,:) + dK .* c;
    end
end
recov = S ./ max(I, 1);                      % 价值存量/投入存量(≥1即已回收)
recov(I < 1e4) = NaN;                        % 投入不足1亿(如未扩建的HVDC/路由)时比值无意义

% ── 单位运营价值 m_{a,y}(万元/单位/年) ────────────────────────────────
m = zeros(NY_real,NA);
for a = 1:NA
    idx = K(:,a) > 1e-6;
    m(idx,a) = F(idx,a) ./ K(idx,a);
end

% ── 后向: 协态Λ(寿命窗口递推) ─────────────────────────────────────────
Hx = NY_real + max(L) + 1;
mx = zeros(Hx, NA);
mx(1:NY_real,:) = m;
for a = 1:NA
    last = m(NY_real,a);
    for t = NY_real+1:Hx
        k_ = t - NY_real;
        if ~isempty(wm) && isfield(wm,'m_fore') && isfield(wm,'year') && ~isempty(wm.m_fore)
            k_ = t - wm.year;                       % 推演起点=预测所在年
        end
        if ~isempty(wm) && isfield(wm,'m_fore') && k_ >= 1 && size(wm.m_fore,1) >= k_ ...
                && size(wm.m_fore,2) == NA
            mx(t,a) = wm.m_fore(k_, a);             % 世界模型推演值
        else
            mx(t,a) = last;                        % 平稳外推(无推演时)
        end
    end
end
Lam = zeros(Hx+1, NA);
for a = 1:NA
    La = L(a);
    for t = Hx:-1:1
        tail = 0; if t+La <= Hx; tail = beta^La * mx(t+La,a); end
        Lam(t,a) = mx(t,a) + beta*Lam(t+1,a) - tail;
    end
end
Lam = Lam(1:NY_real,:);
rho = Lam ./ max(c,1e-9) - 1;                % 价值学习力(单位投资净生命周期价值)

% ── 跨网跨期响应 R 与非对称指数 ────────────────────────────────────────
R = zeros(NA, 2, 5, NY_real, NY_real);
for a = 1:NA
    for tau = 1:NY_real
        if K(tau,a) <= 1e-6; continue; end
        for y = 1:tau
            if tau - y >= L(a); continue; end      % 该vintage已退役
            R(a,:,:,y,tau) = reshape(A.GAM(tau,a,:,:), [1 2 5]) / K(tau,a);
        end
    end
end
T_assets = [1 3 4];  I_assets = [2 5];       % 训练侧(西)资产 / 推理侧(东)资产
G = A.GAM(1:NY_real,:,:,:);
gT = G(:,T_assets,2,:); gI = G(:,I_assets,1,:);
TtoI = sum(gT(:));  ItoT = sum(gI(:));
AI = TtoI / max(1e-6, abs(TtoI) + abs(ItoT));   % 训练侧→推理侧占跨侧价值份额(0~1)

% ── 节点级跨网响应(资产节点×服务节点): 西部节点i单位训练容量 → 东部节点j兑现价值 ──
NIw = P.N_west; NJe = P.N_east;
Rnode = zeros(NIw, NJe, NY_real, NY_real);
if isfield(A,'XV') && isfield(A,'WTn')
    for tau = 1:NY_real
        for i = 1:NIw
            if A.WTn(tau,i) <= 1e-6; continue; end
            v_ij = reshape(A.XV(tau,i,:), [1 NJe]) / A.WTn(tau,i);
            for y = 1:tau
                if tau - y >= L(1); continue; end
                Rnode(i,:,y,tau) = v_ij;
            end
        end
    end
end
PVnode = @(y0) reshape(sum(Rnode(:,:,y0,y0:NY_real) .* ...
    reshape(beta.^(0:NY_real-y0), [1 1 1 NY_real-y0+1]), 4), [NIw NJe]);

% ── 瓶颈迁移: 学习力最大资产的年际切换 ────────────────────────────────
[~, lead] = max(rho, [], 2);
V = struct('F',F,'S',S,'I',I,'recov',recov,'m',m,'Lambda',Lam,'rho',rho, ...
           'R',R,'AI',AI,'TtoI',TtoI,'ItoT',ItoT,'lead',lead,'assets',{A.assets}, ...
           'Rnode',Rnode);
if quiet; return; end

% ── 全量输出 ─────────────────────────────────────────────────────────
fprintf('\n╔════════ 价值流—存量双态前后递演(AFZ-VFS-FBR) ════════╗\n');
fprintf('%-12s %10s %10s %10s %10s\n','资产','Y末存量亿','回收比','Λ/c','学习力ρ');
for a = 1:NA
    fprintf('%-12s %10.1f %10.2f %10.2f %+10.2f\n', A.assets{a}, S(end,a)/1e4, ...
        recov(end,a), Lam(end,a)/max(c(a),1e-9), rho(end,a));
end
fprintf('跨侧价值: 训练侧→推理侧 %.0f亿, 推理侧→训练侧 %.0f亿, 单向份额%.1f%%\n', ...
    TtoI/1e4, ItoT/1e4, 100*AI);
if abs(ItoT) < 1e-6
    fprintf('  注: 模型未设推理→训练价值通道(如再训练数据回流), 单向性为结构性结果\n');
end
sw = find(diff(lead) ~= 0);
if isempty(sw)
    fprintf('瓶颈迁移: 学习力主导资产全程为 %s\n', A.assets{lead(1)});
else
    for s = sw(:)'
        fprintf('瓶颈迁移: Y%d→Y%d 主导资产 %s → %s\n', s, s+1, A.assets{lead(s)}, A.assets{lead(s+1)});
    end
end
wn = {'NM','GS','NX','GZ'}; en = {'BJ','SH','GZh'};
pv1 = PVnode(1);
fprintf('节点级跨网响应(Y1投运1MW训练容量, 生命周期折现, 万元):\n        %s\n', ...
    strjoin(cellfun(@(s) sprintf('%8s',s), en(1:NJe), 'Uni',0), ''));
for i = 1:NIw
    fprintf('  %-4s %s\n', wn{min(i,4)}, sprintf('%8.1f', pv1(i,:)));
end
fprintf('╚══════════════════════════════════════════════════════╝\n');

outd = 'simulation_output'; if isfield(P,'out_dir'); outd = P.out_dir; end
if ~exist(outd,'dir'); mkdir(outd); end
fid = fopen(fullfile(outd,'value_state_fbr.csv'),'w');
fprintf(fid,'年份,资产,价值流F_亿,价值存量S_亿,回收比,单位运营价值m_万元,协态Lambda_万元,学习力rho\n');
for y = 1:NY_real
    for a = 1:NA
        fprintf(fid,'Y%d,%s,%.2f,%.2f,%.3f,%.3f,%.3f,%.4f\n', y, A.assets{a}, ...
            F(y,a)/1e4, S(y,a)/1e4, recov(y,a), m(y,a), Lam(y,a), rho(y,a));
    end
end
fclose(fid);
% Y1投运单位资产的生命周期响应(按功能侧×SLA类, 折现和)
fid = fopen(fullfile(outd,'value_response_R.csv'),'w');
cls = {'A','B','C','D','柔性'}; side = {'训练侧T','推理侧I'};
fprintf(fid,'资产,功能侧,SLA类,Y1单位资产生命周期响应_万元\n');
for a = 1:NA
    for f = 1:2
        for kq = 1:5
            v = 0;
            for tau = 1:NY_real; v = v + beta^(tau-1) * R(a,f,kq,1,tau); end
            if abs(v) > 1e-9
                fprintf(fid,'%s,%s,%s,%.4f\n', A.assets{a}, side{f}, cls{kq}, v);
            end
        end
    end
end
fclose(fid);
% 节点级响应(两个投运年份对比, 显示跨期变化)
fid = fopen(fullfile(outd,'value_response_node.csv'),'w');
fprintf(fid,'投运年,西部节点,东部节点,单位训练容量生命周期跨网价值_万元每MW\n');
for y0 = unique([1, max(1, ceil(NY_real/2))])
    pv = PVnode(y0);
    for i = 1:NIw
        for j = 1:NJe
            fprintf(fid,'Y%d,%s,%s,%.3f\n', y0, wn{min(i,4)}, en{min(j,3)}, pv(i,j));
        end
    end
end
fclose(fid);

% 图16: 价值学习力(约化成本)年际曲线——交叉即瓶颈迁移
try
    fg = figure('Visible','off','Color','w','Position',[80 80 900 480]);
    hold on; cols = lines(NA);
    eng = {'W_T train','W_I infer','Green gen','Storage W','Storage E','HVDC','Comm route'};
    for a = 1:NA
        if all(K(:,a) <= 1e-6); continue; end
        plot(1:NY_real, rho(:,a), '-o', 'LineWidth', 1.6, 'Color', cols(a,:), ...
            'MarkerSize', 4, 'DisplayName', eng{min(a,numel(eng))});
    end
    yline(0,'k--','HandleVisibility','off');
    xlabel('Planning year'); ylabel('\rho_{a,y} = \Lambda_{a,y}/c_a - 1');
    title('Value learning force (reduced cost) by asset'); grid on;
    legend('Location','eastoutside','Interpreter','none');
    try; set(findall(fg,'Type','axes'),'Toolbar',[]); catch; end
    exportgraphics(fg, fullfile(outd,'fig16_value_learning_force.png'), 'Resolution', 300);
    close(fg);
catch
end
fprintf('[FBR] 已输出 value_state_fbr.csv / value_response_R.csv / fig16\n');
end
