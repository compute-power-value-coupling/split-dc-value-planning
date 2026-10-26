function [root, pkg] = sens_root()
%% 定位 v8 工程根目录(含 main_15year_simulation.m)
%  本程序包可直接放在 matlab_v2/ 根目录, 也可整个文件夹放在 matlab_v2/ 下(如 matlab_v2/sensitivity/)
pkg = fileparts(mfilename('fullpath'));
cand = {pkg, fileparts(pkg)};
for k = 1:numel(cand)
    if exist(fullfile(cand{k}, 'main_15year_simulation.m'), 'file') == 2
        root = cand{k}; return;
    end
end
error('sens:root', ['未找到 main_15year_simulation.m。请把 sensitivity 文件夹放在 matlab_v2 目录下, ' ...
       '或把其中文件复制到 matlab_v2 根目录。当前程序位置: %s'], pkg);
end
