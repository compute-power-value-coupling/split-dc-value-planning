%% =========================================================================
%  load_task_template.m  —  加载4类算力任务24小时时序模板
%  
%  模板含义: 相对负荷比例(0~1), 每类任务在一天24小时内的负荷形态
%    A类(实时推理): 日间双峰(9-12时上午峰, 14-22时下午晚间峰)
%    B类(弱实时): 与A同步但更平滑
%    C类(可迁移): 夜间集中(22-6时, 追逐低谷电价)
%    D类(训练): 全天稳定(0.85~1.0)
%% =========================================================================
function template = load_task_template(P)

template = zeros(4, 24);
h = 0:23;

%% A类 - 实时推理日间双峰
for t = 1:24
    hod = h(t);
    if hod >= 9 && hod <= 12
        % 上午峰
        template(1,t) = 0.7 + 0.3*sin(pi*(hod-9)/3);
    elseif hod >= 14 && hod <= 22
        % 下午晚间峰
        template(1,t) = 0.6 + 0.4*sin(pi*(hod-14)/8);
    elseif hod >= 7 && hod <= 8
        template(1,t) = 0.40;
    else
        template(1,t) = 0.17;
    end
end

%% B类 - 弱实时(与A同步但平滑)
for t = 1:24
    hod = h(t);
    if hod >= 8 && hod <= 22
        template(2,t) = 0.55 + 0.45*sin(pi*(hod-8)/14);
    else
        template(2,t) = 0.25;
    end
end

%% C类 - 可迁移夜间集中
for t = 1:24
    hod = h(t);
    if hod >= 22 || hod <= 6
        % 夜间高峰
        if hod >= 22
            phase = (hod-22)/8;
        else
            phase = (hod+2)/8;
        end
        template(3,t) = 0.70 + 0.30*sin(pi*phase);
    elseif hod >= 7 && hod <= 9
        template(3,t) = 0.35;
    else
        template(3,t) = 0.25;
    end
end

%% D类 - 训练全天稳定
template(4, :) = 0.95 + 0.05*sin(2*pi*h/24);
template(4, :) = max(0.85, min(1.0, template(4, :)));

% 归一化到[0,1]
for k = 1:4
    if max(template(k,:)) > 0
        template(k,:) = template(k,:) / max(template(k,:));
    end
end

fprintf('       任务模板: A峰=%.2f, B峰=%.2f, C峰=%.2f, D均=%.2f\n', ...
    max(template(1,:)), max(template(2,:)), max(template(3,:)), mean(template(4,:)));
end
