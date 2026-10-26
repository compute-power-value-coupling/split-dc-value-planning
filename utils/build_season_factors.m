function S = build_season_factors(hist_data, P)
%% 由历史8760h序列提取逐月季节因子(风光出力、东西部电价), 供规划运行模型的12个月代表周使用
%  因子 = 该月均值 / 全年均值(按节点), 只改变季节形状, 不改变年均水平
NI = P.N_west; NJ = P.N_east;
dm = [31 28 31 30 31 30 31 31 30 31 30 31];
H = size(hist_data.cf_wind, 1); hoy = mod((0:H-1)', 8760);
edges = [0 cumsum(dm)*24]; mon = zeros(H,1);
for m = 1:12; mon(hoy >= edges(m) & hoy < edges(m+1)) = m; end
cr = (hist_data.cf_wind + hist_data.cf_pv) / 2;
S = struct('days', dm, 'cf', ones(12,NI), 'pw', ones(12,NI), 'pe', ones(12,NJ), 'dem', ones(12,1));
for m = 1:12
    k = mon == m; if ~any(k); continue; end
    S.cf(m,:) = mean(cr(k,:),1) ./ max(1e-6, mean(cr,1));
    if isfield(hist_data,'price') && size(hist_data.price,2) >= NI+NJ
        S.pw(m,:) = mean(hist_data.price(k,1:NI),1)       ./ max(1e-6, mean(hist_data.price(:,1:NI),1));
        S.pe(m,:) = mean(hist_data.price(k,NI+1:NI+NJ),1) ./ max(1e-6, mean(hist_data.price(:,NI+1:NI+NJ),1));
    end
end
fprintf('[季节因子] 风光出力逐月范围 %.2f–%.2f | 西部电价 %.2f–%.2f | 东部电价 %.2f–%.2f (相对年均)\n', ...
    min(S.cf(:)), max(S.cf(:)), min(S.pw(:)), max(S.pw(:)), min(S.pe(:)), max(S.pe(:)));
end
