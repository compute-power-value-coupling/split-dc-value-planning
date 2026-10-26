%% =========================================================================
%  append_actual_to_history.m  —  追加实际年数据至历史集
%  
%  机制: 年末实际8760h数据(风光CF+电价+实际算力需求)纳入历史集
%        下一年AEMF基于扩充后的历史集重新构建模糊集
%% =========================================================================
function hist_data = append_actual_to_history(hist_data, actual_y, year)

% 追加风光CF(8760×NI)
hist_data.cf_wind = [hist_data.cf_wind; actual_y.cf_wind];
hist_data.cf_pv   = [hist_data.cf_pv;   actual_y.cf_pv];
hist_data.cf_renew = [hist_data.cf_renew; (actual_y.cf_wind + actual_y.cf_pv)/2];

% 追加电价(8760×NI+NJ)
hist_data.price = [hist_data.price; actual_y.price];

% 追加实际年需求(标量)
hist_data.demand_yearly(end+1, 1) = actual_y.demand_realized_peak;

end
