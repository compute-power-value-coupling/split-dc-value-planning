function A = compute_asset_attribution(results_yearly, P, quiet)
if nargin < 3; quiet = false; end
%% 资产级价值归因与回收闭合审计引擎(创新点二的实证载体)
%
%  核心命题: 系统NPV>0 ⇏ 每项必要资产NPV_a>0("系统最优但投资链不可实现")
%  价值链: V^SKU → V^real → Γ_a(运行贡献归因) → (NPV_a, T_a^payback) → 闭合审计
%
%  归因原则(预算平衡·边际租金+残差混合):
%   · 绿电/储能: 供电市场机会租金(市场价值−实付电费) + 迁移弃电吸收租金
%   · 通信网络: 迁移过路费(内部转移, 系统级净零, 资产级显性化)
%   · HVDC:    迁移带宽租金(利用率×迁移剩余盈余)
%   · 训练算力: 西部服务收入−电力租金 + 迁移承接残余(容量稀缺租)
%   · 推理算力: 东部服务+柔性+VPP收入−东储能套利
%   · 东储能:  峰谷价差套利(放电市值−充电成本)
%  成本侧: 分资产年金化capex(逐vintage CRF) + 分项O&M/GPU折旧/电费/变动
%
%  输出: output/asset_recovery.csv + 控制台闭合审计 + 返回结构A

NY = numel(results_yearly);
r = 0.08;                                   % 折现率
if isfield(P, 'r_min') && ~isempty(P.r_min); r = P.r_min; end   % 与主问题/现金流口径一致(默认0.08, 结果不变)
life = struct('WT',15,'WI',15,'G',20,'Ew',10,'Ee',10,'HVDC',25);
crf = @(n) r*(1+r)^n/((1+r)^n-1);
assets = {'W_T训练算力','W_I推理算力','G绿电','E_w西储能','E_e东储能','HVDC','COMM通信'};
NA = numel(assets);
CF = zeros(NY, NA);  REV = zeros(NY, NA);  CST = zeros(NY, NA);
CAPX = zeros(NY, NA);                       % 各年新增投资(现金流口径)
GAM = zeros(NY, NA, 2, 5);                  % Γ: 资产×功能侧(1训练T/2推理I)×SLA类(A,B,C,D,柔性)
Kc  = zeros(NY, NA);                        % 在役容量(MW/MWh/MW/对)
XV  = zeros(NY, P.N_west, P.N_east);        % 节点级跨网价值: 西部节点i支撑、东部节点j兑现(万元)
WTn = zeros(NY, P.N_west);                  % 西部各节点训练容量(MW)
ann = zeros(NY, NA);                        % 各年在役年金(逐vintage累积)

prev = struct('WT',0,'WI',0,'G',0,'Ew',0,'Ee',0,'HVDC',0);
prevRT = [];
renew_unit = 0.5*(P.C_renew_wind + P.C_renew_pv)*1000;   % 万元/MW

for y = 1:NY
    R = results_yearly{y};
    if isempty(R); continue; end
    act = []; st = [];
    if isfield(R,'actual'); act = R.actual; end
    if isfield(R,'state');  st  = R.state;  end
    if isempty(act) || isempty(st); continue; end
    gv = @(s,f,d) (isfield(s,f))*0 + d;  %#ok<NASGU>

    % ── 容量与增量 ─────────────────────────────────────────────────────
    WT = sum(st.W_T_cum); WI = sum(st.W_I_cum); G = sum(st.G_cum);
    Ew = sum(st.E_w_cum); Ee = sum(st.E_e_cum);
    HV = 0; if isfield(st,'dL_cum'); HV = sum(st.dL_cum(:)); end
    d = struct('WT',max(0,WT-prev.WT),'WI',max(0,WI-prev.WI),'G',max(0,G-prev.G), ...
               'Ew',max(0,Ew-prev.Ew),'Ee',max(0,Ee-prev.Ee),'HVDC',max(0,HV-prev.HVDC));
    % HVDC本年投资额(用单价矩阵×增量, 聚合近似: 平均单价)
    hv_unit = mean(P.C_trans_per_node(:));
    comm_capex = 0;
    if isfield(st,'rt_cum') && isfield(P,'C_route_per_pair')
        if isempty(prevRT); prevRT = zeros(size(st.rt_cum)); end
        comm_capex = sum(sum(P.C_route_per_pair .* max(0, st.rt_cum - prevRT)));
        prevRT = st.rt_cum;
    end
    capex = [d.WT*P.C_train_fix, d.WI*P.C_infer_fix*max(0.65, 1-0.05*min(y-1,8)), d.G*renew_unit, ...
             d.Ew*P.C_stor*1000, d.Ee*P.C_stor*1000, d.HVDC*hv_unit, comm_capex];
    lifes = [life.WT life.WI life.G life.Ew life.Ee life.HVDC 20];
    CAPX(y,:) = capex;
    for a = 1:NA
        if a == 1                                   % 训练: 非GPU 15年 + GPU按寿命周期重置
            rG = P.C_gpu_ratio; cr = (1-rG)*crf(lifes(1)) + rG*crf(P.T_gpu_life);
            ann(y:NY, a) = ann(y:NY, a) + capex(a)*cr;
        else
            ann(y:NY, a) = ann(y:NY, a) + capex(a)*crf(lifes(a));  % vintage年金入役
        end
    end
    prev = struct('WT',WT,'WI',WI,'G',G,'Ew',Ew,'Ee',Ee,'HVDC',HV);

    % ── 运行信号 ───────────────────────────────────────────────────────
    rp = act.rev_parts;  cp = act.cost_parts;
    pw_only = isfield(P,'value_model') && strcmpi(P.value_model,'power_only');
    if pw_only
        % 对比组B-I: 现有研究的电力收益口径——不计算力服务收入(训练/推理/迁移/跨域), 只保留电力侧收益;
        % 绿电价值按"替代购电"计(绿电利用量×西部电价)
        rp.west = 0; rp.east = 0; rp.migration = 0; if isfield(rp,'b_offload'); rp.b_offload = 0; end
    end
    NI = P.N_west; 
    pr_w = act.price(:,1:NI);  pr_e = act.price(:,NI+1:end);
    mkt_val_T = sum(sum(pr_w .* act.P_train))/1e4;            % 训练用能市场价值
    % 储能充放(列宽自适应: 合并矩阵或分列)
    [chW,chE,diW,diE] = deal(0);
    if isfield(act,'P_ch') && size(act.P_ch,2) >= NI
        chW = sum(sum(pr_w .* act.P_ch(:,1:NI)))/1e4;
        diW = sum(sum(act.P_dis(:,1:NI)));
        if size(act.P_ch,2) >= NI+1           % 东储能若有逐时调度记录
            chE = sum(sum(pr_e .* act.P_ch(:,NI+1:end)))/1e4;
            diE = sum(sum(pr_e .* act.P_dis(:,NI+1:end)))/1e4;
        end
    end
    tokW = sum(act.T_gen(:));
    tokE = sum(act.S_B(:)) + sum(act.S_C(:));
    if isfield(act,'tok_A'); tokE = tokE + act.tok_A; end   % A类刚性推理token
    tok_share_W = tokW/max(1,tokW+tokE);

    % ── 收入归因 Γ_a ───────────────────────────────────────────────────
    % 电力租金(训练): 用能市值−实付 → 绿电/西储能(按放电能量占比)
    rent_T = max(0, mkt_val_T - cp.west);
    sh_Ew = min(0.4, diW / max(1, sum(act.P_train(:))));
    % 迁移三方分解: 通信过路费 | 绿电吸收租金 | HVDC带宽租金 | 训练承接残余
    mig_comm = 0; if isfield(cp,'mig_comm'); mig_comm = cp.mig_comm; end
    absorb_MWh = 0;
    if isfield(act,'P_mig_run')
        gridE = 0; if isfield(cp,'mig_energy'); gridE = cp.mig_energy; end
        pbar = max(50, mean(pr_w(:)));
        absorb_MWh = max(0, sum(act.P_mig_run(:)) - gridE*1e4/pbar);
    end
    rent_G_mig = absorb_MWh * mean(pr_w(:)) / 1e4 * 0.3;      % 弃电时段折价市值
    u_hv = 0; if HV>0 && isfield(act,'P_mig_run')
        u_hv = min(1, sum(act.P_mig_run(:))/(HV*8760)); end
    mig_pool = max(0, rp.migration - rent_G_mig);
    rent_HV = 0; if isfield(rp,'hvdc'); rent_HV = rp.hvdc; end   % 实际HVDC外送价值(任务走光纤, 不从迁移分成)
    mig_resid = mig_pool;
    % 东储能峰谷套利
    arb_Ee = max(0, diE - chE);
    % 创新一B类跨域服务: 推理侧(I)B类价值由训练侧资产(W_T/G/COMM)共创 → T→I非对称
    rev_boff = 0; boff_E = 0; boff_C = 0; rent_G_B = 0;
    if isfield(rp,'b_offload'); rev_boff = rp.b_offload; end
    if isfield(cp,'boff_energy'); boff_E = cp.boff_energy; boff_C = cp.boff_comm; end
    if isfield(act,'P_Boff') && rev_boff > 0
        pbarB = max(50, mean(pr_w(:)));
        absorb_B = max(0, sum(act.P_Boff(:)) - boff_E*1e4/pbarB);
        rent_G_B = min(0.5*rev_boff, absorb_B * mean(pr_w(:)) / 1e4 * 0.3);
    end
    rEc = [0 0 0]; if isfield(act,'rev_east_cls'); rEc = act.rev_east_cls; end
    Kc(y,:) = [WT, WI, G, Ew, Ee, HV, 0];
    WTn(y,:) = st.W_T_cum(:)';
    xv = zeros(P.N_west, P.N_east);
    if isfield(act,'migration_OD') && sum(act.migration_OD(:)) > 0
        xv = xv + rp.migration * (act.migration_OD' / sum(act.migration_OD(:)));
    end
    if isfield(act,'Boff_OD') && sum(act.Boff_OD(:)) > 0
        xv = xv + rev_boff * (act.Boff_OD' / sum(act.Boff_OD(:)));
    end
    XV(y,:,:) = reshape(xv, [1 P.N_west P.N_east]);
    if isfield(st,'rt_cum'); Kc(y,7) = sum(st.rt_cum(:)); end
    % Γ(侧×类)分解(与下方REV逐项一致, 预算平衡)
    GAM(y,1,1,4) = rp.west - rent_T;  GAM(y,1,2,3) = mig_resid;  GAM(y,1,2,2) = rev_boff - rent_G_B;
    GAM(y,2,2,1) = rEc(1); GAM(y,2,2,2) = rEc(2); GAM(y,2,2,3) = rEc(3);
    GAM(y,2,2,5) = (rp.east - sum(rEc)) + rp.flex + rp.vpp - arb_Ee;
    GAM(y,3,1,4) = rent_T*(1-sh_Ew); GAM(y,3,2,3) = rent_G_mig; GAM(y,3,2,2) = rent_G_B;
    GAM(y,4,1,4) = rent_T*sh_Ew;     GAM(y,5,2,5) = arb_Ee;     GAM(y,6,2,5) = rent_HV;
    GAM(y,7,2,3) = mig_comm;         GAM(y,7,2,2) = boff_C;
    REV(y,:) = [ rp.west - rent_T + mig_resid + rev_boff - rent_G_B, ... % W_T
                 rp.east + rp.flex + rp.vpp - arb_Ee, ...       % W_I
                 rent_T*(1-sh_Ew) + rent_G_mig + rent_G_B, ...  % G
                 rent_T*sh_Ew, ...                              % E_w
                 arb_Ee, ...                                    % E_e
                 rent_HV, ...                                   % HVDC
                 mig_comm + boff_C ];
    if pw_only && isfield(act,'P_renew') && isfield(act,'price')
        REV(y,3) = REV(y,3) + sum(sum(act.P_renew .* act.price(:,1:size(act.P_renew,2)))) / 1e4;   % 绿电替代购电价值
    end                           % COMM(过路费收入)

    % ── 成本归因 ───────────────────────────────────────────────────────
    om = [60*WT, 48*WI, 8.5*G, 1.2*Ew, 1.2*Ee, 0.5*HV*0.01, 0];
    if isfield(cp,'om') && sum(om) > 0                       % 按实际付现运维(剔除折旧)校准总量
        om_cash = cp.om; if isfield(act,'cost_depr'); om_cash = cp.om - act.cost_depr; end
        om = om * max(0, om_cash) / sum(om);
    end
    elec = [cp.west - chW + (isfield(cp,'mig_energy'))*cp.mig_energy, ...
            cp.east - chE, 0, chW, chE, 0, 0];
    varc = [cp.variable*tok_share_W, cp.variable*(1-tok_share_W), 0,0,0,0,0];
    stor = [0,0,0, cp.stor*0.5, cp.stor*0.5, 0,0];
    toll = [mig_comm + boff_C + boff_E, 0,0,0,0,0, 0];          % W_T支付过路费+B跨域购电
    CST(y,:) = ann(y,:) + om + elec + varc + stor + toll;
    CF(y,:) = REV(y,:) - CST(y,:);
end

% ── NPV/回收/闭合审计 ─────────────────────────────────────────────────
disc = (1+r).^-(1:NY)';
% ── 现金流口径(与summary一致): 运营净值 − 新增投资 − 周期重置(GPU/储能) + 期末直线残值 ──
LF = [life.WT life.WI life.G life.Ew life.Ee life.HVDC 20]; rG = P.C_gpu_ratio; TG = P.T_gpu_life;
CFc = (REV - (CST - ann)) - CAPX; salv = zeros(1,NA);
for v = 1:NY
    gpu = CAPX(v,1)*rG; t = v + TG; while t <= NY; CFc(t,1) = CFc(t,1) - gpu; t = t + TG; end
    for a = [4 5]; t = v + LF(a); while t <= NY; CFc(t,a) = CFc(t,a) - CAPX(v,a); t = t + LF(a); end; end
    for a = 1:NA
        age = NY - v + 1; La = LF(a); base = CAPX(v,a);
        if a == 1
            salv(a) = salv(a) + base*(1-rG)*max(0, 1 - age/La) + base*rG*max(0, 1 - (mod(NY-v,TG)+1)/TG);
        elseif any(a == [4 5])
            salv(a) = salv(a) + base*max(0, 1 - (mod(NY-v,La)+1)/La);
        else
            salv(a) = salv(a) + base*max(0, 1 - age/La);
        end
    end
end
CFc(NY,:) = CFc(NY,:) + salv;
NPVc = sum(CFc .* disc, 1) / 1e4;
NPVa_ann = sum(CF .* disc, 1) / 1e4;                            % 年金口径(保留)
NPVa = NPVc;                                                    % 审计采用现金流口径(与summary一致)
payb = nan(1,NA);
for a=1:NA
    cs = cumsum(CFc(:,a));
    k = find(cs>0, 1); if ~isempty(k); payb(a)=k; end
end
if ~quiet
fprintf('\n╔═══════════ 资产级回收闭合审计(创新点二) ═══════════╗\n');
fprintf('%-14s %10s %8s %s\n','资产','NPV_a(亿)','回收年','闭合状态');
gap_total = 0;
for a=1:NA
    st_ = 'OK闭合'; if NPVa(a)<0; st_=sprintf('X缺口%.0f亿',-NPVa(a)); gap_total=gap_total-NPVa(a); end
    pb='—'; if ~isnan(payb(a)); pb=sprintf('Y%d',payb(a)); end
    fprintf('%-14s %10.1f %8s %s\n', assets{a}, NPVa(a), pb, st_);
end
fprintf('系统级NPV=%.1f亿 | 资产缺口合计=%.1f亿 → %s\n', ...
    sum(NPVa), gap_total, ternary(gap_total>1,'!链条未闭合: 需转移定价/容量补偿','OK投资链闭合'));
fprintf('╚═══════════════════════════════════════════════════╝\n');
end

c_unit = [P.C_train_fix, P.C_infer_fix, renew_unit, P.C_stor*1000, P.C_stor*1000, ...
          mean(P.C_trans_per_node(:)), 50000];
if isfield(P,'C_route_per_pair'); c_unit(7) = mean(P.C_route_per_pair(:)); end
A = struct('CF',CF,'REV',REV,'CST',CST,'NPV_a',NPVa,'payback',payb,'assets',{assets}, ...
           'GAM',GAM,'K',Kc,'OPEX',CST-ann,'ANN',ann,'c_unit',c_unit, ...
           'life',[life.WT life.WI life.G life.Ew life.Ee life.HVDC 20],'r',r, ...
           'XV',XV,'WTn',WTn);
if quiet; return; end
% ── CSV导出 ────────────────────────────────────────────────────────────
outd = 'simulation_output'; if isfield(P,'out_dir'); outd = P.out_dir; end
if ~exist(outd,'dir'); mkdir(outd); end
fid = fopen(fullfile(outd,'asset_recovery.csv'),'w');
fprintf(fid,'年份,%s\n', strjoin(assets,','));
for y=1:NY
    fprintf(fid,'Y%d,%s\n', y, strjoin(arrayfun(@(v)sprintf('%.1f',v/1e4),CF(y,:),'Uni',0),','));
end
fprintf(fid,'NPV_亿,%s\n', strjoin(arrayfun(@(v)sprintf('%.1f',v),NPVa,'Uni',0),','));
fprintf(fid,'回收年,%s\n', strjoin(arrayfun(@(v)ternary(isnan(v),'NaN',sprintf('%d',v)),payb,'Uni',0),','));
fclose(fid);
c_unit = [P.C_train_fix, P.C_infer_fix, renew_unit, P.C_stor*1000, P.C_stor*1000, ...
          mean(P.C_trans_per_node(:)), 50000];
if isfield(P,'C_route_per_pair'); c_unit(7) = mean(P.C_route_per_pair(:)); end
A = struct('CF',CF,'REV',REV,'CST',CST,'NPV_a',NPVa,'payback',payb,'assets',{assets}, ...
           'GAM',GAM,'K',Kc,'OPEX',CST-ann,'ANN',ann,'c_unit',c_unit, ...
           'life',[life.WT life.WI life.G life.Ew life.Ee life.HVDC 20],'r',r, ...
           'XV',XV,'WTn',WTn);
end

function s = ternary(c,a,b); if c; s=a; else; s=b; end; end
