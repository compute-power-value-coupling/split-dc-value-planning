function P = fig_style()
%% 期刊级统一绘图样式(所有图共用) — 英文标签,用MATLAB默认字体
P.font   = get(groot,'factoryAxesFontName');   % MATLAB默认(Helvetica/system)
P.fontCJK= P.font;
P.fs_title = 11; P.fs_lab = 9.5; P.fs_tick = 8.5; P.fs_leg = 8;
% 主调色板(低饱和,色盲友好)
P.C = [ 0.22 0.35 0.55;    % 深蓝
        0.30 0.60 0.45;    % 墨绿
        0.85 0.58 0.28;    % 赭橙
        0.55 0.42 0.62;    % 紫
        0.75 0.30 0.30;    % 砖红
        0.35 0.62 0.68 ];  % 青
P.seq = interp1([0 .5 1], [0.20 0.30 0.50; 0.90 0.85 0.55; 0.75 0.25 0.20], linspace(0,1,256));
end
