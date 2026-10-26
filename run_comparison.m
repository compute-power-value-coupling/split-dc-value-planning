function run_comparison(names__)
%% 单窗口依次运行对比组(本文方法使用 simulation_output 中已有的主程序结果)
%  run_comparison                          % 五组全部
%  run_comparison({'S1_AHGF'})    % 指定组
%  每组输出到 cmp_<组名>/ , 日志 cmp_<组名>/run_log.txt ; 中断后再次运行自动从检查点续跑
global CMP_CASE
C__ = comparison_cases(); all__ = fieldnames(C__)';
if nargin < 1 || isempty(names__); names__ = all__; end
root__ = fileparts(mfilename('fullpath'));
for i__ = 1:numel(names__)
    n__ = names__{i__};
    od__ = fullfile(root__, ['cmp_' n__]); if ~exist(od__,'dir'); mkdir(od__); end
    CMP_CASE = C__.(n__); CMP_CASE.out_dir = od__; CMP_CASE.resume = true;
    CMP_CASE.stop_after_year = []; CMP_CASE.show_figs = false;
    fprintf('\n════════ 对比组 %d/%d: %s ════════\n', i__, numel(names__), n__);
    diary(fullfile(od__, 'run_log.txt')); diary on;
    CMP_RUNNING = true; %#ok<NASGU>
    try
        run(fullfile(root__, 'main_15year_simulation.m'));
    catch ME__
        fprintf('[对比组 %s] 运行失败: %s\n', n__, ME__.message);
    end
    diary off; close all;
end
CMP_CASE = [];
compare_cases();
end
