function s = fz(v, nofloor)
%FZ 仿真图字号(磅)。原版式以 8 磅为基准设计, 按目标字号 FS 等比放大; 除附图小字外, 图中文字不小于 FS。
%  FS 由 plot_paper_figures / plot_comparison_figures / plot_sensitivity_figure 的字号参数设定(默认 14 磅)。
%  fz(v)        普通文字: max(v*FS/8, FS)
%  fz(v, true)  附图比例尺、审图号等小字: v*FS/8, 不设下限
fs = 14; if isappdata(0, 'pf_fs'); fs = getappdata(0, 'pf_fs'); end
s = v * fs / 8;
if nargin < 2 || ~nofloor; s = max(s, fs); end
end
