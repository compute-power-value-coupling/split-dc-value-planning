function SP = sens_params(mode)
%% 敏感性分析参数与扰动水平(各入口函数共用)
%  mode = 'expost'(默认): 规划方案不变, 在已有15年规划与8760h运行结果上重新核算经济性, 不重跑仿真
%  mode = 'replan'      : 参数进入规划模型, 各方案重新完成15年规划(需重跑仿真)
%  rel=true: 水平为基准值的倍数; rel=false: 水平为绝对值
if nargin < 1 || isempty(mode); mode = 'expost'; end
SP = struct();
switch mode
    case 'expost'
        SP.disc  = struct('name', 'Discount rate', 'levels', [0.06 0.10], 'rel', false, 'base', 0.08);
        SP.stor  = struct('name', 'Storage cost',  'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
        SP.comp  = struct('name', 'Computing cost', 'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
        SP.green = struct('name', 'Green power cost', 'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
    case 'replan'
        SP.demand = struct('name', 'Demand growth', 'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
        SP.token  = struct('name', 'Token efficiency growth', 'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
        SP.stor   = struct('name', 'Storage cost',  'levels', [0.8 1.2],   'rel', true,  'base', 1.0);
        SP.disc   = struct('name', 'Discount rate', 'levels', [0.06 0.10], 'rel', false, 'base', 0.08);
    otherwise
        error('sens:mode', '未知模式: %s (可选 expost / replan)', mode);
end
end
