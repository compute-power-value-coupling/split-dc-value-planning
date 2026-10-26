function sens_install(root, pkg)
%% 检查并安装两处补丁(需求增速缩放 P.growth_scale、资产归因折现率 P.r_min)
%  工程中的文件已含补丁 → 跳过; 否则用程序包内的同名文件覆盖, 原文件备份为 *.m.bak_before_sens
%  两处补丁在未设置新字段时不改变任何已有结果
F = {fullfile('data_loader', 'load_growth_forecast.m'),          'growth_scale'; ...
     fullfile('output_module', 'compute_asset_attribution.m'),   'isfield(P, ''r_min'')'};
changed = false;
for k = 1:size(F, 1)
    dst = fullfile(root, F{k, 1}); src = fullfile(pkg, F{k, 1});
    if exist(dst, 'file') == 2 && contains(fileread(dst), F{k, 2}); continue; end
    if strcmp(src, dst) || exist(src, 'file') ~= 2
        error('sens:patch', '%s 未包含敏感性补丁, 且程序包中缺少替换文件 %s', dst, src);
    end
    if exist(dst, 'file') == 2
        bak = [dst '.bak_before_sens'];
        if exist(bak, 'file') ~= 2; copyfile(dst, bak); end
    end
    copyfile(src, dst, 'f');
    fprintf('[敏感性] 已安装补丁: %s (原文件备份为 .bak_before_sens)\n', dst);
    changed = true;
end
if changed
    clear('load_growth_forecast', 'compute_asset_attribution');
    rehash;
end
end
