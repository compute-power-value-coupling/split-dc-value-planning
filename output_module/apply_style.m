function apply_style(ax, S, ttl, fignum)
%% 对单个axes套用统一样式
grid(ax,'on'); ax.GridAlpha=0.13; ax.GridLineStyle='-';
ax.LineWidth=0.8; ax.Box='on';
ax.FontName=S.font; ax.FontSize=S.fs_tick; ax.Layer='top';
ax.XColor=[.25 .25 .25]; if strcmp(ax.YAxisLocation,'left'); ax.YColor=[.25 .25 .25]; end
if nargin>=3 && ~isempty(ttl)
    title(ax, ttl, 'FontName',S.fontCJK,'FontSize',S.fs_title,'FontWeight','bold');
end
% 图号角标(右上,论文用)
if nargin>=4 && ~isempty(fignum)
    text(ax,0.985,0.97,fignum,'Units','normalized','HorizontalAlignment','right', ...
        'VerticalAlignment','top','FontName',S.font,'FontSize',9,'FontWeight','bold', ...
        'BackgroundColor',[1 1 1 ],'Margin',1.5,'EdgeColor',[.7 .7 .7]);
end
end
