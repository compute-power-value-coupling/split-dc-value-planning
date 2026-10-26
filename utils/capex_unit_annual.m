function a = capex_unit_annual(P, year)
%% 各资产单位容量的年金化投资(万元/单位/年), 与capex_annual同口径
%  顺序: [训练MW, 推理MW, 绿电MW, 西储MWh, 东储MWh, HVDC MW, 直连路由(对)]
r = 0.08; if isfield(P,'r_min'); r = P.r_min; end
crf = @(n) r*(1+r)^n/((1+r)^n-1);
rG = P.C_gpu_ratio;
C_ie = P.C_infer_fix * max(0.65, (1 - 0.05 * min(year-1, 8)));
a = [P.C_train_fix*((1-rG)*crf(15) + rG*crf(P.T_gpu_life)), C_ie*crf(15), ...
     0.5*(P.C_renew_wind + P.C_renew_pv)*1000*crf(20), P.C_stor*1000*crf(P.T_stor_life), ...
     P.C_stor*1000*crf(P.T_stor_life), mean(P.C_trans_per_node(:))*crf(25), mean(P.C_route_per_pair(:))*crf(20)];
end
