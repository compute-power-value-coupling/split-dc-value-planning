function generate_all_figures(results_yearly, P)
%% 高级图型仿真出图(v7): 7张单轴高密度图, 无子图
% 图1全景复合柱线 | 图2利润瀑布 | 图3负荷×周×年3D曲面 | 图4利用率小提琴/豆荚
% 图5电价年度箱线 | 图6西部能量桑基 | 图7 HVDC走廊和弦
out = P.out_dir; if ~exist(out,'dir'); mkdir(out); end
S = fig_style();  % 统一期刊样式
set(groot,'defaultAxesFontName',S.font,'defaultTextFontName',S.font);
NY = P.N_year; NI = P.N_west; NJ = P.N_east; yrs = 1:NY;
CN = {'NM','GS','NX','GZ'}; CE = {'BJ','SH','GZh'};
col = S.C(1:4,:);

% ── 通用数据抽取(防御式) ─────────────────────────────────────────────
WT=zeros(NY,NI); WI=zeros(NY,1); G=zeros(NY,NI); pen=nan(NY,1);
for y=1:NY
    R=results_yearly{y}; if isempty(R); continue; end
    WT(y,:)=R.state.W_T_cum(1:NI)'; G(y,:)=R.state.G_cum(1:NI)';
    WI(y)=sum(R.state.W_I_cum);
    if isfield(R,'actual')&&isfield(R.actual,'mode')
        pen(y)=mean(R.actual.mode(:)==1)*100;   % 弃电模式≈绿电主导占比
    end
end
% 真实算力需求(从各年demand_y峰值提取, 消除硬编码)
demand = nan(1,NY);
for y=1:NY
    R=results_yearly{y};
    if ~isempty(R)&&isfield(R,'demand_y')
        demand(y)=max(R.demand_y(:))/1e3;   % MW→GW峰值(demand_y为4×T矩阵)
    end
end
if all(isnan(demand)); demand=(sum(WT,2)+WI)'/1e3; end  % 兜底:用总容量

%% ══ 图1 15年规划全景(复合柱线双轴, 单轴高密度) ══════════════════════
f=figure('Units','centimeters','Position',[1 1 20 12],'Color','w');
ax=axes(f); hold(ax,'on');
hb=bar(yrs, WT/1e3, 0.55,'stacked','EdgeColor','none');
for i=1:min(NI,4); hb(i).FaceColor=col(i,:); end
bar(yrs, WI/1e3, 0.18,'FaceColor',[.55 .35 .62],'FaceAlpha',.55,'EdgeColor','none');
plot(yrs, sum(G,2)/1e3,'--d','Color',[.2 .45 .28],'LineWidth',1.8,'MarkerFaceColor',[.2 .45 .28],'MarkerSize',5);
for y=[1 8 NY]
    tot=sum(WT(y,:)); if tot>0
        pct=WT(y,:)/tot*100;
        text(y,tot/1e3+0.12,sprintf('%.0f/%.0f/%.0f/%.0f%%',pct),'HorizontalAlignment','center','FontSize',7.5,'FontWeight','bold');
    end
end
ylabel('Capacity / Green (GW)'); xlabel('Planning Year');
yyaxis(ax,'right'); ax.YColor=[.8 .25 .25];
plot(yrs,demand,'-o','Color',[.8 .25 .25],'LineWidth',2.2,'MarkerFaceColor',[.8 .25 .25],'MarkerSize',5);
plot(yrs,pen,'-^','Color',[.15 .6 .55],'LineWidth',1.8,'MarkerFaceColor',[.15 .6 .55],'MarkerSize',5);
ylabel('Demand (GW) / Green-dominant (%)');
legend([{'Train-NM','Train-GS','Train-NX','Train-GZ'},{'Infer W_I','Green Cap','Demand','Green-dom%'}], ...
    'Location','northwest','NumColumns',2,'FontSize',8.5);
title('15-Year Compute-Power Co-Planning Panorama'); grid on; ax.GridAlpha=.15; ax.XTick=yrs;
add_fignum(gca,S,'Fig 1'); saveas_dual(f, fullfile(out,'fig1_panorama'));

%% ══ 图2 Y15年度利润瀑布(收益正项+成本负项→净利, 全财务分解一图) ══════
R15=results_yearly{NY};
if ~isempty(R15)&&isfield(R15,'actual')&&isfield(R15.actual,'rev_parts')
    rp=R15.actual.rev_parts; cp=R15.actual.cost_parts;
    labs={'Train-W','Infer-E','FlexDR','Migr','VPP','B-cross','Elec-W','Elec-E','O&M','Var','Stor','X-net','Net'};
    rb=0; if isfield(rp,'b_offload'); rb=rp.b_offload; end
    xn=0; for ff={'mig_comm','mig_energy','boff_energy','boff_comm'}
        if isfield(cp,ff{1}); xn=xn+cp.(ff{1}); end; end   % 跨网成本(迁移/B跨域的通信与购电)
    vals=[rp.west rp.east rp.flex rp.migration rp.vpp rb ...
          -cp.west -cp.east -cp.om -cp.variable -cp.stor -xn]/1e4;   % 亿元(与cost_total口径一致)
    net=sum(vals); vals=[vals net];
    f=figure('Units','centimeters','Position',[1 1 20 11],'Color','w');
    ax=axes(f); hold(ax,'on'); run=0;
    for k=1:numel(vals)
        v=vals(k);
        if k==numel(vals)
            patch([k-.35 k+.35 k+.35 k-.35],[0 0 v v],[.25 .35 .6],'EdgeColor','k');
        else
            c=[.30 .62 .40]; if v<0; c=[.82 .32 .30]; end
            patch([k-.35 k+.35 k+.35 k-.35],[run run run+v run+v],c,'EdgeColor','none');
            plot([k+.35 k+1-.35],[run+v run+v],'k:','LineWidth',.8);
            run=run+v;
        end
        text(k, max(run,v)+range(vals)*0.02, sprintf('%+.0f',v),'HorizontalAlignment','center','FontSize',8);
    end
    set(ax,'XTick',1:numel(labs),'XTickLabel',labs,'XTickLabelRotation',28);
    ylabel('100M CNY'); grid on; ax.GridAlpha=.15;
    title(sprintf('Y%d 年度利润瀑布分解  (营业利润率 %.0f%%)',NY,net/sum(vals(vals>0&(1:numel(vals))<11))*100));
    add_fignum(gca,S,'Fig 2'); saveas_dual(f, fullfile(out,'fig2_waterfall'));
end

% [图3已精简: 3D曲面读数困难,周形态由图8典型周运行承载]

%% ══ 图4 各节点训练利用率分布 小提琴/豆荚图(三模式双峰指纹) ═══════════
f=figure('Units','centimeters','Position',[1 1 18 11],'Color','w');
ax=axes(f); hold(ax,'on'); drew=false;
for i=1:NI
    R=results_yearly{NY};
    if isempty(R)||~isfield(R,'actual')||~isfield(R.actual,'P_train'); break; end
    Wi=R.state.W_T_cum(i); if Wi<1; continue; end
    u=R.actual.P_train(:,i)/Wi; u=u(u>=0&u<=1.2); if numel(u)<50; continue; end
    u=u(1:max(1,floor(numel(u)/2000)):end);
    [fd,xd]=ksdensity(u,'Bandwidth',0.03);
    fd=fd/max(fd)*0.32;
    patch([i-fd, fliplr(i+fd)], [xd, fliplr(xd)], col(i,:),'FaceAlpha',.55,'EdgeColor',col(i,:)*.7);
    plot([i-.30 i+.30],[median(u) median(u)],'k-','LineWidth',2);
    plot(i+0.36*(rand(min(120,numel(u)),1)-.5), u(randperm(numel(u),min(120,numel(u)))), ...
        '.','Color',col(i,:)*.6,'MarkerSize',3);   % 豆荚散点
    drew=true;
end
if drew
    set(ax,'XTick',1:NI,'XTickLabel',CN(1:NI)); ylim([0 1.1]);
    ylabel('Utilization P_{train}/W_T'); grid on; ax.GridAlpha=.15;
    yline(1.0,'--','Cap limit','FontSize',8); 
    title('Node Training Utilization (violin: bimodal = 3-mode signature)');
    add_fignum(gca,S,'Fig 4'); saveas_dual(f, fullfile(out,'fig4_violin'));
else; close(f); end

%% ══ 图5 逐年电价分布箱线(15箱同轴, 尖峰离群=稀缺定价证据) ════════════
PB=cell(NY,1); hasP=false;
for y=1:NY
    R=results_yearly{y};
    if ~isempty(R)&&isfield(R,'actual')&&isfield(R.actual,'price')
        pw=R.actual.price(:,1:NI); PB{y}=pw(:); hasP=true;
    end
end
if hasP
    f=figure('Units','centimeters','Position',[1 1 20 10],'Color','w');
    ax=axes(f); hold(ax,'on');
    mu_y=nan(NY,1);
    for y=1:NY
        d=PB{y}; if isempty(d); continue; end
        d=d(1:max(1,floor(numel(d)/4000)):end);
        q=quantile(d,[.05 .25 .5 .75 .95]); mu_y(y)=mean(d);
        patch(y+[-.28 .28 .28 -.28],[q(2) q(2) q(4) q(4)],[.35 .55 .8],'FaceAlpha',.6,'EdgeColor',[.2 .3 .5]);
        plot(y+[-.28 .28],[q(3) q(3)],'k-','LineWidth',1.6);
        plot([y y],[q(1) q(2)],'k-'); plot([y y],[q(4) q(5)],'k-');
        ol=d(d>q(5)); if ~isempty(ol)
            plot(y*ones(min(30,numel(ol)),1), ol(1:min(30,numel(ol))),'r.','MarkerSize',4);
        end
    end
    plot(yrs,mu_y,'-o','Color',[.85 .45 .1],'LineWidth',1.8,'MarkerFaceColor',[.85 .45 .1],'MarkerSize',4);
    xlabel('Planning Year'); ylabel('West Price (CNY/MWh)'); set(ax,'XTick',yrs); grid on; ax.GridAlpha=.15;
    title('Annual Price Boxplot (red=scarcity spikes trigger load-reduction/VPP)');
    add_fignum(gca,S,'Fig 5'); saveas_dual(f, fullfile(out,'fig5_boxplot'));
end

%% ══ 图6 Y15西部能量桑基(来源→去向, 精确成对流量) ═════════════════════
R15=results_yearly{NY};
if ~isempty(R15)&&isfield(R15,'actual')&&isfield(R15.actual,'P_renew')
    A=R15.actual;
    Fr=[sum(A.P_renew(:)), sum(A.P_ch(:)), sum(A.P_curt(:))]/1e6;  % 绿电→训练/储/弃 TWh
    Fg=sum(A.P_grid(:))/1e6;  Fd=sum(A.P_dis(:))/1e6;
    src={'绿电出力','电网购电','储能放电'}; dst={'训练负荷','储能充电','弃电'};
    sv=[sum(Fr) Fg Fd]; dv=[Fr(1)+Fg+Fd, Fr(2), Fr(3)];
    links=[1 1 Fr(1); 1 2 Fr(2); 1 3 Fr(3); 2 1 Fg; 3 1 Fd];
    f=figure('Units','centimeters','Position',[1 1 20 11],'Color','w');
    ax=axes(f); hold(ax,'off'); axis(ax,'off'); hold(ax,'on');
    cs=[.30 .62 .40; .82 .42 .30; .45 .45 .75];
    y0=0; sy=zeros(3,2); tot=sum(sv);
    for k=1:3; h=sv(k)/tot*0.9; sy(k,:)=[y0 y0+h];
        patch([0 .06 .06 0],[y0 y0 y0+h y0+h],cs(k,:),'EdgeColor','none');
        text(-.01,y0+h/2,sprintf('%s %.1fTWh',src{k},sv(k)),'HorizontalAlignment','right','FontSize',9);
        y0=y0+h+0.05; end
    y0=0; dy=zeros(3,2);
    for k=1:3; h=dv(k)/tot*0.9; dy(k,:)=[y0 y0+h];
        patch([.94 1 1 .94],[y0 y0 y0+h y0+h],[.5 .5 .5],'EdgeColor','none');
        text(1.01,y0+h/2,sprintf('%s %.1fTWh',dst{k},dv(k)),'FontSize',9);
        y0=y0+h+0.05; end
    so=sy(:,1); do_=dy(:,1);
    for L=1:size(links,1)
        s=links(L,1); d=links(L,2); w=links(L,3)/tot*0.9; if w<1e-6; continue; end
        ys=[so(s) so(s)+w]; yd=[do_(d) do_(d)+w]; so(s)=ys(2); do_(d)=yd(2);
        xx=linspace(.06,.94,50); bez=@(a,b)a+(b-a)*(3*((xx-.06)/.88).^2-2*((xx-.06)/.88).^3);
        patch([xx fliplr(xx)],[bez(ys(1),yd(1)) fliplr(bez(ys(2),yd(2)))],cs(s,:),'FaceAlpha',.45,'EdgeColor','none');
    end
    xlim([-.28 1.3]); ylim([-.02 1.02]);
    title('Y15 West Energy Flow Sankey (pairwise flows from 3-mode dispatch)');
    add_fignum(gca,S,'Fig 6'); saveas_dual(f, fullfile(out,'fig6_sankey'));
end

% [图7已精简: HVDC和弦与图9迁移和弦图型重复]

fprintf('[出图] 前7张已输出, 继续图8-15...\n');

%% ══ 图8 典型周西部运行栈叠面积(能量流+SOC+电价+三模式带, 单轴多层) ════
R=results_yearly{min(8,NY)};   % 取中期某年
if ~isempty(R)&&isfield(R,'actual')&&isfield(R.actual,'P_train')
    A=R.actual; H=min(168,size(A.P_train,1)); t=1:H;
    Ptr=sum(A.P_train(t,:),2)/1e3; Pch=sum(A.P_ch(t,:),2)/1e3;
    Pcu=sum(A.P_curt(t,:),2)/1e3;  Pgr=sum(A.P_grid(t,:),2)/1e3;
    Pre=sum(A.P_renew(t,:),2)/1e3;
    f=figure('Units','centimeters','Position',[1 1 20 12],'Color','w');
    ax=axes(f); hold(ax,'on');
    % 底层三模式色带
    md=A.mode(t,1); yl=max(Ptr+Pch)*1.15;
    % 向量化色带: 用imagesc铺一条底色带(避免168次patch卡死)
    modemap=[.92 .97 .92; .97 .93 .90; .99 .90 .90];  % 模式1/2/3底色
    mdc=md; mdc(mdc<1|mdc>3)=1;
    image('XData',[1 H],'YData',[0 yl],'CData',reshape(modemap(mdc,:),[1 H 3]),'AlphaData',0.6);
    ar=area(t,[Ptr Pch Pcu],'EdgeColor','none');
    ar(1).FaceColor=[.30 .55 .75]; ar(2).FaceColor=[.45 .70 .50]; ar(3).FaceColor=[.85 .55 .25];
    for k=1:3; ar(k).FaceAlpha=.75; end
    plot(t,Pre,'-','Color',[.15 .5 .3],'LineWidth',1.8);
    plot(t,Pgr,':','Color',[.7 .3 .3],'LineWidth',1.5);
    ylabel('Power (GW)'); xlabel('Typical Week Hour'); ylim([0 yl]);
    yyaxis(ax,'right'); ax.YColor=[.5 .3 .6];
    plot(t,A.SOC(t,1)/max(A.SOC(t,1)+eps)*100,'--','Color',[.5 .3 .6],'LineWidth',1.4);
    ylabel('Storage SOC (%)');
    legend({'Train load','Charge','Curtail','Green gen','Grid buy','SOC'},'Location','northoutside','NumColumns',4,'FontSize',8);
    title(sprintf('Y%d Typical Week West Operation (band=curtail/buy/reduce mode)',min(8,NY)));
    add_fignum(gca,S,'Fig 8'); saveas_dual(f, fullfile(out,'fig8_week_ops'));
end

%% ══ 图9 C类迁移OD和弦(东3→西4, 弦宽=年迁移量, 证明空间柔性) ══════════
OD=zeros(NJ,NI); mig15=0;
R=results_yearly{NY};
if ~isempty(R)&&isfield(R,'actual')&&isfield(R.actual,'migration_OD')
    OD=R.actual.migration_OD; mig15=sum(OD(:));
end
if mig15>1
    nn=NJ+NI; W=[sum(OD,2)' sum(OD,1)]; W=W/sum(W)*2*pi*0.9;
    gp=2*pi*0.1/nn; ang=0; a0=zeros(1,nn);
    labs=[CE(1:NJ) CN(1:NI)];
    cA=[.55 .35 .62; .5 .4 .65; .6 .45 .7; col(1:NI,:)];
    f=figure('Units','centimeters','Position',[1 1 16 15],'Color','w');
    ax=axes(f); hold(ax,'on'); axis equal off;
    for k=1:nn
        a0(k)=ang; th=linspace(ang,ang+W(k),36);
        patch([cos(th) .9*cos(fliplr(th))],[sin(th) .9*sin(fliplr(th))],cA(k,:),'EdgeColor','none');
        tm=ang+W(k)/2; text(1.08*cos(tm),1.08*sin(tm),labs{k},'HorizontalAlignment','center','FontSize',10,'FontWeight','bold');
        ang=ang+W(k)+gp;
    end
    sj=a0(1:NJ); si=a0(NJ+1:end);
    for j=1:NJ, for i=1:NI
        w=OD(j,i); if w<1; continue; end
        wj=w/sum(OD(j,:))*W(j); wi=w/sum(OD(:,i))*W(NJ+i);
        t1=[sj(j) sj(j)+wj]; t2=[si(i) si(i)+wi]; sj(j)=t1(2); si(i)=t2(2);
        tt=linspace(0,1,50);
        bz=@(p1,p2)(1-tt).^2*.9.*[cos(p1);sin(p1)]+2*(1-tt).*tt*0.04.*[cos((p1+p2)/2);sin((p1+p2)/2)]+tt.^2*.9.*[cos(p2);sin(p2)];
        c1=bz(t1(1),t2(2)); c2=bz(t1(2),t2(1));
        patch([c1(1,:) fliplr(c2(1,:))],[c1(2,:) fliplr(c2(2,:))],[.55 .4 .62],'FaceAlpha',.45,'EdgeColor','none');
    end, end
    title(sprintf('Task E->W Migration OD Chord (%.1f TWh/yr, spatial flexibility)',mig15*1e-6));
    add_fignum(gca,S,'Fig 9'); saveas_dual(f, fullfile(out,'fig9_migration_chord'));
end

%% ══ 图10 VPP削峰 电价-削峰量二维密度散点(高价触发削峰的博弈证据) ══════
allpr=[]; allvpp=[];
for y=1:NY
    R=results_yearly{y};
    if ~isempty(R)&&isfield(R,'actual')&&isfield(R.actual,'vpp_hourly')
        vp=R.actual.vpp_hourly; pr=mean(R.actual.price(:,NI+1:end),2);
        n=min(numel(vp),numel(pr)); allpr=[allpr;pr(1:n)]; allvpp=[allvpp;vp(1:n)];
    end
end
if ~isempty(allvpp)&&any(allvpp>0)
    m=find(allvpp>0.01);
    % 降采样至≤5000点(13万点散点渲染极慢)
    if numel(m)>5000; m=m(round(linspace(1,numel(m),5000))); end
    f=figure('Units','centimeters','Position',[1 1 18 11],'Color','w');
    ax=axes(f); hold(ax,'on');
    scatter(allpr(m),allvpp(m),14,allpr(m),'filled','MarkerFaceAlpha',.5); colormap(ax,S.seq);
    if numel(m)>10
        p=polyfit(allpr(m),allvpp(m),1); xx=linspace(min(allpr(m)),max(allpr(m)),50);
        plot(xx,polyval(p,xx),'k--','LineWidth',1.8);
    end
    xline(mean(allpr),':','Mean','FontSize',8);
    xlabel('East Price (CNY/MWh)'); ylabel('VPP Peak-shaving (MW-eq)');
    cb=colorbar; cb.Label.String='Price'; grid on; ax.GridAlpha=.15;
    title('VPP Peak-shaving vs Price (upper-right = high price triggers shaving)');
    add_fignum(gca,S,'Fig 10'); saveas_dual(f, fullfile(out,'fig10_vpp_scatter'));
end

%% ══ 图11 C类积压队列热力图(节点×周内小时, SLA违约区标注) ═════════════
R=results_yearly{min(10,NY)};
if ~isempty(R)&&isfield(R,'actual')&&isfield(R.actual,'B_C')
    BC=R.actual.B_C; H=min(168,size(BC,1));
    M=BC(1:H,1:NJ)'; 
    f=figure('Units','centimeters','Position',[1 1 20 8],'Color','w');
    ax=axes(f); imagesc(1:H,1:NJ,M); colormap(ax,flipud(S.seq)); set(ax,'YTick',1:NJ,'YTickLabel',CE(1:NJ));
    xlabel('Typical Week Hour'); ylabel('East Node'); cb=colorbar; cb.Label.String='C-backlog (M-tok)';
    title(sprintf('Y%d C-backlog Queue Heatmap (brighter=higher backlog)',min(10,NY)));
    add_fignum(gca,S,'Fig 11'); saveas_dual(f, fullfile(out,'fig11_queue_heat'));
end

%% ══ 图12 DRO鲁棒性 AEMF模糊集真实收缩(读仿真快照,零近似) ═══════════
eps_y=nan(NY,1); rhoL=nan(NY,1); rhoU=nan(NY,1);
for y=1:NY
    R=results_yearly{y};
    if isempty(R)||~isfield(R,'ben_info')||~isfield(R.ben_info,'aemf_snap'); continue; end
    sn=R.ben_info.aemf_snap;
    eps_y(y)=sn.epsilon_1; rhoL(y)=sn.rho_L; rhoU(y)=sn.rho_U;
end
if any(~isnan(eps_y))
    vy=find(~isnan(eps_y));
    f=figure('Units','centimeters','Position',[1 1 20 11],'Color','w');
    ax=axes(f); hold(ax,'on');
    rl=rhoL(vy); ru=rhoU(vy);
    if any(~isnan(rl))
        fill([vy' fliplr(vy')],[rl' fliplr(ru')],S.C(6,:),'EdgeColor','none','FaceAlpha',.35);
        plot(vy,rl,'-','Color',S.C(1,:),'LineWidth',1.3);
        plot(vy,ru,'-','Color',S.C(1,:),'LineWidth',1.3);
    end
    plot(vy,ones(size(vy)),'k:','LineWidth',1);
    ylabel('Moment interval \rho (nominal=1)'); xlabel('Planning Year');
    yyaxis(ax,'right'); ax.YColor=S.C(3,:);
    plot(vy,eps_y(vy),'-o','Color',S.C(3,:),'LineWidth',2,'MarkerFaceColor',S.C(3,:),'MarkerSize',4);
    ylabel('Wasserstein radius \epsilon_1');
    legend({'Moment [\rho_L,\rho_U]','','','Nominal','\epsilon_1'},'Location','northeast','FontSize',S.fs_leg);
    apply_style(ax,S,'AEMF Ambiguity Set 15-yr Shrinkage (data accumulation)');
    add_fignum(gca,S,'Fig 12'); saveas_dual(f, fullfile(out,'fig12_dro_shrink'));
else
    fprintf('  [图12] 无AEMF快照(需重跑M0),跳过\n');
end

%% ══ 图13 Benders收敛轨迹(逐年UB-LB gap带, 单轴多年叠加) ═══════════════
f=figure('Units','centimeters','Position',[1 1 18 11],'Color','w');
ax=axes(f); hold(ax,'on'); cmap=parula(NY);
hly=gobjects(NY,1);
for y=1:NY
    R=results_yearly{y}; if isempty(R)||~isfield(R,'ben_info'); continue; end
    bi=R.ben_info;
    if isfield(bi,'LB_history')&&numel(bi.LB_history)>1
        lh=bi.LB_history; it=1:numel(lh);
        gp=abs(lh-lh(end))/max(1,abs(lh(end)))*100;
        hly(y)=plot(it,gp,'-','Color',cmap(y,:),'LineWidth',1.2);
    end
end
yline(1,'r--','1% tol','FontSize',8);
xlabel('Benders Iteration'); ylabel('Relative Gap (%)'); set(ax,'YScale','log'); grid on; ax.GridAlpha=.15;
sel=[1 4 8 12 NY]; sel=sel(sel<=NY); ok=isgraphics(hly(sel));
if any(ok); legend(hly(sel(ok)), arrayfun(@(y)sprintf('Y%d',y),sel(ok),'Uni',0), ...
    'Location','northeast','FontSize',S.fs_leg); end
title('SAIL-BD Yearly Convergence (log gap, color=year)');
add_fignum(gca,S,'Fig 13'); saveas_dual(f, fullfile(out,'fig13_convergence'));

%% ══ 图14 消融雷达(M0-M6六边形, 需消融CSV; 无则占位提示) ═════════════
abl_file=fullfile(out,'ablation_M0_M6.csv');
if exist(abl_file,'file')
    T=readmatrix(abl_file); 
    mets={'收敛轮次','绿电消纳','SLA达标','迁移率','绿电占比','净收益'};
    nm=size(T,1); ang=linspace(0,2*pi,numel(mets)+1);
    f=figure('Units','centimeters','Position',[1 1 15 15],'Color','w');
    ax=axes(f); hold(ax,'on'); axis equal off;
    for r=1:4; th=linspace(0,2*pi,100); plot(r/4*cos(th),r/4*sin(th),':','Color',[.8 .8 .8]); end
    cmap=lines(nm);
    for m=1:nm
        v=T(m,:); v=v/max(v); v=[v v(1)];
        plot(v.*cos(ang),v.*sin(ang),'-o','Color',cmap(m,:),'LineWidth',1.5,'MarkerSize',3);
    end
    for k=1:numel(mets); text(1.1*cos(ang(k)),1.1*sin(ang(k)),mets{k},'HorizontalAlignment','center','FontSize',9); end
    legend(arrayfun(@(x)sprintf('M%d',x-1),1:nm,'Uni',0),'Location','eastoutside','FontSize',8);
    title('Ablation Radar (M0 full vs M1-M6, larger area = better)');
    add_fignum(gca,S,'Fig 14'); saveas_dual(f, fullfile(out,'fig14_ablation_radar'));
else
    fprintf('  [图14] 待消融CSV(ablation_M0_M6.csv), 运行M0-M6后自动生成\n');
end

%% ══ 图15 节点价值密度分解条(电力+集群+水三维堆叠, 选址依据) ═══════════
wv=zeros(NI,3);  % [集群价值 电力价值 水价值]代理分解
if isfield(P,'kappa_cluster_west')&&isfield(P,'w_water_west')
    kap=P.kappa_cluster_west(1:NI); ww=P.w_water_west(1:NI);
    cf=(P.CF_wind_west(1:NI)+P.CF_pv_west(1:NI))/2;
    wv(:,1)=kap'/max(kap); wv(:,2)=cf'/max(cf); wv(:,3)=ww'/max(ww);
end
zsel=[1 1 1 0]; R=results_yearly{NY};
if ~isempty(R)&&isfield(R.state,'z_cum'); zsel=R.state.z_cum(1:NI)'; end
f=figure('Units','centimeters','Position',[1 1 16 11],'Color','w');
ax=axes(f); hold(ax,'on');
hb=bar(1:NI, wv, 0.6,'stacked','EdgeColor','none');
hb(1).FaceColor=[.30 .45 .70]; hb(2).FaceColor=[.30 .62 .40]; hb(3).FaceColor=[.35 .60 .75];
for i=1:NI
    if zsel(i)>0.5; text(i,sum(wv(i,:))+0.05,'Sel','HorizontalAlignment','center','FontSize',9,'Color',[.1 .5 .1],'FontWeight','bold');
    else; text(i,sum(wv(i,:))+0.05,'Excl','HorizontalAlignment','center','FontSize',9,'Color',[.6 .1 .1],'FontWeight','bold'); end
end
set(ax,'XTick',1:NI,'XTickLabel',CN(1:NI)); ylabel('Normalized Value Density');
legend({'Cluster','Power(CF)','Water'},'Location','northeast','FontSize',8.5);
title('Node Endowment Decomposition & Siting (z from simulation)');
add_fignum(gca,S,'Fig 15'); saveas_dual(f, fullfile(out,'fig15_value_decomp'));

fprintf('[出图] 全部15张高级单轴图已输出至 %s\n', out);
end

function saveas_dual(fig, base)
set(fig,'PaperPositionMode','auto');
drawnow limitrate;   % 限速刷新, 避免复杂patch图渲染卡顿
% 默认只导PNG(300dpi, 快且稳); 复杂patch图(和弦/桑基)的矢量导出易卡, 故设可选
try
    exportgraphics(fig, [base '.png'], 'Resolution', 300);
catch
    try; print(fig,'-dpng','-r300',[base '.png']); catch ME
        fprintf('  [出图警告] %s: %s\n', base, ME.message); end
end
% 矢量PDF: 全局开关P_export_pdf控制(默认关,需要投稿矢量图时在主程序设true)
global FIG_EXPORT_PDF
if ~isempty(FIG_EXPORT_PDF) && FIG_EXPORT_PDF
    try; exportgraphics(fig, [base '.pdf'], 'ContentType', 'vector'); catch; end
end
end

function add_fignum(ax, S, num)
% 图号角标(右上白底), axis off的图跳过边框
try
    text(ax,0.98,0.97,num,'Units','normalized','HorizontalAlignment','right', ...
        'VerticalAlignment','top','FontName',S.fontCJK,'FontSize',9.5,'FontWeight','bold', ...
        'BackgroundColor','w','Margin',1.5,'EdgeColor',[.7 .7 .7]);
catch; end
end
