%% =========================================================================
%  log_warning.m  —  警告日志记录
%% =========================================================================
function log_warning(msg, P)

if nargin < 2 || ~isfield(P, 'out_dir')
    out_dir = '.';
else
    out_dir = P.out_dir;
end

log_file = fullfile(out_dir, 'warnings.log');
fid = fopen(log_file, 'a');
if fid > 0
    fprintf(fid, '[%s] %s\n', datestr(now,'yyyy-mm-dd HH:MM:SS'), msg);
    fclose(fid);
end
fprintf('  [WARN] %s\n', msg);
end
