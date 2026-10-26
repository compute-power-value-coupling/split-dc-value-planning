function w = lz(v)
%LZ 坐标轴与色条线宽(磅), 随目标字号 FS 按平方根放大, 使轴线与放大后的文字协调
fs = 14; if isappdata(0, 'pf_fs'); fs = getappdata(0, 'pf_fs'); end
w = v * sqrt(fs / 8);
end
