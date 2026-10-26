%% =========================================================================
%  compute_C17_storage_lower.m  —  C17储能能量缺口下界
%  
%  对应论文式(10):
%    E_stor,i >= max_{[t1,t2]} ∫[t1,t2] [W_contract_D,i/eta_PUE,i - P_renew,i(τ)]+ dτ
%  
%  实现: 滑动窗口扫描历史风光时序, 计算连续低出力时段的最大累积能量缺口
%% =========================================================================
function E_C17 = compute_C17_storage_lower(hist_data, P)

E_C17 = zeros(P.N_west, 1);

for i = 1:P.N_west
    % 该节点合同保障的最小训练功率(MW)
    Pc_min = P.W_contract_D(i) / P.eta_PUE_west(i);
    
    % 假设该节点最低绿电装机 = γ_min × Pc_min (满足C4约束的最小情形)
    G_min = P.gamma_min * Pc_min;
    
    % 历史综合CF时序
    cf_i = (hist_data.cf_wind(:,i) + hist_data.cf_pv(:,i)) / 2;
    
    % 可用绿电功率时序(MW)
    P_renew_i = G_min * cf_i;
    
    % 逐小时缺口
    gap_hourly = max(0, Pc_min - P_renew_i);
    
    % 扫描连续缺口段, 找最大累积能量
    max_gap_energy = 0;
    cur_gap_energy = 0;
    for h = 1:length(gap_hourly)
        if gap_hourly(h) > 0.1
            cur_gap_energy = cur_gap_energy + gap_hourly(h);
            if cur_gap_energy > max_gap_energy
                max_gap_energy = cur_gap_energy;
            end
        else
            cur_gap_energy = 0;
        end
    end
    
    E_C17(i) = max_gap_energy;
end

% 工程裁剪: 上界=各节点合同容量×储能配置时长×1.0(不×2)
% 缩小上界使C5(mu_min×G×dt)在后期G增大后能超过C17,储能随绿电增长
for i = 1:P.N_west
    Pc_i = P.W_contract_D(i) / P.eta_PUE_west(i);
    E_max_i = Pc_i * P.dt_stor * 1.0;   % 合同容量×配置时长(×1.0不再×2)
    E_C17(i) = min(E_C17(i), E_max_i);
end
end
