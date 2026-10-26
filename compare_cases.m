function T = compare_cases()
%% 汇总本文方法与五组对比的实际运行结果 → simulation_output/comparison.csv, 并弹出对比图
root = fileparts(mfilename('fullpath'));
C = comparison_cases(); nm = [{'Proposed'}, fieldnames(C)'];
dirs = [{fullfile(root,'simulation_output')}, fullfile(root, strcat('cmp_', fieldnames(C)'))];
hdr = {'累计NPV_亿','IRR','总投资_亿','总收益_亿','亏损资产缺口_亿','Y15训练_MW','Y15推理_MW','Y15绿电_MW', ...
       'B类SLA违约率均值','C类迁移率均值','弃风弃光率均值','绿电利用率均值','Benders平均gap'};
T = nan(numel(nm), numel(hdr)); ok = false(1, numel(nm));
for k = 1:numel(nm)
    f = fullfile(dirs{k}, 'summary.csv'); if ~exist(f,'file'); continue; end
    S = readmatrix(f, 'NumHeaderLines', 1); if isempty(S); continue; end
    gap_ = NaN; if size(S,2) >= 27; gap_ = mean(S(:,27), 'omitnan'); end
    T(k,:) = [S(end,13), S(end,15), sum(S(:,7)), sum(S(:,8)), loss_gap(dirs{k}), S(end,2), S(end,3), S(end,4), ...
              mean(S(:,20),'omitnan'), mean(S(:,21),'omitnan'), mean(S(:,25),'omitnan'), mean(S(:,22),'omitnan'), gap_];
    ok(k) = true;
end
od = fullfile(root,'simulation_output'); if ~exist(od,'dir'); mkdir(od); end
fid = fopen(fullfile(od,'comparison.csv'),'w');
fprintf(fid, '方案,%s\n', strjoin(hdr, ','));
for k = 1:numel(nm)
    fprintf(fid, '%s,%s\n', nm{k}, strjoin(arrayfun(@(v) sprintf('%.4g', v), T(k,:), 'Uni', 0), ','));
end
fclose(fid);
fprintf('\n[对比汇总] 已完成: %s\n', strjoin(nm(ok), ', '));
if any(~ok); fprintf('[对比汇总] 未完成: %s\n', strjoin(nm(~ok), ', ')); end
for k = find(ok)
    fprintf('  %-18s NPV=%8.1f亿  投资=%8.1f亿  缺口=%7.1f亿  训练=%6.0fMW  B违约=%.3f\n', nm{k}, T(k,1), T(k,3), T(k,5), T(k,6), T(k,9));
end
% 对比图(自动弹出)
if sum(ok) >= 2
    f = figure('Color','w','Name','Comparison','NumberTitle','off','Units','centimeters','Position',[2 2 18 7]);
    t = tiledlayout(f, 1, 3, 'TileSpacing','compact','Padding','compact');
    lab = categorical(nm(ok), nm(ok));
    ax = nexttile(t); bar(ax, lab, T(ok,1), 0.6); ylabel(ax,'Cumulative NPV (10^8 CNY)'); title(ax,'a','HorizontalAlignment','left');
    ax = nexttile(t); bar(ax, lab, T(ok,5), 0.6); ylabel(ax,'Loss-asset gap (10^8 CNY)'); title(ax,'b','HorizontalAlignment','left');
    ax = nexttile(t); bar(ax, lab, [T(ok,9) T(ok,11)], 0.8); ylabel(ax,'Rate'); legend(ax,{'B-class SLA violation','Curtailment'},'Box','off');
    title(ax,'c','HorizontalAlignment','left');
    fd = fullfile(od,'paper_figs'); if ~exist(fd,'dir'); mkdir(fd); end
    try; exportgraphics(f, fullfile(fd,'Fig12_comparison.png'), 'Resolution', 600); exportgraphics(f, fullfile(fd,'Fig12_comparison.pdf'), 'ContentType','vector'); catch; end
end
end

function g = loss_gap(d)
g = NaN; f = fullfile(d, 'asset_recovery.csv'); if ~exist(f,'file'); return; end
try
    R = readcell(f);
    for r = 2:size(R,1)
        if startsWith(string(R{r,1}), 'NPV')
            v = cellfun(@(x) str2double(string(x)), R(r,2:min(8,size(R,2)))); g = -sum(v(v < 0)); return;
        end
    end
catch
end
end
