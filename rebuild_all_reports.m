function rebuild_all_reports()
%% 本文方法与五组对比的报告一次性重建, 并刷新对比汇总
rebuild_reports('simulation_output');
C = comparison_cases(); f = fieldnames(C);
for k = 1:numel(f); rebuild_reports(['cmp_' f{k}]); end
compare_cases();
end
