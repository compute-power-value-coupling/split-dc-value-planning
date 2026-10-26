# Value-driven long-term co-planning of split training and inference data centres

MATLAB code accompanying the manuscript *"Value-driven long-term co-planning of training and inference data centres with power and communication networks"* (submitted to *Nature Communications*).

The code plans, year by year over a 15-year horizon, investment in training and inference computing, wind and solar generation, western and eastern storage, inter-regional HVDC corridors and direct fibre routes for seven East Data West Computing hubs on a modified IEEE 118-bus system and a seven-node backbone network. Each year's plan is verified by an 8,760-h digital twin.

## Authors and correspondence

Yuqian Liu¹, Guojian Sun², Peng Sun¹, Mao Yang¹ and Zhe Chen¹.

¹ Key Laboratory of Modern Power System Simulation and Control & Renewable Energy Technology, Ministry of Education (Northeast Electric Power University), Jilin 132012, China

² Jiangxi University of Finance and Economics, Nanchang 330013, China

Yuqian Liu and Guojian Sun contributed equally to this work.
Corresponding author: Peng Sun.

## Requirements

- MATLAB R2024a with Optimization Toolbox, Deep Learning Toolbox and Statistics and Machine Learning Toolbox
- [YALMIP](https://yalmip.github.io) (investment master problem)
- [Gurobi](https://www.gurobi.com) with its MATLAB interface (free academic licence available), required by the configured investment master solver. Only the operational LP subproblems fall back to `linprog` without Gurobi; this is not a Gurobi-free replacement for the complete planning workflow.
- [MATPOWER](https://matpower.org) (IEEE 118-bus data, the default planning network constraints and ex-post N−1 screening)

## Quick start

Set MATLAB's current folder to the repository root, which contains `main_15year_simulation.m` and `init_parameters.m`.

### Figures from the archived results

Extract `split-dc-value-planning-results.zip`. Copy the six scheme folders inside the extracted results folder into the repository root: `simulation_output/`, `cmp_S1_AHGF/`, `cmp_S2_PO_VFS_FBR/`, `cmp_S3_AFZ_VFS_SHAP/`, `cmp_S4_MRP/` and `cmp_S5_WM/`. Preserve their contents and subfolders, including `checkpoint/ckpt_latest.mat`; CSV files alone are not sufficient for all figures.

```matlab
plot_paper_figures('simulation_output', false)  % main-text figures from the archived results
plot_comparison_figures(pwd, false)             % comparison figures from the archived results
cd sensitivity
run_sensitivity                                % Fig. 6f: economic post-processing of existing checkpoints
cd ..
```

The sensitivity command reads the scheme folders from the repository root and writes derived results to `sens_expost/`; it does not rerun the planning model. Figure files are written to `simulation_output/paper_figs/`.

### Simulations from scratch

Use a separate working copy with empty output folders when generating new results, so that the archived results are preserved.

```matlab
main_15year_simulation                     % proposed approach, results written to simulation_output/
run_comparison                             % comparison schemes S1–S5, results written to cmp_S1_AHGF/ … cmp_S5_WM/
```

Figure text defaults to 14 pt and the layout adapts automatically (`utils/fit_figure_text.m`); pass a size as the third argument to change it, e.g. `plot_paper_figures('simulation_output', true, 18)`.


Random seeds are fixed for every planning year. To resume a standalone main run, set `P.resume = true` in `init_parameters.m` before calling `main_15year_simulation`, keeping the other parameters unchanged. Assigning `P.resume` in the MATLAB command window is not sufficient: the main script clears the workspace and initializes its own parameters. Set `P.stop_after_year` in the same parameter file to stop after a chosen planning year. `run_comparison` enables resumption for its comparison runs. All parameters, with sources and assumptions, are set in `init_parameters.m`.

## Code structure and correspondence with Methods

| Methods section | Main files |
|---|---|
| Data collection and processing | `data_loader/`, `init_parameters.m` |
| Service value metering on an asymmetric heterogeneous graph (SKU-AHGF) | `utils/task_ratio_at.m`, `utils/reach_*.m`, `DACS/solve_subproblem_lp_fast.m`, `VAIC/solve_master_problem.m`, `benders/` |
| Asset value attribution and lifetime recursion (AFZ-VFS-FBR) | `output_module/compute_asset_attribution.m`, `output_module/value_flow_stock_fbr.m`, `AEMF/wm_sample_generator.m` |
| Value learning world model for long-term decisions (VLM-WM) | `AEMF/vlm_wm_rl.m`, `AEMF/wm_mlp_train.m` |
| Digital twin (8,760-h verification) | `utils/simulate_actual_operation.m` |
| Ex-post N−1 screening | `output_module/verify_dc_powerflow_n1.m` |
| Sensitivity to economic parameters (Fig. 6f) | `sensitivity/run_sensitivity.m`, `sensitivity/plot_sensitivity_figure.m` |

## Data

- Power network: IEEE 118-bus case from MATPOWER (`case118`), load and line capacities scaled 20-fold.
- Hourly wind, solar and electricity price series and the three-year initial history are generated by `data_loader/load_initial_history.m` with fixed random seeds.
- Demand shares, prices and investment costs are listed in `init_parameters.m` and in Supplementary Tables 1 and 2 of the paper.
- Map figures: the submitted figures use the Tianditu standard map (approval No. GS(2024)0650), which is not redistributed here. Download the provincial GeoJSON from https://cloudcenter.tianditu.gov.cn/administrativeDivision and save it as `map_data/中国_省.geojson`; otherwise the code falls back to the simplified Apache ECharts outline included in `map_data/` (Apache-2.0) for preview only.

## Optional and inactive modules

Settings in `init_parameters.m` reproduce the results of the paper. Modules switched off there (for example `enable_RL_cut`, and the heuristic operating subproblems used only when `recourse_lp = false`) are retained for completeness but do not affect the reported results.

## Licence

MIT licence (see `LICENSE`). If you use this code, please cite the paper and the Zenodo archive (see `CITATION.cff`).
