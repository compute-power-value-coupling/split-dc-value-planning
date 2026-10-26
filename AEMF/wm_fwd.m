function Y = wm_fwd(p, X)
%% 两隐层tanh前向(双精度与dlarray通用)
if isfield(p,'rff') && p.rff
    Y = p.B * [tanh(p.Wr*X + p.br); ones(1,size(X,2))];
    return;
end
H1 = tanh(p.W1*X + p.b1);
H2 = tanh(p.W2*H1 + p.b2);
Y  = p.W3*H2 + p.b3;
end
