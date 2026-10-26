# 算电通信多网价值规划（SLA–SKU异质图网络流 · AFZ-VFS-FBR · VLM-WM）

## 环境
- MATLAB R2024a（与英文 README 的环境要求一致）；Optimization Toolbox、Deep Learning Toolbox、Statistics and Machine Learning Toolbox
- Gurobi 10+（含MATLAB接口 `gurobi.m`，默认投资主问题求解器）；YALMIP（主问题建模）；MATPOWER 7（默认规划网络约束与N−1筛查所需）
- 无Gurobi时只有运行LP子问题自动切换为 `linprog`（较慢），不代表完整规划流程可在无Gurobi时等价复现

## 运行
先将 MATLAB 当前文件夹切换到包含 `main_15year_simulation.m` 和 `init_parameters.m` 的代码根目录。

只重绘已有结果时，解压结果包，将其中的 `simulation_output/` 和五个 `cmp_*/` 方案文件夹复制到代码根目录，保留各方案的完整目录和 `checkpoint/ckpt_latest.mat`。然后执行下方两个绘图命令即可，无需先运行主仿真。经济敏感性分析可在代码根目录执行 `cd sensitivity; run_sensitivity; cd ..`，它读取上述检查点进行后处理，不重新规划。新仿真请使用单独的工作副本，保留归档结果原件。

```matlab
main_15year_simulation            % 主结果(本文方法), 输出至 simulation_output/
plot_paper_figures('simulation_output')   % 本文仿真图 N01–N13 + 国家地图仿真图 M1–M4, 自动弹出并保存(PNG 600dpi + PDF); 加参数 false 则只保存不弹出
plot_comparison_figures                   % 本文与五组单因素对比图 K01–K05 (读取已有结果, 无需重跑)
```

图中字号默认 14 磅, 版面随字号自动调整(utils/fit_figure_text.m); 第三个参数可指定字号, 如 `plot_paper_figures('simulation_output', true, 18)`。

独立运行主程序的断点续跑：先在 `init_parameters.m` 内设置 `P.resume = true`，并保持其余参数不变；分阶段运行同样在该文件内设置 `P.stop_after_year = 3`。只在 MATLAB 命令行设置 `P.resume` 不会生效，主程序会清空工作区并重新初始化参数。`run_comparison` 已为对比方案启用续跑。逐年随机种子由 `P.seed` 固定。

## 结构与方法对应
| 目录/文件 | 论文对应 |
|---|---|
| `utils/task_ratio_at.m`, `utils/reach_*.m`, `DACS/solve_subproblem_lp_fast.m` | 第2节 SLA–SKU驱动的异质图网络流、服务可达域（规划运行模型：12个月代表周×168h LP）|
| `VAIC/solve_master_problem.m`, `benders/inner_benders_loop.m` | 第2.6/5节 年度规划主问题与Benders分解（精确对偶割、下界预热、选址枚举、近端信赖域）|
| `utils/simulate_actual_operation.m` | 8760h实际运行层（数字孪生，用于检验与价值归因）|
| `output_module/compute_asset_attribution.m`, `output_module/value_flow_stock_fbr.m`, `AEMF/wm_sample_generator.m` | 第3节 AFZ-VFS-FBR：价值流、存量、协态、反事实边际 |
| `AEMF/vlm_wm_rl.m`, `AEMF/wm_mlp_train.m`, `output_module/planning_mechanics_report.m` | 第4节 VLM-WM：世界模型、critic、CEM推演、规划力学、候选检验 |
| `init_parameters.m` | 全部参数（含来源与假设注释）|

## 数据
- 电网：IEEE 118节点（MATPOWER `case118`，负荷与机组×20）
- 风光出力与电价：`data_loader/load_initial_history.m` 生成的3年合成小时序列（固定种子2024，季节与日内形状参数见文件）
- 需求结构：按公开行业测算标定的三族份额（非AI/AI推理/AI训练），Y6之后为情景外推
- 骨干网时延：`data_loader/load_comm_delay_matrix.m`

## 建模边界
运行模型为线性（不含机组组合与整数任务调度）；电网约束在规划层以DC-PTDF软约束计入；实际运行层为规则型数字孪生，与规划模型逐年校准；线路额定值为推定值。

## 遗留模块
`AEMF/BendersRLEnvironment.m` 等旧强化学习割模块默认关闭（`P.enable_RL_cut=false`），不参与本文结果；`DACS/subproblem_DACS_*.m` 为旧启发式运行子问题（`P.recourse_lp=false` 时启用）。


## 仿真图 v3(期刊风格, 中文字体, 一图一幅; 均读取已有结果, 无需重跑仿真)
输出到 `simulation_output/paper_figs/`, 每张图 PNG(600dpi) + PDF。字体自动选 宋体(SimSun), 无则依次退到其他中文衬线/黑体。

| 编号 | 图式 | 内容 |
|---|---|---|
| N01 | 三维切片瀑布 | x 年份, y SLA类别(A/B/C/D), z 需求功率, 颜色 = 单位电量服务价值(SKU) |
| N02 | 散点 + 二维核密度 + 边缘分布 | 西部绿电出力 vs 训练负荷(第5/10/15年) |
| N03 | 六边形分箱 + 条件均值/95%置信带 | 东西部电价差 → 西部承接迁移与跨域服务功率 |
| N04 | 月份–时刻三维地形 + 底面投影 | 末年训练负荷(高度) 与 西部绿电(颜色) |
| N05 | 山脊图 | 15年小时训练负荷分布演化(竖线为中位数) |
| N06 | 价值势地形 + 规划轨迹 | 世界模型样本三次响应面, 叠加实际规划路径 |
| N07 | 正负堆叠流 | 各资产累计折现运营价值 + 系统净值 |
| N08 | 气泡矩阵 | 颜色 = 边际学习力 ρ, 面积 = 次年投资速度 |
| N09 | 联合核密度 + 边缘分布 | 上年学习力 ρ 与本年投资速度 |
| N10 | 热图 + 顶部曲线 | 前瞻−近视首年增量 与 逐年前瞻价值 VoF |
| N12 | 相关性矩阵 + 聚类树 | 第5年与末年逐小时的绿电出力/训练负荷/HVDC外送/跨域服务承接/东西部电价: 下三角散点, 对角核密度, 上三角末年 Pearson r |
| N13 | 三维收敛曲面 | x 迭代轮次, y 规划年份, z/颜色 = Benders 上下界间隙(对数), 各年终止后保持末轮间隙 |
| M1 | 全国流线地图 | 东部推理→西部训练任务流(B+C), 每条流线 = 一个年份 |
| M2 | 全国流线地图 | 西电东送 HVDC 逐年通道容量 |
| M3 | 全国流线地图 | 训练→推理跨网价值流 |
| M4 | 时空立方体 | x,y 地图, z 年份, 颜色 = 任务流强度, 竖柱 = 节点容量 |
| K01 | 箱线 + 抖动散点 | 末年365个日均训练算力利用率, 顶部标注年均值与名次 |
| K02 | 平行坐标 | 规划中后期(第8–15年)逐年 9 项指标组内归一化得分: 淡线为每种方法每一年, 粗线为组均值, 阴影为四分位带 |
| K03 | 山脊图 | 末年小时闲置训练算力, 标注相对本文变化 |
| K04 | 三维切片 | 东部储能逐年配置, 颜色 = 资产回收缺口 |
| K05 | 差值矩阵 | 资产级NPV(对比方法 − 本文) |

底图数据在 `map_data/`(见其中 README), 投稿前替换为带审图号的标准地图数据即可, 代码不用改。
