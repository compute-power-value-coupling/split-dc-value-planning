function A = capex_annual(x, state, P, year)
%% 投资年金化(与现金流口径一致): 资本回收系数CRF(r, 寿命) + GPU周期重置
%  训练算力: 非GPU部分按15年、GPU部分按T_gpu_life年年金(等价于含周期重置)
%  推理15年 | 绿电20年 | 储能T_stor_life年 | HVDC 25年 | 直连路由20年
%  原口径 F1/T_life(20年直线, 无利息, 无GPU重置)使训练算力年成本约75万/MW,
%  x可为数值解(UB)或YALMIP表达式(主问题)的字段集合
r = 0.08; if isfield(P,'r_min'); r = P.r_min; end
crf = @(n) r*(1+r)^n/((1+r)^n-1);
C_infer_eff = P.C_infer_fix * max(0.65, (1 - 0.05 * min(year-1, 8)));
rG = P.C_gpu_ratio;
aT = P.C_train_fix * ((1-rG)*crf(15) + rG*crf(P.T_gpu_life));
aI = C_infer_eff * crf(15);
aG = 0.5*(P.C_renew_wind + P.C_renew_pv) * 1000 * crf(20);
aS = P.C_stor * 1000 * crf(P.T_stor_life);
A = aT*sum(x.W_T) + aI*sum(x.W_I) + aG*sum(x.G) + aS*(sum(x.E_w) + sum(x.E_e));
if isfield(x,'dL') && ~isempty(x.dL)
    dLc = zeros(size(x.dL)); if isfield(state,'dL_cum') && isequal(size(state.dL_cum), size(x.dL)); dLc = state.dL_cum; end
    A = A + crf(25) * sum(sum(P.C_trans_per_node .* (x.dL - dLc)));
end
if isfield(x,'rt') && ~isempty(x.rt) && isfield(P,'C_route_per_pair')
    rtc = zeros(size(x.rt)); if isfield(state,'rt_cum') && isequal(size(state.rt_cum), size(x.rt)); rtc = state.rt_cum; end
    A = A + crf(20) * sum(sum(P.C_route_per_pair .* (x.rt - rtc)));
end
end
