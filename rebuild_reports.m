function rebuild_reports(out_dir)
%% 不重跑仿真, 用检查点中的逐年结果重新生成 summary.csv 与绿电去向表(修正弃电率与HVDC扩容列)
%  rebuild_reports('simulation_output'); rebuild_reports('cmp_S1_AHGF'); ...
if nargin < 1; out_dir = 'simulation_output'; end
ck = fullfile(out_dir, 'checkpoint', 'ckpt_latest.mat');
if ~exist(ck,'file'); fprintf('[跳过] %s 无检查点\n', out_dir); return; end
S = load(ck, 'results_yearly');
P = init_parameters(); P.out_dir = out_dir;
write_summary_csv(S.results_yearly, P);
fid = fopen(fullfile(out_dir,'green_balance.csv'),'w');
fprintf(fid,'年份,可发绿电_TWh,训练直接消纳_TWh,HVDC外送_TWh,迁移跨域储能等吸纳_TWh,最终弃电_TWh,最终弃电率\n');
for y = 1:numel(S.results_yearly)
    R = S.results_yearly{y}; if isempty(R); continue; end
    a = R.actual; st = R.state; av = 0;
    for i = 1:min(numel(st.G_cum), size(a.cf_wind,2)); av = av + sum(st.G_cum(i)*(a.cf_wind(:,i) + a.cf_pv(:,i))/2); end
    tr = sum(a.P_renew(:)); hv = 0; if isfield(a,'P_hvdc'); hv = sum(a.P_hvdc(:)); end
    cu = sum(a.P_curt(:)); ot = max(0, av - tr - hv - cu);
    fprintf(fid,'Y%d,%.3f,%.3f,%.3f,%.3f,%.4f,%.5f\n', y, av/1e6, tr/1e6, hv/1e6, ot/1e6, cu/1e6, cu/max(1,av));
end
fclose(fid);
fprintf('[已重建] %s/summary.csv 与 green_balance.csv\n', out_dir);
end
