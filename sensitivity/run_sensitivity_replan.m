function run_sensitivity_replan(params__, schemes__)
%% 关键参数敏感性分析(重规划模式, 需重跑仿真): 参数进入规划模型, 各方案重新完成15年规划
%  不需要重新规划的参数(折现率、投资成本)请用 run_sensitivity(事后评估, 不重跑)
%  run_sensitivity_replan                                  % 4个参数 × 2个水平 × 6个方案 = 48次15年仿真
%  run_sensitivity_replan({'demand'})                      % 只跑指定参数
%  run_sensitivity_replan({'demand'}, {'Proposed','S2_PO_VFS_FBR','S4_MRP'})   % 只跑指定方案(本文 + 最接近的两组, 24次)
%
%  参数(水平见 sens_params('replan')):
%    demand  算力需求增速   ×0.8 / ×1.2   (P.growth_scale, 缩放15年增长率曲线)
%    token   token效率增速  ×0.8 / ×1.2   (P.eta_token_gr_schedule)
%    stor    储能投资成本   ×0.8 / ×1.2   (P.C_stor)
%    disc    折现率         6% / 10%      (P.r_min, 主问题年金化/现金流/资产归因统一)
%
%  每次仿真输出到 sens_replan/<参数>_<水平>_<方案>/ ; 已完成的组合自动跳过, 中断后再次运行从检查点续跑
%  基准水平直接读取 simulation_output/ 与 cmp_<组名>/ 已有结果, 不重跑
%  全部完成后自动汇总 sens_replan/sensitivity.csv 并绘图(plot_sensitivity_figure)
%
%  放置: 本文件夹可直接放在 matlab_v2/ 下(如 matlab_v2/sensitivity/), 也可把文件复制到 matlab_v2/ 根目录
%  首次运行自动把 data_loader/load_growth_forecast.m 与 output_module/compute_asset_attribution.m
%  替换为补丁版(原文件备份为 .bak_before_sens; 两处补丁在未设置新字段时不改变任何已有结果)
global CMP_CASE
[root__, pkg__] = sens_root();
addpath(pkg__);
addpath(root__, fullfile(root__, 'data_loader'), fullfile(root__, 'output_module'), fullfile(root__, 'utils'));
sens_install(root__, pkg__);
fprintf('[敏感性] 工程目录: %s\n', root__);
SP__ = sens_params('replan');
if nargin < 1 || isempty(params__); params__ = fieldnames(SP__)'; end
C__ = comparison_cases();
if nargin < 2 || isempty(schemes__); schemes__ = [{'Proposed'}, fieldnames(C__)']; end
if ischar(params__); params__ = {params__}; end
if ischar(schemes__); schemes__ = {schemes__}; end

% 基准参数(用于按比例扰动)
old__ = cd(root__); P0__ = init_parameters(); cd(old__);

% 任务清单
jobs__ = cell(0, 3);
for ip__ = 1:numel(params__)
    p__ = params__{ip__};
    if ~isfield(SP__, p__); error('未知参数: %s (可选: %s)', p__, strjoin(fieldnames(SP__)', ', ')); end
    for il__ = 1:numel(SP__.(p__).levels)
        for is__ = 1:numel(schemes__)
            jobs__(end+1, :) = {p__, SP__.(p__).levels(il__), schemes__{is__}}; %#ok<AGROW>
        end
    end
end
nj__ = size(jobs__, 1);
sd__ = fullfile(root__, 'sens_replan'); if ~exist(sd__, 'dir'); mkdir(sd__); end
fprintf('\n[敏感性] 共 %d 个组合(参数 %s; 方案 %s)\n', nj__, strjoin(params__, ','), strjoin(schemes__, ','));

for j__ = 1:nj__
    p__ = jobs__{j__, 1}; lev__ = jobs__{j__, 2}; s__ = jobs__{j__, 3};
    tag__ = sens_tag(p__, lev__, s__);
    od__ = fullfile(sd__, tag__);
    if exist(fullfile(od__, 'summary.csv'), 'file') && exist(fullfile(od__, 'asset_recovery.csv'), 'file')
        fprintf('[敏感性 %d/%d] %s 已完成, 跳过\n', j__, nj__, tag__); continue;
    end
    if ~exist(od__, 'dir'); mkdir(od__); end
    cfg__ = struct();
    if ~strcmp(s__, 'Proposed')
        if ~isfield(C__, s__); error('未知方案: %s', s__); end
        cfg__ = C__.(s__);
    end
    ov__ = sens_override(p__, lev__, P0__);
    fo__ = fieldnames(ov__);
    for k__ = 1:numel(fo__); cfg__.(fo__{k__}) = ov__.(fo__{k__}); end
    cfg__.out_dir = od__; cfg__.resume = true; cfg__.stop_after_year = []; cfg__.show_figs = false;
    CMP_CASE = cfg__;
    fprintf('\n════════ 敏感性 %d/%d: %s ════════\n', j__, nj__, tag__);
    diary(fullfile(od__, 'run_log.txt')); diary on;
    CMP_RUNNING = true; %#ok<NASGU>
    try
        run(fullfile(root__, 'main_15year_simulation.m'));
    catch ME__
        fprintf('[敏感性 %s] 运行失败: %s\n', tag__, ME__.message);
    end
    diary off; close all;
    CMP_CASE = [];
end
CMP_CASE = [];
collect_sensitivity(root__, 'replan');
try
    plot_sensitivity_figure(root__, true, 'replan');
catch ME__
    fprintf('[敏感性] 绘图跳过: %s\n', ME__.message);
end
end
