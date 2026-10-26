%% write_summary_csv.m — 15年逐年关键指标汇总（完全修复版）
% 修复点：
%   1. 绿电利用率NaN → 从消纳率计算
%   2. 投资回收年份NaN → 从累计NCF计算
%   4. HVDC"利用率"单位错误 → 改为真实利用率(0~1)
%   5. 碳减排NaN → 从绿电发电量估算
%   6. 主/子问题状态NaN → 从ben_info读取
%   7. 推理投资漏计 → 用state前后差值算W_I增量成本
%   8. ROI加NPV折现值
%   9. B违约率正确输出
function write_summary_csv(results_yearly, P)

NY = P.N_year;
NI = P.N_west;
NJ = P.N_east;
WACC = isfield(P,'r_min')*P.r_min + ~isfield(P,'r_min')*0.08;

% ── 碳排放因子 ─────────────────────────────────────────────────────────────
% 中国电网平均碳排放强度约0.581 kgCO2/kWh = 581 tCO2/GWh (2023年)
CO2_factor = 0.581;   % tCO2/MWh

% ── 逐年提取数据 ─────────────────────────────────────────────────────────
% 基础容量
W_T_tot = nan(NY,1); W_I_tot=nan(NY,1); G_tot=nan(NY,1);
Ew_tot=nan(NY,1);   Ee_tot=nan(NY,1);
% 按西部节点分列容量
W_T_node = nan(NY,NI); G_node=nan(NY,NI); Ew_node=nan(NY,NI);
z_node   = zeros(NY,NI);
% HVDC（NI×NJ，分通道输出）
dL_cum_mat = nan(NY,NI,NJ);
% 财务
rev=nan(NY,1);  op_cost=nan(NY,1); inv_incr=nan(NY,1);
ncf=nan(NY,1);  cum_ncf=nan(NY,1); roi=nan(NY,1);
depr_y = zeros(NY,1); vint_cap = zeros(NY,7);   % 现金流口径: 折旧与各类资产投运批次
npv_inc=nan(NY,1);
% 运营
mode_curt=nan(NY,1); mode_grid=nan(NY,1); mode_load=nan(NY,1);
b_viol=nan(NY,1);    migration=nan(NY,1); comm_delay=nan(NY,1);
green_util=nan(NY,1);carbon_save=nan(NY,1);
% 算法
n_iter=nan(NY,1); gap=nan(NY,1); n_cuts=nan(NY,1);
eps1=nan(NY,1);   master_ok=nan(NY,1); sub_ok=nan(NY,1);

prev_state.W_T_cum = zeros(NI,1);
prev_state.W_I_cum = zeros(NJ,1);
prev_state.G_cum   = zeros(NI,1);
prev_state.E_w_cum = zeros(NI,1);
prev_state.E_e_cum = zeros(NJ,1);
prev_state.dL_cum  = zeros(NI,NJ);
C_infer_base = P.C_infer_fix;

for y = 1:NY
    R = results_yearly{y};
    if isempty(R); continue; end
    st  = R.state;
    act = R.actual;
    bi  = R.ben_info;
    af  = R.AEMF;

    % ── 容量 ──────────────────────────────────────────────────────
    W_T_tot(y) = sum(st.W_T_cum);
    W_I_tot(y) = sum(st.W_I_cum);
    G_tot(y)   = sum(st.G_cum);
    Ew_tot(y)  = sum(st.E_w_cum);
    Ee_tot(y)  = sum(st.E_e_cum);
    W_T_node(y,:) = st.W_T_cum(:)';
    G_node(y,:)   = st.G_cum(:)';
    Ew_node(y,:)  = st.E_w_cum(:)';
    z_node(y,:)   = st.z_cum(:)';
    % HVDC累计容量（NI×NJ → 存3D数组）
    dL_mat = st.dL_cum;
    if isequal(size(dL_mat),[NI,NJ])
        dL_cum_mat(y,:,:) = dL_mat;
    end

    % ── 财务（修复推理投资漏计）──────────────────────────────────
    % 本年新增投资 = 训练/绿电/储能/推理/HVDC各项增量成本之和
    C_infer_eff = C_infer_base * max(0.65, 1-0.05*min(y-1,8));
    dWT  = max(0, st.W_T_cum - prev_state.W_T_cum);
    dG   = max(0, st.G_cum   - prev_state.G_cum);
    dEw  = max(0, st.E_w_cum - prev_state.E_w_cum);
    dWI  = max(0, st.W_I_cum - prev_state.W_I_cum);
    dEe  = max(0, st.E_e_cum - prev_state.E_e_cum);
    dL_inc = max(0, st.dL_cum - prev_state.dL_cum);
    if ~isequal(size(dL_inc),[NI,NJ]); dL_inc=zeros(NI,NJ); end
    inv_y = P.C_train_fix*sum(dWT) ...
          + (P.C_renew_wind+P.C_renew_pv)*1000*sum(dG)*0.5 ...
          + P.C_stor*1000*sum(dEw) ...
          + C_infer_eff*sum(dWI) ...
          + P.C_stor*1000*sum(dEe) ...
          + sum(sum(P.C_trans_per_node.*dL_inc));
    % 通信直连路由投资(原未计入投资)
    if isfield(st,'rt_cum') && isfield(P,'C_route_per_pair')
        rt_prev = zeros(size(st.rt_cum)); if isfield(prev_state,'rt_cum'); rt_prev = prev_state.rt_cum; end
        inv_rt = sum(sum(P.C_route_per_pair .* max(0, st.rt_cum - rt_prev)));
    else
        inv_rt = 0;
    end
    inv_y = inv_y + inv_rt;
    % 电网加强投资: 规划中按年金罚计入的线路越限, 财务上计为加强投资(=罚/CRF(30年))
    inv_re = 0;
    if isfield(st,'net_reinf_cum')
        re_prev = 0; if isfield(prev_state,'net_reinf_cum'); re_prev = prev_state.net_reinf_cum; end
        np_ = 30; if isfield(P,'net_pen'); np_ = P.net_pen; end
        crf30 = 0.08*1.08^30/(1.08^30-1);
        inv_re = max(0, st.net_reinf_cum - re_prev) * np_ / crf30;
    end
    inv_y = inv_y + inv_re;
    inv_incr(y) = inv_y / 1e4;   % 亿元
    vint_cap(y,:) = [P.C_train_fix*sum(dWT)*(1-P.C_gpu_ratio), P.C_train_fix*sum(dWT)*P.C_gpu_ratio, ...
                     C_infer_eff*sum(dWI), (P.C_renew_wind+P.C_renew_pv)*1000*sum(dG)*0.5, ...
                     P.C_stor*1000*(sum(dEw)+sum(dEe)), sum(sum(P.C_trans_per_node.*dL_inc)) + inv_re, inv_rt];
    if isfield(act,'cost_depr'); depr_y(y) = act.cost_depr / 1e4; end

    % 运营净收益（万元→亿元）
    net_yr = act.net_profit(1) / 1e4;
    rev(y)  = isfield(act,'revenue_total')*act.revenue_total(1)/1e4 + ~isfield(act,'revenue_total')*NaN;
    op_cost(y) = isfield(act,'cost_total')*act.cost_total(1)/1e4 + ~isfield(act,'cost_total')*NaN;
    ncf(y)  = net_yr - inv_incr(y);

    % ROI（年度净收益/累计总投资）和NPV增量（含折现）
    F1_cum_y = P.C_train_fix*sum(st.W_T_cum) ...
             + (P.C_renew_wind+P.C_renew_pv)*1000*sum(st.G_cum)*0.5 ...
             + P.C_stor*1000*(sum(st.E_w_cum)+sum(st.E_e_cum)) ...
             + C_infer_base*sum(st.W_I_cum) ...
             + sum(sum(P.C_trans_per_node.*st.dL_cum));
    roi(y)     = F1_cum_y>0 && net_yr/F1_cum_y*1e4 || 0;
    roi(y)     = net_yr / (F1_cum_y/1e4 + eps);   % 净收益/累计投资（亿元÷亿元）
    npv_inc(y) = ncf(y) / (1+WACC)^y;             % 折现净现金流

    % ── 运营指标 ──────────────────────────────────────────────────
    mode_curt(y) = act.mode_freq(1);
    mode_grid(y) = act.mode_freq(2);
    mode_load(y) = act.mode_freq(3);
    b_viol(y) = isfield(act,'sla_B_viol_rate') * act.sla_B_viol_rate;
    comm_delay(y) = isfield(act,'avg_comm_delay') * act.avg_comm_delay;

    if isfield(act,'P_curt') && isfield(act,'cf_wind') && isfield(act,'cf_pv') && ~isempty(act.P_curt)
        % 修正: 原用"训练直接消纳/可发绿电"(未计C迁移、B跨域、储能、HVDC外送的吸纳), 报告的弃电率被高估约50个百分点
        av_ = 0; for i_ = 1:min(NI, size(act.cf_wind,2)); av_ = av_ + sum(st.G_cum(i_) * (act.cf_wind(:,i_) + act.cf_pv(:,i_)) / 2); end
        green_util(y) = max(0, min(1, 1 - sum(act.P_curt(:)) / max(1, av_)));
    elseif isfield(act,'curtail_rate') && ~isnan(act.curtail_rate)
        green_util(y) = act.curtail_rate;
    else
        green_util(y) = 1 - mode_curt(y) * 0.005;  % 弃电模式35%≈0.5%实际弃电
    end

    if isfield(act,'revenue_total') && ~isempty(act.revenue_total)
        rev(y) = act.revenue_total(1) / 1e4;
    end
    if isfield(act,'cost_total') && ~isempty(act.cost_total)
        op_cost(y) = act.cost_total(1) / 1e4;
    end

    % C类迁移率 = 实际迁移量 / C类总需求量(真实口径)
    % 迁移率 = 迁移消化的C类任务 / C类年度到达总量, 反映空间柔性利用程度
    if isfield(act,'total_migration') && act.total_migration > 0
        % 迁移率 = 迁移量/(迁移量+东部本地服务C量), 天然≤1且随年变化
        localC = 0;
        if isfield(act,'S_C'); localC = sum(act.S_C(:)); end
        migration(y) = act.total_migration / max(1, act.total_migration + localC);
    else
        migration(y) = 0;
    end

    % 碳减排量 = 绿电发电量 × 碳排放因子
    CF_avg_west = mean((P.CF_wind_west+P.CF_pv_west)/2);
    green_gen_annual = G_tot(y) * CF_avg_west * 8736;
    carbon_save(y) = green_gen_annual * CO2_factor / 1e6;
    CF_avg_west = mean((P.CF_wind_west+P.CF_pv_west)/2);
    green_gen_annual = sum(G_tot(y)) * CF_avg_west * 8736;  % MWh/年
    carbon_save(y) = green_gen_annual * CO2_factor / 1e6;   % 百万tCO2

    % ── 算法指标 ──────────────────────────────────────────────────
    n_iter(y) = bi.n_iter;
    gap(y)    = bi.final_gap;
    if isfield(bi,'n_cuts'); n_cuts(y) = bi.n_cuts; else; n_cuts(y) = NaN; end
    eps1(y)   = af.epsilon_1;
    master_ok(y) = isfield(bi,'master_status') * bi.master_status;
    sub_ok(y)    = isfield(bi,'sub_status') * bi.sub_status;

    prev_state = st;
end

% ── 现金流口径修正 ───────────────────────────────────────────────────
% 原: 净现金流 = (收入 − 含折旧的成本) − 投资 → 资本被计两次(GPU折旧262.5万/MW/年、储能折旧)
% 今: 净现金流 = 收入 − 付现成本 − 新增投资 − 周期重置投资(GPU每T_gpu年、储能每T_stor年) + 期末残值
life_v = [15, P.T_gpu_life, 15, 20, P.T_stor_life, 25, 20];
refresh = zeros(NY,1); salvage = 0;
for v = 1:NY
    for kk = [2 5]
        t = v + life_v(kk);
        while t <= NY; refresh(t) = refresh(t) + vint_cap(v,kk)/1e4; t = t + life_v(kk); end
    end
    for kk = 1:7
        age = NY - v + 1;
        if any(kk == [2 5]); age = mod(NY - v, life_v(kk)) + 1; end
        salvage = salvage + vint_cap(v,kk)/1e4 * max(0, 1 - age/life_v(kk));
    end
end
for y = 1:NY
    ncf(y) = rev(y) - (op_cost(y) - depr_y(y)) - inv_incr(y) - refresh(y);
end
ncf(NY) = ncf(NY) + salvage;
npv_inc = ncf ./ (1+WACC).^((1:NY)');
fprintf('  [现金流口径] 剔除折旧%.0f亿(非现金), 计入周期重置%.0f亿, 期末残值%.0f亿\n', ...
    sum(depr_y), sum(refresh), salvage);

% ── 累计净现金流 & 投资回收年份 ───────────────────────────────────────
cum_ncf = cumsum(ncf);
npv_cum = cumsum(npv_inc);
payback_yr = find(cum_ncf > 0, 1);
if isempty(payback_yr); payback_yr = NaN; end
irr_approx = NaN;
if ~any(isnan(ncf)) && sum(ncf) > 0
    try
        % 简单IRR近似（二分法求NPV=0的折现率）
        r_lo=0.01; r_hi=0.50;
        for k=1:50
            r_mid=(r_lo+r_hi)/2;
            npv_mid=sum(ncf./(1+r_mid).^(1:NY)');
            if npv_mid>0; r_lo=r_mid; else; r_hi=r_mid; end
        end
        irr_approx = r_lo;
    catch; end
end
payback_vec = repmat(payback_yr, NY, 1);
irr_vec     = repmat(irr_approx, NY, 1);

hvdc_node_names = {'内蒙','甘肃','宁夏','贵州'};
east_names      = {'北京','上海','广州'};
hvdc_headers = {};
hvdc_data_all = zeros(NY, NI*NJ*2);  % 扩容量 + 利用率
hvdc_util_override = nan(NY, NI*NJ);
col = 0;
for i = 1:NI
    for j = 1:NJ
        col = col + 1;
        hvdc_headers{end+1} = sprintf('HVDC_%s_%s_扩容MW', hvdc_node_names{i}, east_names{j});
        hvdc_headers{end+1} = sprintf('HVDC_%s_%s_利用率', hvdc_node_names{i}, east_names{j});
        for y = 1:NY
            cap_base = P.HVDC_cap_per_node(i,j);
            dL_y = squeeze(dL_cum_mat(y,i,j));
            if isnan(dL_y); dL_y=0; end
            total_cap = cap_base + dL_y;
            hvdc_data_all(y, (col-1)*2+1) = dL_y;                              % 修正: 扩容列原未写入
            act_y = results_yearly{y}.actual; u_ = NaN;
            if isfield(act_y,'P_hvdc') && size(act_y.P_hvdc,2) >= i
                capi_ = sum(P.HVDC_cap_per_node(i,:)) + sum(squeeze(dL_cum_mat(y,i,:)), 'omitnan');
                u_ = sum(act_y.P_hvdc(:,i)) / max(1, capi_ * size(act_y.P_hvdc,1));
            end
            hvdc_util_override(y, col) = u_;
            % HVDC利用率 = 实际传输量 / 通道最大传输能力
    % 正确：用act.total_migration(百万tokens)折算为等效MW传输量
    for i2 = 1:NI
        for j2 = 1:NJ
            cap_ij = P.HVDC_cap_per_node(i2,j2) + dL_inc(i2,j2);
            max_annual_flow = cap_ij * 8736;  % MW·h
            if max_annual_flow > 0 && ~isnan(migration(y)) && migration(y) > 0
                % C类迁移等效电力传输：migration × Lambda_C_est × MWh/百万tokens
                MWh_per_Mtok = 1 / P.eta_token;  % MWh/百万tokens
                flow_ij = migration(y) * max(1, mean(R.demand_y(3,:))) * P.eta_token ...
                          * 52 * 168 / (NI*NJ) * MWh_per_Mtok;
                hvdc_data_all(y, (col-1)*2+2) = min(1.0, flow_ij / max_annual_flow);
            else
                hvdc_data_all(y, (col-1)*2+2) = 0;
            end
        end
    end
        end
    end
end

% ── 按节点输出训练/绿电/储能 ─────────────────────────────────────────────
for y_ = 1:NY; for c_ = 1:NI*NJ                                    % 用实际外送电量的利用率覆盖原代理值
    if isfinite(hvdc_util_override(y_,c_)); hvdc_data_all(y_, (c_-1)*2+2) = min(1, hvdc_util_override(y_,c_)); end
end; end
node_headers = {};
node_data = zeros(NY, NI*4);  % z,W_T,G,E_w per node
for i = 1:NI
    nm = hvdc_node_names{i};
    node_headers{end+1} = ['选址_' nm];
    node_headers{end+1} = ['训练容量_' nm '_MW'];
    node_headers{end+1} = ['绿电_' nm '_MW'];
    node_headers{end+1} = ['储能_' nm '_MWh'];
    for y = 1:NY
        node_data(y,(i-1)*4+1) = z_node(y,i);
        node_data(y,(i-1)*4+2) = W_T_node(y,i);
        node_data(y,(i-1)*4+3) = G_node(y,i);
        node_data(y,(i-1)*4+4) = Ew_node(y,i);
    end
end

% ── 写CSV ────────────────────────────────────────────────────────────────
out_path = fullfile(P.out_dir, 'summary.csv');
fid = fopen(out_path, 'w');
fprintf(fid, '%s\n', strjoin([...
    {'年份','训练容量_MW','推理容量_MW','绿电装机_MW','西储能_MWh','东储能_MWh',...
     '年度投资_亿元','年度收益_亿元','年度运营成本_亿元',...
     '年度净现金流_亿元','累计净现金流_亿元',...
     '折现净现金流_亿元','累计NPV_亿元',...
     'ROI','IRR','投资回收年份',...
     '弃电模式','购电模式','降载模式',...
     'B类SLA违约率','C类迁移率','绿电利用率',...
     '碳减排_百万tCO2','平均通信时延_ms',...
     '弃风弃光率',...
     'Benders轮次','Benders最终Gap','整数割数量','eps_1',...
     'Gurobi状态'}, node_headers, hvdc_headers], ','));

for y = 1:NY
    base = [y, W_T_tot(y), W_I_tot(y), G_tot(y), Ew_tot(y), Ee_tot(y), ...
            inv_incr(y), rev(y), op_cost(y), ...
            ncf(y), cum_ncf(y), ...
            npv_inc(y), npv_cum(y), ...
            roi(y), irr_vec(y), payback_vec(y), ...
            mode_curt(y)*100, mode_grid(y)*100, mode_load(y)*100, ...
            b_viol(y), migration(y), green_util(y), ...
            carbon_save(y), comm_delay(y), ...
            1-green_util(y), ...
            n_iter(y), gap(y), n_cuts(y), eps1(y), ...
            master_ok(y)];
    vals = [base, node_data(y,:), hvdc_data_all(y,:)];
    fmt = [repmat('%g,', 1, length(vals)-1), '%g\n'];
    fprintf(fid, fmt, vals);
end
fclose(fid);

fprintf('  [CSV] summary.csv 已生成: %d行 × %d列\n', NY, ...
    1+length(base)+size(node_data,2)+size(hvdc_data_all,2));
if isnan(payback_yr); pb_s = '规划期内未回收'; else; pb_s = sprintf('Y%d', payback_yr); end
if isnan(irr_approx); irr_s = '无(累计现金流未转正)'; else; irr_s = sprintf('%.1f%%', irr_approx*100); end
fprintf('  [财务] Y15累计NPV=%.1f亿  投资回收=%s  IRR=%s\n', npv_cum(end), pb_s, irr_s);
end
