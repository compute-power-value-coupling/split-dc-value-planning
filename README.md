# Value-driven long-term co-planning of split training and inference data centres

MATLAB implementation for jointly planning computing infrastructure, power supply and communication links over a 15-year horizon.

**Associated manuscript:** *Value-driven long-term co-planning of training and inference data centres with power and communication networks*.

**Authors:** Yuqian Liu, Guojian Sun, Peng Sun, Mao Yang and Zhe Chen. Yuqian Liu and Guojian Sun contributed equally; Peng Sun is the corresponding author. [Affiliations](#authors-and-correspondence)

[中文说明](docs_README_zh.md) · [Setup](#environment-and-setup) · [Replot results](#replot-the-archived-results) · [Run simulations](#run-the-complete-simulations) · [Script and output index](#script-and-output-index) · [Citation](CITATION.cff)

## Overview

The model couples seven East Data West Computing hubs, a modified IEEE 118-bus power system and a seven-node communication backbone. It plans investment in training and inference computing, wind and solar generation, western and eastern storage, inter-regional HVDC corridors and direct fibre routes. An 8,760-hour digital twin evaluates each annual plan.

The implementation combines service value metering (SKU-AHGF), asset value attribution and lifetime recursion (AFZ-VFS-FBR), and a value-learning world model (VLM-WM). The [method-to-code index](#method-to-code-index) locates these components.

| What you want to do | Start here | Inputs |
|---|---|---|
| Inspect the study's outputs and redraw figures | [Replot the archived results](#replot-the-archived-results) | Archived CSV and MAT files |
| Recalculate economic sensitivity on existing plans | [Economic sensitivity](#economic-sensitivity-from-existing-results) | Complete scheme checkpoints |
| Generate new plans and comparison results | [Run the complete simulations](#run-the-complete-simulations) | Code, configured dependencies and parameter settings |

The companion results dataset is identified in the manuscript's **Data availability** statement. Its six independent ZIP files are listed below. Code citation metadata are provided in [CITATION.cff](CITATION.cff).

## Environment and setup

The full planning workflow uses:

| Dependency | Purpose |
|---|---|
| MATLAB R2024a | Scripts and numerical analysis |
| Optimization Toolbox; Deep Learning Toolbox; Statistics and Machine Learning Toolbox | Optimization, learning and statistical routines |
| [YALMIP](https://yalmip.github.io/) | Investment master-problem modelling |
| [Gurobi](https://www.gurobi.com/) 10+, including its MATLAB interface | Configured investment master solver |
| [MATPOWER](https://matpower.org/) 7 | IEEE 118-bus data, default planning network constraints and ex-post N−1 screening |

1. Download or clone the code and extract it to a working directory.
2. Install the external dependencies using their own instructions, configure the solver licence, and make their MATLAB interfaces available on the MATLAB path.
3. Set MATLAB's **Current Folder** to the code root containing `main_15year_simulation.m` and `init_parameters.m`, then add the project directories:

```matlab
addpath(genpath(pwd));
```

Gurobi is required for the configured full planning workflow. The operational LP subproblems can fall back to `linprog`, but the investment master problem still uses Gurobi. Plotting archived results does not rerun the planning optimization.

## Replot the archived results

### 1. Download and unpack the result archives

The results are split by scheme to make downloads and retries smaller. Each ZIP can be extracted independently. Work with extracted copies and retain the original archives, because plotting writes derived files into the result directories.

| Scheme | Result archive | Scheme directory |
|---|---|---|
| Proposed approach | `split-dc-value-planning-results-proposed.zip` | `simulation_output/` |
| S1: uniform value metering with a fixed latency threshold | `split-dc-value-planning-results-S1-AHGF.zip` | `cmp_S1_AHGF/` |
| S2: power-side-only asset valuation | `split-dc-value-planning-results-S2-PO-VFS-FBR.zip` | `cmp_S2_PO_VFS_FBR/` |
| S3: Shapley attribution instead of counterfactual marginal value | `split-dc-value-planning-results-S3-AFZ-VFS-SHAP.zip` | `cmp_S3_AFZ_VFS_SHAP/` |
| S4: myopic rolling planning without the world model | `split-dc-value-planning-results-S4-MRP.zip` | `cmp_S4_MRP/` |
| S5: generic world model without value learning | `split-dc-value-planning-results-S5-WM.zip` | `cmp_S5_WM/` |

Each archive contains an outer `split-dc-value-planning-results/` directory, one scheme directory and a copy of the original results README. Copy the **six scheme directories** into the code root; keep the results README with the downloaded archives. On macOS, independently extracted outer folders may acquire numeric suffixes: use the scheme directory inside each one.

The resulting layout should be:

```text
split-dc-value-planning/
├── README.md
├── init_parameters.m
├── main_15year_simulation.m
├── plot_paper_figures.m
├── plot_comparison_figures.m
├── sensitivity/
├── simulation_output/
├── cmp_S1_AHGF/
├── cmp_S2_PO_VFS_FBR/
├── cmp_S3_AFZ_VFS_SHAP/
├── cmp_S4_MRP/
└── cmp_S5_WM/
```

Preserve every scheme's internal files and subdirectories, including `checkpoint/ckpt_latest.mat`. CSV files alone are insufficient for all figures. The proposed archive supplies the main-result plots; use all six archives for the complete comparison and sensitivity analyses. If you already have the original combined results ZIP, its six scheme directories can be used in the same layout.

### 2. Generate the figures

Run from the code root:

```matlab
plot_paper_figures('simulation_output', false)
plot_comparison_figures(pwd, false)
```

The `false` argument suppresses figure windows while saving the outputs. Figures are written to `simulation_output/paper_figs/` as PNG and PDF files. Check the MATLAB console for any skipped figures when required fields or files are unavailable. Map plots use the [map inputs described below](#data-and-map-inputs).

### Economic sensitivity from existing results

Use a writable code working copy with all six scheme directories in its root, then run from that root:

```matlab
addpath('sensitivity');
run_sensitivity
```

This performs economic post-processing of the archived plans and hourly operation. It recalculates cash flows, NPV and asset-recovery gaps under parameter changes, without rerunning investment planning or hourly operation. Each checkpoint must contain all 15 planning years. Derived tables are written to `sens_expost/`; the sensitivity figure is saved as `simulation_output/paper_figs/S01_sensitivity_matrix.png` and `.pdf`.

## Run the complete simulations

Use a separate working copy with empty result directories to retain the archived results for reference. Complete the [environment setup](#environment-and-setup), then run from the code root:

```matlab
main_15year_simulation    % Proposed approach -> simulation_output/
run_comparison            % Comparison schemes S1-S5 -> cmp_*/
```

The default model configuration is in [init_parameters.m](init_parameters.m); the comparison settings are in [comparison_cases.m](comparison_cases.m). After generating results, use the plotting commands above. For interrupted or staged runs, see [advanced settings](#advanced-settings).

## Script and output index

The figure identifiers here are the output IDs used by the supplied scripts.

| Analysis | Entry point | Main inputs | Output |
|---|---|---|---|
| Main-result and map figures: N01–N10, N12–N13, M1–M4 | [plot_paper_figures.m](plot_paper_figures.m) | Proposed scheme's checkpoint and supporting result files; map data | `simulation_output/paper_figs/` |
| Comparison figures: K01–K05 | [plot_comparison_figures.m](plot_comparison_figures.m) | Six schemes' `summary.csv`, `asset_recovery.csv` and checkpoints | `simulation_output/paper_figs/` and `simulation_output/comparison_yearly.csv` |
| Economic sensitivity: S01 | [sensitivity/run_sensitivity.m](sensitivity/run_sensitivity.m) | Six complete scheme checkpoints | `sens_expost/` and `simulation_output/paper_figs/` |

The main plotting script refreshes its generated N/M figure files when rerun. Copy any manually edited figure exports elsewhere before regenerating them.

## Data and map inputs

- **Power network:** the modified IEEE 118-bus system uses MATPOWER's `case118`; the scaling and network assumptions are configured in `init_parameters.m` and the data-loading routines.
- **Hourly inputs:** wind, solar and electricity-price series and the three-year initial history are generated by [data_loader/load_initial_history.m](data_loader/load_initial_history.m) with fixed random seeds.
- **Scenario and calibrated parameters:** demand shares, prices and investment costs are documented in `init_parameters.m` and Supplementary Tables 1 and 2 of the manuscript.
- **Archived results:** retain both the CSV tables and MAT files. The README included in each result archive describes their contents and units.
- **Map figures:** the manuscript's map figures use the Tianditu standard map, approval No. GS(2024)0650, which is not redistributed here. Obtain the provincial GeoJSON from [Tianditu](https://cloudcenter.tianditu.gov.cn/administrativeDivision) and save it as `map_data/中国_省.geojson`. Otherwise, plotting uses the simplified Apache ECharts outline included in `map_data/` for preview. See [map_data/README.md](map_data/README.md) for map sources and licensing.

## Method-to-code index

| Method component | Main files |
|---|---|
| Data collection and processing | `data_loader/`, [init_parameters.m](init_parameters.m) |
| Service value metering on an asymmetric heterogeneous graph (SKU-AHGF) | `utils/task_ratio_at.m`, `utils/reach_*.m`, `DACS/solve_subproblem_lp_fast.m`, `VAIC/solve_master_problem.m`, `benders/` |
| Asset value attribution and lifetime recursion (AFZ-VFS-FBR) | `output_module/compute_asset_attribution.m`, `output_module/value_flow_stock_fbr.m`, `AEMF/wm_sample_generator.m` |
| Value-learning world model for long-term decisions (VLM-WM) | `AEMF/vlm_wm_rl.m`, `AEMF/wm_mlp_train.m` |
| Annual 8,760-hour digital-twin evaluation | `utils/simulate_actual_operation.m` |
| Ex-post N−1 screening | `output_module/verify_dc_powerflow_n1.m` |
| Economic sensitivity post-processing | `sensitivity/run_sensitivity.m`, `sensitivity/plot_sensitivity_figure.m` |

## Advanced settings

### Resume or stage a run

Random seeds are fixed for each planning year. For a standalone main run, set `P.resume = true` **inside `init_parameters.m`** before calling `main_15year_simulation`, keeping the other parameters unchanged. An assignment in the MATLAB command window is insufficient because the main script initializes its own parameters.

Set `P.stop_after_year` in the same file to stop after a selected planning year. `run_comparison` enables resumption for its comparison runs.

### Figure appearance

Figure text defaults to 14 pt; [utils/fit_figure_text.m](utils/fit_figure_text.m) adapts the layout. Supply a third argument to change the size:

```matlab
plot_paper_figures('simulation_output', true, 18)
```

The [Chinese guide](docs_README_zh.md) contains a more detailed index of the figure contents.

### Optional and inactive modules

The supplied configuration is intended for the study's model setup. Modules disabled there, such as `enable_RL_cut`, are retained for completeness. The heuristic operating subproblems are selected only when `recourse_lp = false`; the default configuration uses the LP formulation.

## Authors and correspondence

Yuqian Liu¹, Guojian Sun², Peng Sun¹, Mao Yang¹ and Zhe Chen¹.

¹ Key Laboratory of Modern Power System Simulation and Control & Renewable Energy Technology, Ministry of Education (Northeast Electric Power University), Jilin 132012, China

² Jiangxi University of Finance and Economics, Nanchang 330013, China

Yuqian Liu and Guojian Sun contributed equally to this work. Corresponding author: **Peng Sun**.

## Citation and licence

Please cite the associated paper and the archived code version when using this work. Machine-readable code citation metadata are in [CITATION.cff](CITATION.cff). Cite the companion results dataset as well when using its archived outputs; refer to the manuscript's availability statements for the archive identifiers.

- **Project code:** MIT licence; see [LICENSE](LICENSE).
- **Archived simulation results:** CC BY 4.0, as stated in the results README.
- **Third-party map data:** retain their own source and licence terms; see [map_data/README.md](map_data/README.md).
