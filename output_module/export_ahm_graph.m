function export_ahm_graph(results_yearly, P)
%% 非对称异质多层时空图逐年导出(创新一的图对象载体, 供论文作图与复核)
%  层: T训练侧 / I推理侧 / C通信 / E电力(IEEE118母线)
%  边: task_C, task_B (I→T, 任务迁移, 百万token)  |  value (T→I, 跨网价值, 万元)
%      comm (C↔C, 当年时延含路由)  |  hvdc (E→E, MW)  |  map_T/map_I (跨层接入, MW)
%  非对称: 任务边I→T与价值边T→I量纲和规模均不同, 不是彼此的转置(A^{TI}≠(A^{IT})^T)
%  另输出Ω_srv逐年摘要: 各SLA类在(西i,东j)上的可服务节点对数
outd = 'simulation_output'; if isfield(P,'out_dir'); outd = P.out_dir; end
if ~exist(outd,'dir'); mkdir(outd); end
NI = P.N_west; NJ = P.N_east;
wn = {'NM','GS','NX','GZ'}; en = {'BJ','SH','GZh'};
fe = fopen(fullfile(outd,'ahm_graph_edges.csv'),'w');
fprintf(fe,'年份,边类型,起点层,起点,终点层,终点,时延ms,容量,流量,单位\n');
fo = fopen(fullfile(outd,'omega_srv_summary.csv'),'w');
fprintf(fo,'年份,A类可服务对,B类可服务对,C类可服务对,D类可服务对,已建路由对,B外送token_百万\n');
fprintf('\n[多层图] 逐年导出 ahm_graph_edges.csv / omega_srv_summary.csv\n');
for y = 1:numel(results_yearly)
    R = results_yearly{y}; if isempty(R) || ~isfield(R,'state'); continue; end
    st = R.state; act = R.actual;
    Py = P;
    rt = zeros(NI,NJ); if isfield(st,'rt_cum'); rt = st.rt_cum; end
    if isfield(P,'comm_delay_base'); Py.comm_delay = route_delay_apply(P, rt); end
    Rb = reach_matrix(Py, st.z_cum);
    odC = zeros(NJ,NI); if isfield(act,'migration_OD'); odC = act.migration_OD; end
    odB = zeros(NJ,NI); if isfield(act,'Boff_OD');      odB = act.Boff_OD;      end
    rv = act.rev_parts; rb = 0; if isfield(rv,'b_offload'); rb = rv.b_offload; end
    for i = 1:NI
        for j = 1:NJ
            d = Py.comm_delay(P.west_hub_idx(i), P.east_hub_idx(j));
            if odC(j,i) > 0
                fprintf(fe,'Y%d,task_C,I,%s,T,%s,%.1f,,%.4g,百万token\n', y, en{j}, wn{i}, d, odC(j,i));
            end
            if odB(j,i) > 0
                fprintf(fe,'Y%d,task_B,I,%s,T,%s,%.1f,,%.4g,百万token\n', y, en{j}, wn{i}, d, odB(j,i));
            end
            val = 0;
            if sum(odC(:)) > 0; val = val + rv.migration * odC(j,i)/sum(odC(:)); end
            if sum(odB(:)) > 0; val = val + rb * odB(j,i)/sum(odB(:)); end
            if val > 0
                fprintf(fe,'Y%d,value,T,%s,I,%s,%.1f,,%.4g,万元\n', y, wn{i}, en{j}, d, val);
            end
            fprintf(fe,'Y%d,comm,C,%s,C,%s,%.1f,%d,,路由(1=直连)\n', y, wn{i}, en{j}, d, rt(i,j));
            if isfield(st,'dL_cum') && isequal(size(st.dL_cum),[NI NJ]) && st.dL_cum(i,j) > 0
                fprintf(fe,'Y%d,hvdc,E,%d,E,%d,,%.1f,,MW\n', y, P.ieee118_bus_west(i), ...
                    P.ieee118_bus_east(j), st.dL_cum(i,j));
            end
        end
        loadT = mean(act.P_train(:,i)); if isfield(act,'P_Boff'); loadT = loadT + mean(act.P_Boff(:,i)); end
        fprintf(fe,'Y%d,map_T,T,%s,E,%d,,%.1f,%.1f,MW(容量/平均负荷)\n', y, wn{i}, ...
            P.ieee118_bus_west(i), st.W_T_cum(i), loadT);
    end
    for j = 1:NJ
        fprintf(fe,'Y%d,map_I,I,%s,E,%d,,%.1f,,MW(容量)\n', y, en{j}, P.ieee118_bus_east(j), st.W_I_cum(j));
    end
    zsel = st.z_cum(:) > 0.5;
    nA = 0;                                   % A类: 功能不兼容训练侧
    nB = sum(Rb(:));
    nC = sum(zsel) * NJ;                      % C类: 24h时延容忍, 已选址即可达
    nD = sum(zsel);                           % D类: 仅训练侧本地
    fprintf(fo,'Y%d,%d,%d,%d,%d,%d,%.4g\n', y, nA, nB, nC, nD, sum(rt(:)), sum(odB(:)));
    fprintf('  Y%-2d Ω_srv: B类可达%d对 | 路由%d对 | B外送%.3g M token\n', y, nB, sum(rt(:)), sum(odB(:)));
end
fclose(fe); fclose(fo);
end
