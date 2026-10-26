function [v, ov] = extra_obj_terms(x, state, P, year)
%% 主问题目标中的附加项(与solve_master_problem逐项一致), 供UB同口径计算
%  = 资产回收闭合溢价 + 电网越限罚 − 世界模型前瞻修正
v = 0; ov = 0;
dK = [sum(x.W_T) - sum(state.W_T_cum); sum(x.W_I) - sum(state.W_I_cum); sum(x.G) - sum(state.G_cum); ...
      sum(x.E_w) - sum(state.E_w_cum); sum(x.E_e) - sum(state.E_e_cum); 0; 0];
if isfield(x,'dL') && isfield(state,'dL_cum') && isequal(size(x.dL), size(state.dL_cum)); dK(6) = sum(x.dL(:)) - sum(state.dL_cum(:)); end
if isfield(x,'rt') && isfield(state,'rt_cum') && isequal(size(x.rt), size(state.rt_cum)); dK(7) = sum(x.rt(:)) - sum(state.rt_cum(:)); end
if (~isfield(P,'enable_bankability') || P.enable_bankability) && isfield(P,'wm') && isstruct(P.wm) ...
        && isfield(P.wm,'rho_mg') && numel(P.wm.rho_mg) == 7
    bw = 0.5; if isfield(P,'bank_weight'); bw = P.bank_weight; end
    rm = P.wm.rho_mg(:); rm(~isfinite(rm)) = 0;
    v = v + (bw * max(0, -rm) .* capex_unit_annual(P, year)')' * dK;
end
if (~isfield(P,'enable_net_planning') || P.enable_net_planning) && isfield(P,'net') && ~isempty(P.net)
    dP = [P.net.cfw(:) .* x.G(:) - x.W_T(:); -x.W_I(:)];
    fl = P.net.f0(:) + P.net.H * dP;
    ov = sum(max(0, abs(fl) - P.net.rate(:)));
    np = 30; if isfield(P,'net_pen'); np = P.net_pen; end
    v = v + np * ov;
end
if (~isfield(P,'enable_world_model') || P.enable_world_model) && isfield(P,'wm') && isstruct(P.wm) ...
        && isfield(P.wm,'active') && P.wm.active && numel(P.wm.adj) == 7
    kw = 0.5; if isfield(P,'world_model_kappa'); kw = P.world_model_kappa; end
    v = v - kw * (P.wm.adj(:)' * dK);
end
end
