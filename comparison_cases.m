function C = comparison_cases()
%% 五组单因素对比(每组只替换A/B/C之一, 其余与本文方法相同; 全部在同一8760h实际运行层评估)
%  A: SLA–SKU任务与价值体系 | B: 价值模型 | C: 规划方法
C = struct();
% S1 AHGF 时延分类异质负荷: 统一单位算力价值 + 固定工程时延门限(30 ms) + 时延不可投资
C.S1_AHGF = struct('plan_value_mode','uniform', 'plan_d_max_B',30, 'enable_route_invest',false);
% S2 PO-VFS-FBR 电力收益价值模型: 资产价值只计电力侧收益(替代购电、外送、移峰、需求响应)
C.S2_PO_VFS_FBR   = struct('value_model','power_only');
% S3 AFZ-VFS-SHAP Shapley静态分摊: 以Shapley值替代反事实边际, 不做前后递演
C.S3_AFZ_VFS_SHAP       = struct('value_model','shapley');
% S4 近视滚动规划(MRP): 逐年规划, 无长期价值推演与候选(回收闭合保留)
C.S4_MRP    = struct('enable_world_model',false);
% S5 通用世界模型(WM): 世界模型推演保留, 去掉价值学习(critic/协态锚)与学习力候选
C.S5_WM          = struct('wm_mode','no_value', 'force_step',0);
end
