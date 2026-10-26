# 算电通信多网价值规划

本项目为训练与推理数据中心、电力供给及通信网络的15年协同规划提供 MATLAB 实现，包含主方案、五组对比方案及结果绘图入口。

[English README](README.md) · [环境与准备](#环境与准备) · [从归档结果重绘](#从归档结果重绘) · [完整仿真](#运行完整仿真) · [脚本与输出](#脚本与输出索引) · [作者与单位](README.md#authors-and-correspondence) · [引用信息](CITATION.cff)

## 从哪里开始

| 目的 | 入口 | 所需材料 |
|---|---|---|
| 查看已有结果并重新绘图 | 下方“从归档结果重绘” | 结果包中的 CSV、MAT 检查点及辅助文件 |
| 在既有规划上重新核算经济敏感性 | “经济敏感性后处理” | 六方案完整15年检查点 |
| 重新生成规划与对比结果 | “运行完整仿真” | 源码、外部依赖与参数配置 |

结果归档入口见论文的 Data availability 声明，代码引用信息见 `CITATION.cff`。三个方法模块为服务价值计量（SKU-AHGF）、资产价值归因与寿命递推（AFZ-VFS-FBR）和价值学习世界模型（VLM-WM）；下方保留方法与代码、图形内容的详细索引。

## 环境与准备

- MATLAB R2024a；Optimization Toolbox、Deep Learning Toolbox、Statistics and Machine Learning Toolbox。
- [YALMIP](https://yalmip.github.io/)：投资主问题建模。
- [Gurobi](https://www.gurobi.com/) 10+ 及其 MATLAB 接口：默认投资主问题求解器。
- [MATPOWER](https://matpower.org/) 7：IEEE 118节点数据、默认规划网络约束与事后 N−1 筛查。

自行安装外部依赖、配置所需许可证，并按各工具说明将其 MATLAB 接口加入路径。将 MATLAB 当前文件夹切换到包含 `main_15year_simulation.m` 和 `init_parameters.m` 的代码根目录，再执行：

```matlab
addpath(genpath(pwd));
```

完整规划流程使用上述环境。无 Gurobi 时，只有运行 LP 子问题会切换到 `linprog`；投资主问题仍使用 Gurobi。从归档结果绘图不重新执行规划优化。

## 从归档结果重绘

### 1. 解压并摆放六个方案

结果已按方案拆成六个可独立解压的 ZIP：

| 方案 | 压缩包 | 方案目录 |
|---|---|---|
| 本文方法 | `split-dc-value-planning-results-proposed.zip` | `simulation_output/` |
| S1 | `split-dc-value-planning-results-S1-AHGF.zip` | `cmp_S1_AHGF/` |
| S2 | `split-dc-value-planning-results-S2-PO-VFS-FBR.zip` | `cmp_S2_PO_VFS_FBR/` |
| S3 | `split-dc-value-planning-results-S3-AFZ-VFS-SHAP.zip` | `cmp_S3_AFZ_VFS_SHAP/` |
| S4 | `split-dc-value-planning-results-S4-MRP.zip` | `cmp_S4_MRP/` |
| S5 | `split-dc-value-planning-results-S5-WM.zip` | `cmp_S5_WM/` |

每个 ZIP 内都有外层 `split-dc-value-planning-results/` 文件夹、一个方案目录和一份相同的原始结果 README。将表中的**六个方案目录**复制到代码根目录，使它们与 `plot_paper_figures.m` 同层；结果 README 保留在下载材料中。macOS 分别解压时可能给外层同名文件夹加数字后缀，取各自内部的方案目录即可。

保留方案内部的全部文件及 `checkpoint/ckpt_latest.mat`。仅 CSV 不足以生成完整图集。主方案图使用本文方法结果；完整对比及敏感性分析使用六方案结果。已有旧版合并结果 ZIP 时，取其中相同的六个目录即可。

绘图会在结果目录中写入或更新派生文件；请操作解压后的工作副本，并保留原始 ZIP。

### 2. 执行绘图

在代码根目录执行：

```matlab
plot_paper_figures('simulation_output', false)
plot_comparison_figures(pwd, false)
```

`false` 表示保存图文件而不弹出图窗。图文件写入 `simulation_output/paper_figs/`。输入缺失时，脚本可能跳过部分图，请查看 MATLAB 命令窗口中的提示。地图输入另见下方“数据与地图”。

### 经济敏感性后处理

在可写的代码工作副本中，将六个方案目录放在代码根目录后执行：

```matlab
addpath('sensitivity');
run_sensitivity
```

此入口读取完整15年检查点，保持规划方案和小时运行结果不变，重新核算经济参数扰动下的现金流、NPV及资产回收缺口，不重跑投资规划或8760小时运行。派生表格写入 `sens_expost/`，并自动生成 `simulation_output/paper_figs/S01_sensitivity_matrix.png` 和 `.pdf`。

## 运行完整仿真

使用单独的代码工作副本和空的结果目录，保留归档结果原件。完成环境准备后，在代码根目录执行：

```matlab
main_15year_simulation    % 本文方法，输出至 simulation_output/
run_comparison            % 五组对比，输出至各 cmp_*/ 目录
```

默认参数见 [init_parameters.m](init_parameters.m)，对比方案设置见 [comparison_cases.m](comparison_cases.m)。结果生成后再使用前述绘图命令。

## 脚本与输出索引

下面使用代码中的输出编号；论文最终图号以投稿稿件为准。

| 分析 | 入口 | 主要输入 | 输出 |
|---|---|---|---|
| 主方案与地图图形：N01–N10、N12–N13、M1–M4 | `plot_paper_figures.m` | 主方案检查点、辅助结果及地图数据 | `simulation_output/paper_figs/` |
| 对比图：K01–K05 | `plot_comparison_figures.m` | 六方案的汇总表、资产回收表及检查点 | `simulation_output/paper_figs/`，另写 `simulation_output/comparison_yearly.csv` |
| 经济敏感性：S01 | `sensitivity/run_sensitivity.m` | 六方案完整15年检查点 | `sens_expost/` 及 `simulation_output/paper_figs/` |

主图脚本重绘时会刷新对应的 N/M 图文件；已手工编辑的图请另存后再重绘。下方图形内容表保留了各输出编号的详细解释。

## 数据与地图

- 电网采用 MATPOWER `case118` 的修改版；容量缩放参数 `P.ieee118_scale = 20` 及网络假设见参数文件与数据加载程序。
- 风光出力、电价及3年初始历史由 `data_loader/load_initial_history.m` 使用固定随机种子生成。
- 需求结构、价格和投资成本见 `init_parameters.m`，并对应论文补充表1和表2。
- 通信骨干网时延见 `data_loader/load_comm_delay_matrix.m`。
- 结果包内的原始 README 说明了 CSV、MAT 文件内容及单位。
- 论文地图使用天地图标准地图，审图号 GS(2024)0650，本包未分发该底图。可从[天地图行政区划数据](https://cloudcenter.tianditu.gov.cn/administrativeDivision)获取省级 GeoJSON，保存为 `map_data/中国_省.geojson`；否则代码使用包内 Apache ECharts 简化轮廓作预览。来源与许可见 [map_data/README.md](map_data/README.md)。

## 高级设置

### 断点续跑和分阶段运行

独立运行主程序时，在 `init_parameters.m` 内设置 `P.resume = true`，并保持其余参数不变。分阶段运行在同一文件设置 `P.stop_after_year`。只在 MATLAB 命令窗口赋值不会生效，因为主程序会重新初始化参数。`run_comparison` 已为对比方案启用续跑；逐年随机种子由代码中的参数设置控制。

### 字体和版式

图中字号默认14磅，版面由 `utils/fit_figure_text.m` 调整。第三个参数可指定字号，例如：

```matlab
plot_paper_figures('simulation_output', true, 18)
```

各输出编号的图形内容见下方详表。

### 停用模块

默认配置对应本研究的模型设置。`AEMF/BendersRLEnvironment.m` 等旧强化学习割模块默认关闭（`P.enable_RL_cut = false`）；旧启发式运行子问题在 `P.recourse_lp = false` 时启用。默认运行子问题采用 LP。

## 结构与方法对应
| 目录/文件 | 方法模块 |
|---|---|
| `utils/task_ratio_at.m`, `utils/reach_*.m`, `DACS/solve_subproblem_lp_fast.m` | SLA–SKU驱动的异质图网络流、服务可达域（规划运行模型：12个月代表周×168h LP）|
| `VAIC/solve_master_problem.m`, `benders/inner_benders_loop.m` | 年度规划主问题与Benders分解（精确对偶割、下界预热、选址枚举、近端信赖域）|
| `utils/simulate_actual_operation.m` | 8760h实际运行层（数字孪生，用于检验与价值归因）|
| `output_module/compute_asset_attribution.m`, `output_module/value_flow_stock_fbr.m`, `AEMF/wm_sample_generator.m` | AFZ-VFS-FBR：价值流、存量、协态、反事实边际 |
| `AEMF/vlm_wm_rl.m`, `AEMF/wm_mlp_train.m`, `output_module/planning_mechanics_report.m` | VLM-WM：世界模型、critic、CEM推演、规划力学、候选检验 |
| `init_parameters.m` | 全部参数（含来源与假设注释）|


## 建模边界
运行模型为线性（不含机组组合与整数任务调度）；电网约束在规划层以DC-PTDF软约束计入；实际运行层为规则型数字孪生，与规划模型逐年校准；线路额定值为推定值。


## 图形内容详表

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


## 作者、引用与许可

作者顺序、共同第一作者、通讯作者与单位见[英文首页](README.md#authors-and-correspondence)，引用元数据见 [CITATION.cff](CITATION.cff)。

项目代码采用 MIT 许可证，见 [LICENSE](LICENSE)；归档仿真结果采用 CC BY 4.0；第三方地图保留各自来源和许可条件。引用本工作时请引用论文及所用代码归档版本；使用归档结果时同时引用对应数据记录。
