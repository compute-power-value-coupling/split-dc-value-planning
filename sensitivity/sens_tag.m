function t = sens_tag(p, lev, s)
%% 敏感性组合目录名: <参数>_<水平>_<方案>, 如 demand_0p80_Proposed
t = sprintf('%s_%s_%s', p, strrep(sprintf('%.2f', lev), '.', 'p'), s);
end
