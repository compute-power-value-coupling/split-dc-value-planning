function fit_figure_text(f)
%FIT_FIGURE_TEXT 放大字号后的版面自适应, 在导出前调用
%  1) 过长的坐标轴标题与色条标题按单词均衡折行(至多三行);
%  2) 以面积最大的二维主坐标区为基准收缩其位置, 使刻度、轴标题、区外标注、图例与色条全部落在画布内;
%     其余坐标区(边缘分布、上方子轴)及手动放置的色条与图例随之等比平移缩放, 相对版式不变;
%  3) 绘制依赖最终版面的元素(setappdata(f, 'pf_after_fit', 函数句柄));
%  4) 渲染检查画布四周是否仍有内容被裁切, 若有则等比扩大画布(每次 8%, 至多 6 次)。
%  对地图、相关矩阵等手工版式, 可在作图时 setappdata(f, 'pf_nofit', true) 跳过第 2 步。
if ~isgraphics(f); return; end
drawnow;
try; wrap_labels_(f); catch; end
if ~(isappdata(f, 'pf_nofit') && getappdata(f, 'pf_nofit'))
    try; fit_main_(f); catch; end
    try; wrap_labels_(f); catch; end                             % 收缩后按新的坐标区尺寸复核折行
end
if isappdata(f, 'pf_after_fit')                                  % 依赖最终版面的元素(如气泡大小图例)在此绘制
    try; feval(getappdata(f, 'pf_after_fit')); drawnow; catch; end
end
try; grow_canvas_(f); catch; end
end

% ───────────────────────────── 1) 标题折行 ─────────────────────────────
function wrap_labels_(f)
fp = fig_pt_(f);
A = findall(f, 'Type', 'axes');
for i = 1:numel(A)
    ax = A(i); if ~strcmp(ax.Visible, 'on') || ~strcmp(ax.Units, 'normalized'); continue; end
    w = ax.Position(3) * fp(3); h = ax.Position(4) * fp(4);
    if is2d_(ax)
        wrap_text_(ax.XLabel, 1.00 * w); wrap_text_(ax.YLabel, 1.00 * h);
    else
        wrap_text_(ax.XLabel, 0.55 * w); wrap_text_(ax.YLabel, 0.55 * w); wrap_text_(ax.ZLabel, 0.85 * h);
    end
end
C = findall(f, 'Type', 'colorbar');
for i = 1:numel(C)
    cb = C(i); q = cb.Position;
    if q(4) >= q(3); len = q(4) * fp(4); else; len = q(3) * fp(3); end
    try; wrap_text_(cb.Label, 1.10 * len); catch; end
end
drawnow;
end

function wrap_text_(h, lim)
% 以原始单行文字为准重新折行(可重复调用)
if isempty(h) || ~isgraphics(h); return; end
if isappdata(h, 'pf_orig')
    s = getappdata(h, 'pf_orig'); h.String = s; drawnow;
else
    s = h.String;
    if isempty(s) || iscell(s) || (isstring(s) && numel(s) > 1); return; end
    s = char(s); if size(s, 1) > 1 || contains(s, '\newline'); return; end
    setappdata(h, 'pf_orig', s);
end
for nl = 2:3
    if text_len_(h) <= lim; return; end
    c = split_words_(s, nl); if isempty(c); return; end
    h.String = c; drawnow;
end
end

function L = text_len_(h)
u = h.Units; h.Units = 'points'; e = h.Extent; h.Units = u;
L = max(e(3), e(4));
end

function c = split_words_(s, nl)
% 按空格(不拆 TeX 花括号内)将字符串均衡分为 nl 行
d = 0; cut = [];
for i = 1:numel(s)
    if s(i) == '{'; d = d + 1; elseif s(i) == '}'; d = d - 1; elseif s(i) == ' ' && d == 0; cut(end+1) = i; end %#ok<AGROW>
end
c = {};
if numel(cut) < nl - 1; return; end
out = cell(1, nl); st = 1; n = numel(s);
for k = 1:nl-1
    cand = cut(cut > st);
    if isempty(cand); return; end
    tgt = st + (n - st + 1) / (nl - k + 1);
    [~, j] = min(abs(cand - tgt)); p = cand(j);
    out{k} = s(st:p-1); st = p + 1;
end
out{nl} = s(st:end);
if any(cellfun(@isempty, out)); return; end
c = out;
end

% ───────────────────────────── 2) 主坐标区收缩 ─────────────────────────────
function fit_main_(f)
m = 0.012;                                                       % 画布边距(归一化)
A = findall(f, 'Type', 'axes'); main = []; best = 0;
for i = 1:numel(A)
    ax = A(i);
    if ~strcmp(ax.Visible, 'on') || ~strcmp(ax.Units, 'normalized') || ~is2d_(ax); continue; end
    if isequal(ax.XColor, 'none') && isequal(ax.YColor, 'none'); continue; end
    a = ax.Position(3) * ax.Position(4); if a > best; best = a; main = ax; end
end
if isempty(main); return; end
p0 = main.Position;
for it = 1:8
    drawnow; [L, B, R, T] = bbox_(f, main);
    dl = max(0, m - L); dr = max(0, R - (1 - m)); db = max(0, m - B); dt = max(0, T - (1 - m));
    if dl + dr + db + dt < 1e-3; break; end
    p = main.Position; pn = [p(1) + dl, p(2) + db, p(3) - dl - dr, p(4) - db - dt];
    if pn(3) < 0.3 * p0(3) || pn(4) < 0.3 * p0(4); break; end
    move_all_(f, main, p, pn);
end
end

function move_all_(f, main, po, pn)
% 主坐标区 po → pn; 其余坐标区、手动色条与手动图例按同一仿射变换平移缩放
sx = pn(3) / po(3); sy = pn(4) / po(4);
tf = @(q) [pn(1) + (q(1) - po(1)) * sx, pn(2) + (q(2) - po(2)) * sy, q(3) * sx, q(4) * sy];
A = findall(f, 'Type', 'axes');
for i = 1:numel(A)
    ax = A(i); if ax == main || ~strcmp(ax.Units, 'normalized'); continue; end
    ax.Position = tf(ax.Position);
end
C = findall(f, 'Type', 'colorbar');
for i = 1:numel(C)
    cb = C(i);
    if strcmp(cb.Location, 'manual'); q = tf(cb.Position); cb.Position = [q(1), q(2), cb.Position(3), q(4)]; end
end
G = findall(f, 'Type', 'legend');
for i = 1:numel(G)
    lg = G(i);
    if strcmp(lg.Location, 'none'); q = tf(lg.Position); lg.Position(1:2) = q(1:2); end
end
main.Position = pn;
end

function [L, B, R, T] = bbox_(f, ax)
% 主坐标区及其文字、图例、色条在画布上的外包框(归一化)
fp = fig_pt_(f); W = fp(3); H = fp(4);
p = ax.Position; ti = ax.TightInset;
L = p(1) - ti(1); B = p(2) - ti(2); R = p(1) + p(3) + ti(3); T = p(2) + p(4) + ti(4);
skip = [ax.XLabel, ax.YLabel, ax.ZLabel, ax.Title];
tx = findall(ax, 'Type', 'text');
for i = 1:numel(tx)
    h = tx(i);
    if ~strcmp(h.Visible, 'on') || isempty(h.String) || any(h == skip); continue; end
    u = h.Units; h.Units = 'normalized'; e = h.Extent; h.Units = u;
    x0 = p(1) + e(1) * p(3); y0 = p(2) + e(2) * p(4);
    L = min(L, x0); B = min(B, y0); R = max(R, x0 + e(3) * p(3)); T = max(T, y0 + e(4) * p(4));
end
G = findall(f, 'Type', 'legend');
for i = 1:numel(G)
    q = G(i).Position; if ~strcmp(G(i).Visible, 'on'); continue; end
    L = min(L, q(1)); B = min(B, q(2)); R = max(R, q(1) + q(3)); T = max(T, q(2) + q(4));
end
C = findall(f, 'Type', 'colorbar');
for i = 1:numel(C)
    cb = C(i); q = cb.Position; fs = cb.FontSize;
    tl = cellstr(cb.TickLabels); nch = max([1; cellfun(@numel, tl(:))]);
    nl = 0; if ~isempty(cb.Label.String); nl = numel(cellstr(cb.Label.String)); end
    ext = 0.55 * fs * nch + 6 + 1.25 * cb.Label.FontSize * nl;          % 刻度与标题宽度估计(磅)
    if q(4) >= q(3)
        L = min(L, q(1)); R = max(R, q(1) + q(3) + ext / W);
        B = min(B, q(2) - 0.6 * fs / H); T = max(T, q(2) + q(4) + 0.6 * fs / H);
    else
        B = min(B, q(2) - ext / H); T = max(T, q(2) + q(4));
        L = min(L, q(1) - 1.2 * fs / W); R = max(R, q(1) + q(3) + 1.2 * fs / W);
    end
end
end

% ───────────────────────────── 3) 渲染检查 ─────────────────────────────
function grow_canvas_(f)
for it = 1:6
    drawnow;
    I = print(f, '-RGBImage', '-r40'); g = min(I, [], 3); b = 2;
    E = [reshape(g(1:b, :), [], 1); reshape(g(end-b+1:end, :), [], 1); reshape(g(:, 1:b), [], 1); reshape(g(:, end-b+1:end), [], 1)];
    if ~any(E < 225); return; end
    u = f.Units; f.Units = 'centimeters'; p = f.Position; f.Position = [p(1) p(2) p(3) * 1.08 p(4) * 1.08]; f.Units = u;
end
end

% ───────────────────────────── 工具 ─────────────────────────────
function fp = fig_pt_(f)
u = f.Units; f.Units = 'points'; fp = f.Position; f.Units = u;
end

function t = is2d_(ax)
[az, el] = view(ax); t = abs(el - 90) < 1e-6 && abs(mod(az, 360)) < 1e-6;
end
