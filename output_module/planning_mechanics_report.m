function planning_mechanics_report(wmb, A, P)
%% 规划力学与世界模型的期末报告(创新点三证据 + 创新点二反事实补强)
%  ① 逐年可证伪检验汇总: 力—饱和律 vs 世界模型critic 对下一年学习力的预测误差、符号一致率、
%     主导资产(瓶颈)命中率
%  ② 力平衡容量 K*(ρ=0)
%  ③ 前瞻价值VoF逐年序列: 按前瞻计划 vs 按冻结状态(近视)计划, 在同一世界模型中的价值差
%  ④ 反事实边际 vs 平均归因: 由扰动样本得到的系统边际价值与FBR平均单位价值对比,
%     并据此后向递推反事实协态 Λ_cf
outd = 'simulation_output'; if isfield(P,'out_dir'); outd = P.out_dir; end
if ~exist(outd,'dir'); mkdir(outd); end
names = {'训练','推理','绿电','西储','东储','HVDC','通信'};
fprintf('\n╔════════ 规划力学与价值引导世界模型(创新点三) ════════╗\n');
if ~isempty(wmb.eval)
    E = wmb.eval;
    fprintf('可证伪检验 %d 年: MAE 定律%.2f / 世界模型%.2f | 符号一致 %.0f%% / %.0f%% | 主导命中 %d/%d / %d/%d\n', ...
        size(E,1), mean(E(:,2),'omitnan'), mean(E(:,3),'omitnan'), 100*mean(E(:,4),'omitnan'), ...
        100*mean(E(:,5),'omitnan'), sum(E(:,6)), size(E,1), sum(E(:,7)), size(E,1));
    fid = fopen(fullfile(outd,'planning_mechanics.csv'),'w');
    if size(E,2) < 10; E(:,end+1:10) = NaN; end
    fprintf(fid,'年份,MAE_差分律,MAE_世界模型rho,符号一致_定律,符号一致_世界模型,主导命中_定律,主导命中_世界模型,MAE_持平基线,MAE_世界模型收益率,MAE_收益率持平\n');
    for i = 1:size(E,1); fprintf(fid,'Y%d,%.4f,%.4f,%.3f,%.3f,%d,%d,%.4f,%.5f,%.5f\n', E(i,1:10)); end
    sk1 = 1 - mean(E(:,2),'omitnan')/max(1e-12, mean(E(:,8),'omitnan'));
    sk2 = 1 - mean(E(:,9),'omitnan')/max(1e-12, mean(E(:,10),'omitnan'));
    fprintf('  预测技巧分(1-MAE/持平MAE, >0才有预测力): 差分律 %.2f | 世界模型收益率 %.2f\n', sk1, sk2);
    fclose(fid);
else
    fprintf('可证伪检验: 样本年份不足\n');
end
if isfield(wmb,'law') && ~isempty(wmb.law)
    Lw = wmb.law;
    for a = 1:7
        if isfinite(Lw.beta(a))
            ks = '—'; if isfinite(Lw.Keq(a)); ks = sprintf('%.0f', Lw.Keq(a)); end
            gg = 0; if isfield(Lw,'gamma'); gg = Lw.gamma(a); end
            fprintf('  差分力学律 %-4s Δρ = %+.2f·Δs %+.2f·ΔlnD | 力平衡容量K*=%s\n', names{a}, Lw.beta(a), gg, ks);
        end
    end
end
if isfield(wmb,'log') && ~isempty(wmb.log)
    vv = wmb.log(:,4); yy = find(isfinite(vv));
    if ~isempty(yy)
        fprintf('前瞻价值VoF(亿元): %s\n', strjoin(arrayfun(@(y) sprintf('Y%d:%.1f', y, vv(y)), yy', 'Uni',0), ' '));
    end
end
% ── 反事实边际 vs 平均归因 ─────────────────────────────────────────────
if isfield(wmb,'cf') && any(isfinite(wmb.cf(:)))
    NY = size(A.REV,1); r = A.r; b = 1/(1+r); c = A.c_unit(:)'; L = A.life(:)';
    F = A.REV - A.OPEX; m_avg = zeros(NY,7);
    for a = 1:7; k = A.K(:,a) > 1e-6; m_avg(k,a) = F(k,a) ./ A.K(k,a); end
    m_cf = wmb.cf(1:NY,:); m_cf(~isfinite(m_cf)) = m_avg(~isfinite(m_cf));
    Lam_avg = zeros(1,7); Lam_cf = zeros(1,7);
    for a = 1:7
        for t = 0:L(a)-1
            y = min(NY, 1 + t);                                   % Y1投运单位, 超出期末按末年平稳
            Lam_avg(a) = Lam_avg(a) + b^t * m_avg(y,a);
            Lam_cf(a)  = Lam_cf(a)  + b^t * m_cf(y,a);
        end
    end
    fid = fopen(fullfile(outd,'counterfactual_marginal.csv'),'w');
    fprintf(fid,'年份,资产,平均归因单位价值_万元,反事实边际价值_万元\n');
    for y = 1:NY
        for a = 1:7
            if isfinite(wmb.cf(y,a))
                fprintf(fid,'Y%d,%s,%.3f,%.3f\n', y, names{a}, m_avg(y,a), wmb.cf(y,a));
            end
        end
    end
    fclose(fid);
    fprintf('Y1投运单位资产生命周期价值/投资(平均归因 vs 反事实边际):\n');
    for a = 1:7
        if any(A.K(:,a) > 1e-6)
            fprintf('  %-4s  Λ/c 平均=%.2f  反事实=%.2f\n', names{a}, Lam_avg(a)/c(a), Lam_cf(a)/c(a));
        end
    end
end
% ── 规划力学第一定律: 投资速度 ∝ 边际学习力(过阻尼梯度流) ────────────────
if isfield(wmb,'invlaw') && size(wmb.invlaw,1) >= 5
    IL = wmb.invlaw; fr = IL(:,3); vv = IL(:,4);
    rs = spearman_(fr, vv);
    sg = mean((fr > 0 & vv > 0.01) | (fr <= 0 & vv <= 0.01));
    pz = fr > 0; kap = NaN; if sum(pz) >= 3; kap = (fr(pz)'*vv(pz)) / max(1e-12, fr(pz)'*fr(pz)); end
    fprintf('投资—学习力定律: Spearman=%.2f | 方向一致%.0f%% | 速度系数κ=%.3f(v=κ·ρ, ρ>0) | 样本%d\n', ...
        rs, 100*sg, kap, numel(fr));
    if size(IL,2) >= 5                                   % 超额速度 = 投资速度 − 需求增速
        ve = vv - IL(:,5); rse = spearman_(fr, ve);
        sge = mean((fr > 0 & ve > 0) | (fr <= 0 & ve <= 0));
        fprintf('  超额速度(扣除需求增长): Spearman=%.2f | 方向一致%.0f%%\n', rse, 100*sge);
        blk = fr > 0.5 & vv <= 0.01;
        if any(blk)
            fprintf('  约束性瓶颈: %d个"强正力但零投资"样本(资产%s) → 投资受约束而非价值限制\n', ...
                sum(blk), strjoin(unique(names(IL(blk,2))), '/'));
        end
    end
    fid = fopen(fullfile(outd,'investment_force_law.csv'),'w');
    fprintf(fid,'年份,资产,上年边际学习力,本年投资速度\n');
    for i = 1:size(IL,1); fprintf(fid,'Y%d,%s,%.4f,%.4f\n', IL(i,1), names{IL(i,2)}, IL(i,3), IL(i,4)); end
    fclose(fid);
end
% ── 力平衡残差: 锁定方案处各自愿投资资产的边际学习力(局部最优性诊断) ──────
% 若规划已达局部最优, 未受约束的自愿投资资产应满足 ρ≤0(再投资一单位不再划算);
% ρ显著>0说明仍有可改进的投资方向, 或该资产被约束锁定(对照"约束性瓶颈")
if isfield(wmb,'cf') && any(isfinite(wmb.cf(:)))
    r_ = A.r; b_ = 1/(1+r_); Lv = A.life(:)'; cu = A.c_unit(:)';
    AFv = arrayfun(@(x) sum(b_.^(0:x-1)), Lv);
    Rm = wmb.cf .* AFv ./ cu - 1; vol = [1 3 6 7];
    res = nan(size(Rm,1),1);
    for y = 1:size(Rm,1)
        v = Rm(y, vol); v = v(isfinite(v)); if ~isempty(v); res(y) = max(0, max(v)); end
    end
    yy = find(isfinite(res))';
    if ~isempty(yy)
        fprintf('力平衡残差(自愿投资资产最大正学习力, 0为局部最优): %s\n', ...
            strjoin(arrayfun(@(y) sprintf('Y%d:%.2f', y, res(y)), yy, 'Uni', 0), ' '));
        fprintf('  残差<0.2的年份 %d/%d\n', sum(res(yy) < 0.2), numel(yy));
    end
end
% ── 价值规划工具的决策检验: 候选动作经真实子问题评估 ─────────────────
if isfield(wmb,'cand_eval') && iscell(wmb.cand_eval)
    fs = []; t1 = []; gain = 0; src = zeros(1,5);
    for y = 1:numel(wmb.cand_eval)
        E = wmb.cand_eval{y};
        if isempty(E) || size(E,1) < 2; continue; end
        ok = all(isfinite(E),1);
        if sum(ok) >= 3
            fs(end+1) = spearman_(E(1,ok)', -E(2,ok)'); %#ok<AGROW>
            [~, a1] = max(E(1,ok)); [~, b1] = min(E(2,ok)); t1(end+1) = (a1 == b1); %#ok<AGROW>
        end
        s = wmb.cand_src(y); src(s+1) = src(s+1) + 1;
        if s > 0; gain = gain + (E(2,end) - E(2,s)) / 1e4; end
    end
    if ~isempty(fs)
        fprintf('决策一致性(世界模型对候选的排序 vs 真实子问题): 平均Spearman=%.2f | 最优动作一致%d/%d年\n', ...
            mean(fs,'omitnan'), sum(t1), numel(t1));
    end
    fa = []; ta = []; fp = [];
    for y = 1:numel(wmb.cand_eval)
        E = wmb.cand_eval{y}; if isempty(E) || size(E,1) < 3; continue; end
        ok = all(isfinite(E([1 3],:)),1);
        if sum(ok) >= 3
            fa(end+1) = spearman_(E(1,ok)', -E(3,ok)'); %#ok<AGROW>
            [~, a1] = max(E(1,ok)); [~, b1] = min(E(3,ok)); ta(end+1) = (a1 == b1); %#ok<AGROW>
        end
        ok2 = all(isfinite(E([2 3],:)),1);
        if sum(ok2) >= 3; fp(end+1) = spearman_(-E(2,ok2)', -E(3,ok2)'); end %#ok<AGROW>
    end
    if ~isempty(fa)
        fprintf('决策一致性(世界模型 vs 8760h实际运行): 平均Spearman=%.2f | 最优动作一致%d/%d年\n', mean(fa,'omitnan'), sum(ta), numel(ta));
    end
    if ~isempty(fp)
        fprintf('规划子问题自身一致性(规划UB排序 vs 实际运行): 平均Spearman=%.2f\n', mean(fp,'omitnan'));
    end
    fprintf('候选采纳来源: 世界模型%d | 近视%d | 力流(规划力学)%d | 零扩容%d | 未采纳%d | 累计UB改善%.1f亿\n', ...
        src(2), src(3), src(4), src(5), src(1), gain);
end
% ── 世界模型候选注入效果 ─────────────────────────────────────────────
if isfield(wmb,'cand') && any(isfinite(wmb.cand(:,1)))
    C = wmb.cand; v = isfinite(C(:,1));
    na_ = sum(C(v,3) > 0.5);
    if na_ > 0
        fprintf('世界模型候选: 评估%d年, 被采纳%d年, 采纳年UB平均改善%.1f亿\n', sum(v), na_, ...
            mean((C(v & C(:,3) > 0.5, 2) - C(v & C(:,3) > 0.5, 1))/1e4, 'omitnan'));
    else
        fprintf('世界模型候选: 评估%d年, 未被采纳\n', sum(v));
    end
end
fprintf('输出: planning_mechanics.csv / investment_force_law.csv / counterfactual_marginal.csv / wm/fig_wm_Yxx.png\n');
fprintf('╚══════════════════════════════════════════════════════╝\n');
end

function s = ifelse_(c, a, b)
if c; s = a; else; s = b; end
end

function r = spearman_(x, y)
[~, ix] = sort(x); rx = zeros(size(x)); rx(ix) = 1:numel(x);
[~, iy] = sort(y); ry = zeros(size(y)); ry(iy) = 1:numel(y);
C = corrcoef(rx, ry); r = C(1,2);
end
