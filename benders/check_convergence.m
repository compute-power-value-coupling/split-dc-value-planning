%% =========================================================================
%  check_convergence.m  —  收敛与早停判定
%% =========================================================================
function [converged, early_stop] = check_convergence(LB_hist, UB_hist, gap_hist, iter, P)

converged = false;
early_stop = false;

% 主收敛: gap < tol
if gap_hist(end) < P.tol_gap
    converged = true;
    return;
end

% 早停: LB连续多轮增量小 且 gap可接受
if iter > P.early_stop_win
    LB_recent = LB_hist(end-P.early_stop_win:end);
    dLB_rate = abs(LB_recent(end) - LB_recent(1)) / max(abs(LB_recent(end)), 1);
    if dLB_rate < P.early_stop_dLB && gap_hist(end) < P.tol_gap_early
        early_stop = true;
    end
end
end
