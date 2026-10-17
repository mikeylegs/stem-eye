/*SR-BEGIN 17c STEM READER -- reads djay Pro's iPad screen (two-deck view, Neural Mix lanes) from TILES: downsampled RGB crops of
   the screen (from the iPad's broadcast extension, or a screen recording played in the SiM). Per frame: djay's beat grid (bar lines,
   bar numbers, the playhead), the stem lanes as columns, the mixer. Kept per deck: a STEM MAP of the track in beats (every column
   seen lands on its bar position, so the map stitches itself as the waveform scrolls) -> the FUTURE right of the playhead: drops /
   breaks / builds / vocals known bars ahead, on djay's own grid. Pure JS (no DOM, no Node, no backticks) -- the SAME block runs in the
   Controller and the SiM. Edit once, paste to both (tests check they are identical). */
var SR=(function(){
'use strict';
var VER='17c';

/* ======================= ATLAS: djay Pro, iPad Pro 12.9" landscape (2732 x 2048 px), two-deck view =======================
   Measured on Mike's 10-16/17 screen recordings. All x / y in full-resolution screen pixels. */
var AT={W:2732, H:2048,
  tiles:{   /* what the sensor sends: crop (x,y,w,h) shrunk by s (box average); every = send every n-th frame (1 = each frame) */
    LN:{x:722, y:266, w:1290, h:436, s:2, every:1},     /* both decks' lane blocks (the stem waveforms + djay's grid) */
    MX:{x:1036, y:860, w:660, h:920, s:2, every:1},     /* the mixer column: filter / EQ knobs, channel faders, VU */
    LOW:{x:0, y:860, w:2732, h:1188, s:4, every:2},     /* lower screen: side panels (Neural Mix faders, FX), play buttons, crossfader */
    TOP:{x:0, y:30, w:2732, h:240, s:2, every:5},       /* header: titles, keys, times left, the whole-track overview strips */
    TR:{x:0, y:700, w:2732, h:160, s:4, every:3}},      /* transport row: SYNC, BPM, the loop circles (blue = a loop is on) */
  deck:[{y0:267, y1:477}, {y0:491, y1:701}],   /* lane blocks: rows y0 .. y1-1 */
  sep:{1:[], 2:[104], 3:[69,140], 4:[51,104,158]},   /* lane separators (2 rows each), offsets from y0 */
  lanes:{1:['mix'], 2:['vocals','inst'], 3:['vocals','harmonic','drums'], 4:['vocals','harmonic','bass','drums']},
  playX:1367,   /* the red playhead line */
  laneX:[722, 2012]};

/* ---------- tiles ---------- */
/* a tile = {id, x, y, w, h, s, cw, ch, px: Uint8Array RGB (cw*ch*3)}; cw = w/s, ch = h/s */
function tileOf(id, px, spec){ var t=spec||AT.tiles[id]; return {id:id, x:t.x, y:t.y, w:t.w, h:t.h, s:t.s, cw:Math.round(t.w/t.s), ch:Math.round(t.h/t.s), px:px}; }
function program(){ var o={v:VER, W:AT.W, H:AT.H, tiles:[]}; Object.keys(AT.tiles).forEach(function(k){ var t=AT.tiles[k]; o.tiles.push({id:k, x:t.x, y:t.y, w:t.w, h:t.h, s:t.s, every:t.every}); }); return o; }
/* box-average a full-resolution RGBA (or RGB) image region into a tile (the browser sensor; the iPad does the same in Swift) */
function boxTile(id, src, sw, sh, bpp, spec){ var t=spec||AT.tiles[id], s=t.s, cw=Math.round(t.w/s), ch=Math.round(t.h/s), out=new Uint8Array(cw*ch*3), n=s*s, x, y, i, j;
  for(y=0;y<ch;y++){ for(x=0;x<cw;x++){ var r=0, g=0, b=0, sy0=t.y+y*s, sx0=t.x+x*s;
      for(j=0;j<s;j++){ var yy=sy0+j; if(yy>=sh) yy=sh-1; var row=yy*sw; for(i=0;i<s;i++){ var xx=sx0+i; if(xx>=sw) xx=sw-1; var q=(row+xx)*bpp; r+=src[q]; g+=src[q+1]; b+=src[q+2]; } }
      var o=(y*cw+x)*3; out[o]=(r+(n>>1))/n|0; out[o+1]=(g+(n>>1))/n|0; out[o+2]=(b+(n>>1))/n|0; } }
  return tileOf(id, out, t); }

/* ======================= LANES: one deck block per frame ======================= */
/* tile rows of a full-res row range */
function rowsOf(T, y0, y1){ return [Math.ceil((y0-T.y)/T.s), Math.floor((y1-T.y)/T.s)]; }
/* luminance median per row over every 3rd column (for the lane separators) */
function rowMed(T, r0, r1){ var cw=T.cw, px=T.px, out=new Float32Array(r1-r0), h=new Int32Array(256), r, x, n;
  for(r=r0;r<r1;r++){ h.fill(0); n=0; for(x=2;x<cw-2;x+=3){ var q=(r*cw+x)*3; h[(px[q]*77+px[q+1]*151+px[q+2]*28)>>8]++; n++; }
    var half=n>>1, c=0, v=0; while(v<255 && c+h[v]<=half){ c+=h[v]; v++; } out[r-r0]=v; }
  return out; }
/* lane layout: which of 1 / 2 / 3 / 4 lanes (djay 'Neural Mix Tracks'): a separator = 2 rows that differ from the rows 3 px above + below */
function laneMode(T, d){ var D=AT.deck[d], R=rowsOf(T, D.y0, D.y1), med=rowMed(T, R[0], R[1]), s=T.s;
  function sepC(off){ var y=D.y0+off, a=Math.floor((y-T.y)/s)-R[0], b=Math.floor((y+1-T.y)/s)-R[0], m=0, k=0, z;
    for(z=a;z<=b;z++){ if(z>=0 && z<med.length){ m+=med[z]; k++; } } if(!k) return 0; m/=k;
    var u=a-Math.ceil(3/s)-1, v=b+Math.ceil(3/s)+1, nb=[]; if(u>=0) nb.push(med[u]); if(v<med.length) nb.push(med[v]); if(!nb.length) return 0;
    var e=0; nb.forEach(function(q){ e+=q; }); e/=nb.length; return Math.abs(m-e)*(b>a?2:1); }   /* a separator split over 2 tile rows is half as strong in each */
  var c={}; [51,104,158,69,140].forEach(function(o){ c[o]=sepC(o); });
  var on=function(o){ return c[o]>=3.5; }, n=1;
  if(on(51) && on(104) && on(158)) n=4; else if(on(69) && on(140)) n=3; else if(on(104) && !on(51) && !on(158)) n=2;
  return {n:n, c:c}; }
/* lane interior rows (tile rows) for a layout */
function laneRows(T, d, n){ var D=AT.deck[d], seps=AT.sep[n], edges=[D.y0], out=[], k;
  seps.forEach(function(o){ edges.push(D.y0+o, D.y0+o+2); }); edges.push(D.y1);
  for(k=0;k<edges.length;k+=2){ var R=rowsOf(T, edges[k], edges[k+1]); out.push([R[0]+(k>0?1:0), R[1]-(k+2<edges.length?1:0)]); }   /* one row of margin next to each separator */
  return out; }

/* vertical lines in a deck block: yellow = djay's bar lines, grey = beat lines, red = the playhead, white = cue / loop markers.
   A line is thin: it stands out from the columns 2 to each side, in most rows of the block (lines are drawn over the waveforms). */
function lines(T, d){ var D=AT.deck[d], R=rowsOf(T, D.y0, D.y1), cw=T.cw, px=T.px, r0=R[0], r1=R[1], nr=0, x, r;
  var cY=new Float32Array(cw), wY=new Float32Array(cw), cR=new Float32Array(cw), wR=new Float32Array(cw), cG=new Float32Array(cw), wG=new Float32Array(cw), cW=new Float32Array(cw);
  for(r=r0;r<r1;r+=2){ var base=r*cw; nr++;   /* every other row is plenty: the lines run the full height */
    for(x=2;x<cw-2;x++){ var q=(base+x)*3, a=q-6, b=q+6;
      var dr=px[q]-((px[a]+px[b])>>1), dg=px[q+1]-((px[a+1]+px[b+1])>>1), db=px[q+2]-((px[a+2]+px[b+2])>>1);
      if(dr<9 && dg<9) continue;
      var mn=dr<dg?dr:dg;
      if(mn>16 && db<0.6*mn){ cY[x]++; wY[x]+=dr+dg-2*(db>0?db:0); }
      else if(dr>36 && dg<0.4*dr && db<0.4*dr){ cR[x]++; wR[x]+=dr; }
      else if(dr>9 && dg>9 && db>9){ var mx=dr>dg?(dr>db?dr:db):(dg>db?dg:db), mi=mn<db?mn:db; if(mx-mi<0.35*mx){ if(mi>120) cW[x]++; else { cG[x]++; wG[x]+=dr+dg+db; } } } } }
  function pick(cnt, w, frac){ var out=[], x=2, th=frac*nr;
    while(x<cw-2){ if(cnt[x]>=th){ var s=0, sx=0, x0=x; while(x<cw-2 && cnt[x]>=th*0.5){ s+=w[x]; sx+=w[x]*x; x++; } out.push({x:s>0?sx/s:(x0+x-1)/2, w:s, n:x-x0}); } else x++; }
    return out; }
  return {bar:pick(cY,wY,0.5), beat:pick(cG,wG,0.5), play:pick(cR,wR,0.45), mark:pick(cW,cW,0.5), nr:nr}; }

/* the grid of one deck in this frame: bar spacing (tile px per bar) + the bar lines' positions as a straight fit */
function gridFit(L, cw){ var B=L.bar.map(function(o){ return o.x; }).sort(function(a,b){ return a-b; }), G=L.beat.map(function(o){ return o.x; }).sort(function(a,b){ return a-b; });
  if(B.length>=2){ var dd=[], k; for(k=1;k<B.length;k++) dd.push(B[k]-B[k-1]); dd.sort(function(a,b){ return a-b; }); var S0=dd[0];   /* the smallest gap = one bar (a hidden line doubles a gap) */
    var idx=B.map(function(x){ return Math.round((x-B[0])/S0); }), n=B.length, sx=0, sy=0, sxx=0, sxy=0;
    for(k=0;k<n;k++){ sx+=idx[k]; sy+=B[k]; sxx+=idx[k]*idx[k]; sxy+=idx[k]*B[k]; }
    var den=n*sxx-sx*sx, S=den>0?(n*sxy-sx*sy)/den:S0, X0=(sy-S*sx)/n, res=0; for(k=0;k<n;k++) res=Math.max(res, Math.abs(X0+S*idx[k]-B[k]));
    if(S>4 && res<Math.max(1.5,S*0.04)) return {S:S, X0:X0, idx:idx, xs:B, n:n, res:res, src:'bars'}; }
  if(B.length>=1 && G.length>=2){ var gd=[]; for(var j=1;j<G.length;j++) gd.push(G[j]-G[j-1]); gd.sort(function(a,b){ return a-b; }); var Sb=gd[gd.length>>1]*4; if(Sb>8) return {S:Sb, X0:B[0], idx:[0], xs:B, n:1, res:0, src:'beats'}; }
  return null; }

/* waveform ink per lane per column. bg = the column's background (black / navy under a loop / grey before the track starts), the median of
   3 rows that are background in every layout (block top + bottom, a middle lane's top). Ink = clearly different from it AND coloured
   (djay paints lows red, mids green, highs blue). A stem muted on djay's Neural Mix faders keeps its shape but DIMS (to ~15-30 % brightness),
   so the thresholds follow each lane's own brightness this frame (its 90th percentile of coloured pixels) -- the map keeps the music while
   'gain' says how loud the stem is drawn right now. Grey text, the zero lines and the separators are never ink. */
function ink(T, d, n, L){ var cw=T.cw, px=T.px, LR=laneRows(T, d, n), nl=LR.length, x, k, r, step=cw*3;
  var F={n:nl, cw:cw, fill:new Float32Array(nl*cw), ext:new Float32Array(nl*cw), r:new Float32Array(nl*cw), g:new Float32Array(nl*cw), b:new Float32Array(nl*cw), br:new Float32Array(nl*cw), bg:new Uint8Array(cw*3), mask:new Uint8Array(cw), rows:LR, lvl:new Float32Array(nl), nCol:new Float32Array(nl)};
  /* mask the yellow bar lines, the red playhead and white markers (they are coloured too); grey beat lines are never ink anyway */
  ['bar','play','mark'].forEach(function(kk){ L[kk].forEach(function(o){ var z0=Math.floor(o.x-0.6), z1=Math.ceil(o.x+0.6); for(var z=z0;z<=z1;z++) if(z>=0&&z<cw) F.mask[z]=1; }); });
  var e0=LR[0][0], e1=LR[nl-1][1]-1, e2=nl>1?LR[nl>>1][0]:((e0+e1)>>1);
  function med3(a,b,c){ return a>b?(b>c?b:(a>c?c:a)):(a>c?a:(b>c?c:b)); }
  for(x=0;x<cw;x++){ var q1=(e0*cw+x)*3, q2=(e1*cw+x)*3, q3=(e2*cw+x)*3; F.bg[x*3]=med3(px[q1],px[q2],px[q3]); F.bg[x*3+1]=med3(px[q1+1],px[q2+1],px[q3+1]); F.bg[x*3+2]=med3(px[q1+2],px[q2+2],px[q3+2]); }
  var H=new Int32Array(256), bg=F.bg, mask=F.mask;
  for(k=0;k<nl;k++){ var a=LR[k][0], b=LR[k][1], h=b-a; if(h<=0) continue;
    /* pass 1: this lane's brightness (p90 of the coloured pixels' max channel) */
    H.fill(0); var tot=0;
    for(x=0;x<cw;x+=2){ if(mask[x]) continue; var bR=bg[x*3], bG=bg[x*3+1], bB=bg[x*3+2], q=(a*cw+x)*3;
      for(r=a;r<b;r++,q+=step){ var pr=px[q], pg=px[q+1], pb=px[q+2], u=pr-bR, v=pg-bG, w=pb-bB; if(u<0) u=-u; if(v<0) v=-v; if(w<0) w=-w; if(u+v+w<=14) continue;
        var mx=pr>pg?(pr>pb?pr:pb):(pg>pb?pg:pb), mi=pr<pg?(pr<pb?pr:pb):(pg<pb?pg:pb); if(mx-mi<=10) continue; H[mx]++; tot++; } }
    var lvl=0; if(tot>=20){ var c=0, lim=tot*0.9; while(lvl<255 && c+H[lvl]<lim){ c+=H[lvl]; lvl++; } }
    F.lvl[k]=lvl; F.nCol[k]=tot;
    var tm=Math.max(14, 0.25*lvl), tc=Math.max(10, 0.22*lvl);   /* 45 / 45 at full brightness, ~14 / 10 for a dimmed stem */
    /* pass 2: per column fill / extent / colour */
    for(x=0;x<cw;x++){ var bR2=bg[x*3], bG2=bg[x*3+1], bB2=bg[x*3+2], cnt=0, top=-1, bot=-1, R_=0, G_=0, B_=0, BR=0, q2=(a*cw+x)*3;
      for(r=a;r<b;r++,q2+=step){ var pr2=px[q2], pg2=px[q2+1], pb2=px[q2+2], u2=pr2-bR2, v2=pg2-bG2, w2=pb2-bB2;
        if(u2<0) u2=-u2; if(v2<0) v2=-v2; if(w2<0) w2=-w2; if(u2+v2+w2<=tm) continue;
        var mx2=pr2>pg2?(pr2>pb2?pr2:pb2):(pg2>pb2?pg2:pb2), mi2=pr2<pg2?(pr2<pb2?pr2:pb2):(pg2<pb2?pg2:pb2);
        if(mx2-mi2>tc || mi2>200){ cnt++; if(top<0) top=r; bot=r; var dr2=pr2-bR2, dg2=pg2-bG2, db2=pb2-bB2; R_+=dr2>0?dr2:0; G_+=dg2>0?dg2:0; B_+=db2>0?db2:0; BR+=mx2; } }   /* colour = ink minus the background (a loop's navy tint shifts the raw colours) */
      var o=k*cw+x; F.fill[o]=cnt/h; F.ext[o]=cnt?(bot-top+1)/h:0; if(cnt){ F.r[o]=R_/cnt; F.g[o]=G_/cnt; F.b[o]=B_/cnt; F.br[o]=BR/cnt; } } }
  return F; }

/* ======================= DIGITS: djay's bar numbers over the lanes =======================
   Grey text, ~9 px tall at half resolution, drawn just right of each yellow bar line. Read on the min-channel image (grey text is
   bright in all three channels; the coloured waveform behind it is not). Templates = 11 x 9 px averages of thousands of glyphs read
   off Mike's recordings (self-checked: a frame's labels must count up by one, djay skips bar 0: -1 then 1). */
var DIG={h:11, w:9, A:'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/', s:{"0": "00258510003FNMNF201BM818MB12IF212FI24KB111BL46KA212AL56LC333DM69MI778JM87HOB7CPH736JMJNJ52113AD9311", "1": "001351001118MO51131BLGM51191956M51281117M51261117M61261227M6237666BPB67C766BPB66C2228N7225111383112", "2": "00147520003FNMNG301CK616LA1199113HD1111117L9222225IG423336IJ644679KMA77768JMA77764EROLLLF526ABAAA82", "3": "00479621014IOMMG412AK616IB1147214GD101346CH61115FNMD4233345AKE3687667GM87HJ769JK738KLIKK831149B9411", "4": "0001243100113FPH200129JJG20116HEEG3013DH6DG3129I94EG426HE55FH53GRQNORSKBAFFFGNOF922334EH53111125621", "5": "0255555201BPOOOL801BG3111102CE3221102EJHLJA213GMC9GMA2477447II59BA88AKMA9KK98DNJ839LLKNJ73114ADA411", "6": "00158520002GOMOI401CM614JC12KD1223315MCGLKA217POF9FOB29RI545IM5BRJ989JQA9KPB8BPL847LOKNL731239DA422", "7": "2555555216NOOOPO6112222CK3111114KA111112CK3122225LB222334EL544488BQG999988IOA888836MC33433249322222", "8": "00258520004HNMNH401EK515LD11GH212JE117JD8EJ7124GQQQF424HMA6AMG4BQI888JPAAPLA89MOA4BNMKNNB4226ADA522", "9": "00278410005KONOC102KI318N705O8001JI14O9112ML32HL85DPM424IPOJHM4687997LL76KH76CRD629NKING32115BD8211"}};
var DT=null;
function digT(){ if(DT) return DT; DT={}; Object.keys(DIG.s).forEach(function(k){ var str=DIG.s[k], a=new Float32Array(99), m=0, i, v=0;
    for(i=0;i<99;i++){ a[i]=DIG.A.indexOf(str.charAt(i))*4; m+=a[i]; } m/=99; for(i=0;i<99;i++){ a[i]-=m; v+=a[i]*a[i]; } DT[k]={a:a, n:Math.sqrt(v)||1}; }); return DT; }
/* one label: the 14 x 34 min-channel box right of a bar line at tile x bx -> {s:'123', q: worst glyph score} or null */
function labelRead(T, d, bx){ var D=AT.deck[d], r0=rowsOf(T, D.y0, D.y1)[0]+2, x0=Math.round(bx)+2, cw=T.cw, px=T.px, W=34, H=14, M=new Float32Array(W*H), A=new Int32Array(W), x, y;
  if(x0<0 || x0+W>cw) return null;
  for(y=0;y<H;y++) for(x=0;x<W;x++){ var q=((r0+y)*cw+x0+x)*3, a=px[q], b=px[q+1], c=px[q+2], m=a<b?(a<c?a:c):(b<c?b:c), mx=a>b?(a>c?a:c):(b>c?b:c); if(mx-m>60) m=Math.min(m,60); M[y*W+x]=m; if(m>75) A[x]++; }   /* text is grey: a coloured pixel is never text */
  var segs=[], s0=-1, hi=0; for(x=0;x<=W;x++){ var on=x<W && A[x]>=1; if(on){ if(s0<0){ s0=x; hi=0; } if(A[x]>hi) hi=A[x]; } else if(s0>=0){ segs.push([s0,x,hi]); s0=-1; } }
  if(!segs.length || segs.length>5) return null;
  var T_=digT(), str='', q=1, p=new Float32Array(99);
  for(var k=0;k<segs.length;k++){ var sg=segs[k];
    if(sg[2]<=2){ if(sg[1]-sg[0]>=2 && sg[1]-sg[0]<=6 && str==='') str+='-'; continue; }   /* a thin dash before the digits = minus */
    var cx=(sg[0]+sg[1]-1)/2, bx0=Math.round(cx-4), best=null, bs=-2;
    for(var dy=-1;dy<=1;dy++) for(var dx=-1;dx<=1;dx++){ var m2=0, i=0, yy, xx;
      for(yy=0;yy<11;yy++){ var Y=2+yy+dy; for(xx=0;xx<9;xx++,i++){ var X=bx0+xx+dx; var v2=(Y>=0&&Y<H&&X>=0&&X<W)?M[Y*W+X]:0; p[i]=v2; m2+=v2; } }
      m2/=99; var nn=0; for(i=0;i<99;i++){ p[i]-=m2; nn+=p[i]*p[i]; } nn=Math.sqrt(nn)||1;
      for(var key in T_){ var t=T_[key], sc=0; for(i=0;i<99;i++) sc+=p[i]*t.a[i]; sc/=nn*t.n; if(sc>bs){ bs=sc; best=key; } } }
    if(bs<0.6) return null; str+=best; if(bs<q) q=bs; }
  if(!/^-?[0-9]{1,4}$/.test(str)) return null;
  return {s:str, v:parseInt(str,10), q:q}; }
/* djay numbers bars ..., -2, -1, 1, 2, ... ; as a continuous index: bar 1 -> 0, bar -1 -> -1 */
function barIdx(n){ return n>=1?n-1:n; }
function barNum(i){ return i>=0?i+1:i; }
/* the frame's labels -> the bar index of the grid's first line (idx 0), when at least 2 labels agree */
function labelsFit(T, d, G){ if(!G) return null; var votes={}, n=0, best=null;
  for(var k=0;k<G.xs.length;k++){ var L=labelRead(T, d, G.xs[k]); if(!L) continue; n++; var i0=barIdx(L.v)-G.idx[k]; votes[i0]=(votes[i0]||0)+1+L.q*0.01; }
  Object.keys(votes).forEach(function(k){ if(!best || votes[k]>votes[best]) best=k; });
  if(best==null) return null; var c=Math.floor(votes[best]);
  return {i0:+best, votes:c, n:n, ok:c>=2 || (c>=1 && n===1 && G.xs.length<=2)}; }

/* ======================= one deck, one frame ======================= */
function deckFrame(T, d, modeHint){ var L=lines(T, d), out={d:d, ok:false};
  var px0=(AT.playX-T.x)/T.s, ph=null; L.play.forEach(function(o){ if(Math.abs(o.x-px0)<8 && (!ph || o.w>ph.w)) ph=o; });
  out.play=ph?ph.x:null; out.lines=L;
  if(!ph) return out;   /* no playhead in this block: an empty deck, or the block is covered (the library, a popover) */
  var M=modeHint?{n:modeHint, c:null}:laneMode(T, d); out.mode=M.n; out.sepC=M.c;
  out.grid=gridFit(L, T.cw); out.ok=!!out.grid;
  out.ink=ink(T, d, M.n, L);
  return out; }

/* ======================= MIXER + PANELS + HEADER =======================
   MX (mixer column, /2): EQ layout = FILTER / HIGH / MID / LOW knobs at the sides, the channel faders in the middle over the VU meters;
   FX layout = the faders at the sides. LOW (/4): each side panel (Neural Mix / cue / loop / FX / EQ, the selected icon is blue),
   Neural Mix stem faders, the play buttons (green ring = playing), the crossfader. TOP (/2): titles (a text signature: a new track =
   a new signature), the whole-track overview strips + their red position marker, the transport row's loop circle (blue = loop on). */
function px3(T, x, y){ x=Math.round(x); y=Math.round(y); if(x<0||y<0||x>=T.cw||y>=T.ch) return null; var q=(y*T.cw+x)*3; return [T.px[q], T.px[q+1], T.px[q+2]]; }
/* a knob's pointer angle (0 = straight up, - = left, + = right; +-135 at the ends): the brightest point on a ring around the centre */
function knob(T, cx, cy, r){ var best=-1, ba=null, i, cw=T.cw, ch=T.ch, P=T.px; for(i=0;i<72;i++){ var a=(i*5-180)*Math.PI/180, sn=Math.sin(a), cs=Math.cos(a), v=0, k;
    for(k=0;k<2;k++){ var x=Math.round(cx+sn*(r-k)), y=Math.round(cy-cs*(r-k)); if(x<0||y<0||x>=cw||y>=ch) continue; var q=(y*cw+x)*3, p0=P[q], p1=P[q+1], p2=P[q+2]; v+=p0<p1?(p0<p2?p0:p2):(p1<p2?p1:p2); }
    if(v>best){ best=v; ba=i*5-180; } }
  return best>2*150?ba:null; }
var MXL={eq:{fad:[[124,154],[170,200]], top:127, zero:366, knobs:{filter:41, high:158, mid:267, low:375}, kx:[56.5,271]}};
function mixRead(T){ var o={lay:null, fader:[null,null], eq:[{},{}]}, d, k;
  /* EQ layout: the four knob pointers on each side */
  var kn=0; ['high','mid','low'].forEach(function(nm){ for(d=0;d<2;d++){ if(knob(T, MXL.eq.kx[d], MXL.eq.knobs[nm], 15)!=null) kn++; } });
  if(kn>=5){ o.lay='eq'; for(d=0;d<2;d++){ for(k in MXL.eq.knobs){ var ang=knob(T, MXL.eq.kx[d], MXL.eq.knobs[k], 15); o.eq[d][k]=ang==null?null:Math.max(-1,Math.min(1,ang/135)); } }
    /* channel fader cap: a ~26 px wide dark-grey bar: a light top edge (grey 70-125), a darker body, a grey bottom edge 7-11 rows down */
    for(d=0;d<2;d++){ var X=MXL.eq.fad[d], best=null, y, cw=T.cw, P=T.px;
      var rowOk=function(yy, lo, hi){ var n=0, m=0, x; for(x=X[0]+4;x<X[1]-4;x++){ var q=(yy*cw+x)*3, r=P[q], g=P[q+1], b=P[q+2], v=(r+g+b)/3; m++; if(Math.abs(r-b)<15 && Math.abs(r-g)<20 && v>=lo && v<=hi) n++; } return m && n>=0.7*m; };   /* the cap is see-through: the VU's green tints it */
      for(y=100;y<380;y++){ if(!rowOk(y,70,125)) continue; var bot=false, z; for(z=y+7;z<=y+11;z++){ if(rowOk(z,55,82)){ bot=true; break; } } if(!bot) continue;
        var q4=((y+4)*cw+Math.round((X[0]+X[1])/2))*3; if(P[q4]<75){ best=y; break; } }
      o.fader[d]=best==null?null:Math.max(0,Math.min(1,(MXL.eq.zero-best)/(MXL.eq.zero-MXL.eq.top))); } }
  else o.lay='other';
  return o; }
var LWL={icons:[[25,77,130,181,234],[449,500,552,604,656]], iconY:[205,228], kinds:['nm','cue','loop','fx','eq'], nmX:[[42,130,217],[465,552,640]], nmTop:92, nmZero:184, play:[[40,263.5],[642.5,263.5]], xf:[280,410,250,277], xfL:287, xfR:400};
function lowRead(T){ var o={panel:[null,null], nm:[null,null], play:[null,null], xf:null}, d, i;
  for(d=0;d<2;d++){ var best=-1, bi=-1; for(i=0;i<5;i++){ var cx=LWL.icons[d][i], n=0, y, x; for(y=LWL.iconY[0];y<LWL.iconY[1];y++) for(x=cx-8;x<=cx+8;x++){ var p=px3(T,x,y); if(p && p[2]>200 && p[0]<120 && p[1]>100) n++; } if(n>best){ best=n; bi=i; } }
    o.panel[d]=best>=6?LWL.kinds[bi]:null;
    if(o.panel[d]==='nm'){ o.nm[d]=LWL.nmX[d].map(function(cx){ var y, hit=null; for(y=LWL.nmTop-6;y<=LWL.nmZero+6;y++){ var n=0, x; for(x=cx-10;x<=cx+10;x++){ var p=px3(T,x,y); if(p && p[0]>200 && p[1]>200 && p[2]>200) n++; } if(n>=14){ hit=y; break; } }
        return hit==null?null:Math.max(0,Math.min(1,(LWL.nmZero-hit-1)/(LWL.nmZero-LWL.nmTop))); }); }
    /* play: the button's ring is green while the deck plays */
    var c=LWL.play[d], g=0, m=0; for(i=0;i<36;i++){ var a=i*10*Math.PI/180, ok=false; for(var rr=22;rr<=23;rr++){ var p2=px3(T, c[0]+Math.cos(a)*rr, c[1]+Math.sin(a)*rr); if(p2 && p2[1]>110 && p2[1]>p2[0]*1.6 && p2[1]>p2[2]*1.6) ok=true; } m++; if(ok) g++; } o.play[d]=g/m>0.4; }
  /* crossfader cap: the whitest column in its track */
  var bx=null, bn=0, x2; for(x2=LWL.xf[0];x2<LWL.xf[1];x2++){ var n2=0, y2; for(y2=LWL.xf[2];y2<LWL.xf[3];y2++){ var p4=px3(T,x2,y2); if(p4 && p4[0]>200 && p4[1]>200 && p4[2]>200) n2++; } if(n2>bn){ bn=n2; bx=x2; } }
  o.xf=bn>=6?Math.max(-1,Math.min(1,((bx-LWL.xfL)/(LWL.xfR-LWL.xfL))*2-1)):null;
  return o; }
var TPL={title:[[122,445],[777,1095]], titleY:[44,64], ov:[[122,586],[777,1241]], ovY:[83,95], mkY:[78,82]}, TRL={loop:[[140,18.5],[542.5,18.5]], r:9};
function topRead(T){ var o={sig:[null,null], ov:[null,null], mark:[null,null]}, d;
  for(d=0;d<2;d++){ var X=TPL.title[d], sig=[], x, y, n=0;
    for(x=X[0];x<X[1];x+=3){ var b=0; for(y=TPL.titleY[0];y<TPL.titleY[1];y+=2){ var p=px3(T,x,y); if(p && p[0]>150 && p[1]>150 && p[2]>150){ b=1; n++; break; } } sig.push(b); }
    o.sig[d]=n>=4?sig:null;
    var V=TPL.ov[d], prof=[], mk=null; for(x=V[0];x<V[1];x++){ var r=0, g=0, bb=0, k=0, red=0; for(y=TPL.ovY[0];y<=TPL.ovY[1];y++){ var p2=px3(T,x,y); if(p2){ r+=p2[0]; g+=p2[1]; bb+=p2[2]; k++; } }
        for(y=TPL.mkY[0];y<=TPL.mkY[1];y++){ var p3=px3(T,x,y); if(p3 && p3[0]>180 && p3[1]<70 && p3[2]<70) red++; } if(red>=3 && mk==null) mk=x;
        prof.push(k?[r/k|0, g/k|0, bb/k|0]:[0,0,0]); }
    o.ov[d]=prof; o.mark[d]=mk==null?null:(mk-V[0])/(V[1]-V[0]);
  }
  return o; }
/* the transport row: deck d's loop circle is blue while a loop is on */
function trRead(T){ var o={loop:[null,null]}, d, x, y; for(d=0;d<2;d++){ var L=TRL.loop[d], bl=0, tt=0;
    for(y=Math.round(L[1]-TRL.r);y<=Math.round(L[1]+TRL.r);y++) for(x=Math.round(L[0]-TRL.r-1);x<=Math.round(L[0]+TRL.r+1);x++){ var p4=px3(T,x,y); if(!p4) continue; tt++; if(p4[2]>170 && p4[0]<110 && p4[2]>p4[0]+60) bl++; } o.loop[d]=tt?bl/tt>0.06:null; }
  return o; }
function sigDiff(a, b){ if(!a || !b || a.length!==b.length) return 1; var d=0, u=0; for(var i=0;i<a.length;i++){ if(a[i]||b[i]) u++; if(a[i]!==b[i]) d++; } return u?d/u:0; }

/* ======================= THE READER: state across frames ======================= */
var SPB=32;   /* map slots per bar (1/32 notes) */
var CH=['V','H','B','D','X'];   /* map channels: vocals, harmonic, bass, drums, mix (1 / 2 lane views) */
var MODE_CH={1:['X'], 2:['V','X'], 3:['V','H','D'], 4:['V','H','B','D']};
var NF=6;   /* per channel per slot: n (columns seen), fill, ext, lo (red share), hi (blue share), att (attack) */
function newDeck(d){ return {d:d, mode:0, modeC:0, modeN:0, modeAt:-1e9, on:false, seenT:-1e9, S:0, pb:null, pbT:null, rate:0, hist:[], playing:false, playT:-1e9,
  lab:{t:-1e9, ok:false, i0:null}, jumps:0, jumpT:-1e9, map:{}, mapN:0, track:0, loop:false, dim:{}, lastF:null, look:0, first:null, last:null}; }
function reader(opt){ return {opt:opt||{}, n:0, t:null, decks:[newDeck(0), newDeck(1)], view:'none', viewT:-1e9, mix:null, ev:[], evN:0, log:[]}; }
function barArr(D, bar){ var a=D.map[bar]; if(!a){ a=D.map[bar]=new Float32Array(SPB*CH.length*NF); D.mapN++; } return a; }
function resetTrack(D, why){ D.map={}; D.mapN=0; D.track++; D.hist=[]; D.rate=0; D.first=null; D.last=null; D.trackWhy=why; D.trackT=D.pbT||0; D.ref=null; }

/* fold one frame of one deck into its state */
function deckUpdate(R, D, F, t, T){ var G=F.grid, Xp=F.play, S=G.S, lab=null;
  /* lane layout: sticky (3 frames in a row to change) */
  if(F.mode!==D.mode){ if(F.mode===D.modeC) D.modeN++; else { D.modeC=F.mode; D.modeN=1; } if(D.modeN>=3 || !D.mode){ if(D.mode && D.mode!==F.mode) resetTrack(D,'lanes '+D.mode+'->'+F.mode); D.mode=F.mode; D.modeAt=t; } }
  /* where is the playhead in the track (bar index, bar 1 = 0)? prediction from the last frames, checked against djay's numbers */
  var rel=(Xp-G.X0)/S, pred=null; if(D.pb!=null && D.pbT!=null && t-D.pbT<1.5) pred=D.pb+(D.playing?D.rate:0)*(t-D.pbT);
  var needLab=pred==null || t-D.lab.t>0.6;
  if(needLab){ lab=labelsFit(T, D.d, G); if(lab && lab.ok){ D.lab={t:t, ok:true, i0:lab.i0}; } }
  var i0=null, src='', hold=false;
  if(lab && lab.ok){
    if(pred==null){ i0=lab.i0; src='label'; }
    else { var pi=Math.round(pred-rel), jb=(lab.i0+rel)-pred;
      if(pi===lab.i0 || Math.abs(jb)<=0.25){ i0=lab.i0; src='label'; D.pend=null; }
      else if(Math.abs(jb)>=64 && (String(barNum(Math.round(pred-rel))).indexOf(String(barNum(lab.i0)))>=0 || String(barNum(lab.i0)).indexOf(String(barNum(Math.round(pred-rel))))>=0)){ i0=pi; src='track'; D.lab.t=t; }   /* '113' read as '13' (a thin 1 lost): a misread, not a jump */
      else if((D.loop && jb<0 && jb>-65) || (D.pend && D.pend.i0===lab.i0-Math.round((t-D.pend.t0)*(D.playing?D.rate:0)) && (Math.abs(jb)<64 ? D.pend.n>=1 : (D.pend.n>=2 && t-D.pend.t0>=0.4)))){   /* a loop wraps back: believe it; a jump must read the same twice (a far one 3 times over 0.4 s: a misread digit is not a jump) */
        i0=lab.i0; src='jump'; D.jumps++; D.jumpT=t; D.hist=[]; D.pend=null; R.log.push([+t.toFixed(2),D.d,'jump',+pred.toFixed(2),+(i0+rel).toFixed(2)]); }
      else { if(D.pend && D.pend.i0===lab.i0-Math.round((t-D.pend.t0)*(D.playing?D.rate:0))) D.pend.n++; else D.pend={i0:lab.i0, t0:t, n:1}; i0=pi; src='hold'; hold=true; D.lab.t=-1e9; } } }
  else if(pred!=null){ i0=Math.round(pred-rel); src='track'; }
  if(i0==null) return false;
  var pb=i0+rel;
  /* tempo: a straight line through the last ~3 s of (t, pb) while it moves */
  if(D.pb!=null && Math.abs(pb-D.pb)<1e-4 && D.pbT!=null && t-D.pbT>0.25){ D.playing=false; }
  D.hist.push([t,pb]); while(D.hist.length>2 && t-D.hist[0][0]>3) D.hist.shift();
  if(D.hist.length>=4){ var n=D.hist.length, sx=0, sy=0, sxx=0, sxy=0, k; for(k=0;k<n;k++){ var u=D.hist[k][0]-t, v=D.hist[k][1]; sx+=u; sy+=v; sxx+=u*u; sxy+=u*v; } var den=n*sxx-sx*sx;
    if(den>1e-9){ var rate=(n*sxy-sx*sy)/den; if(rate>0.05 && rate<2){ D.rate=rate; D.playing=true; D.playT=t; } else if(Math.abs(rate)<0.02){ D.playing=false; } } }
  D.pb=pb; D.pbT=t; D.S=S; D.src=src; D.on=true; D.seenT=t;
  /* the screen shows [left edge .. right edge] in bars around the playhead */
  var cw=T.cw, bL=pb+(0-Xp)/S, bR=pb+(cw-1-Xp)/S; D.view=[bL,bR]; D.look=bR-pb;
  /* loop: the background behind the playhead is navy */
  var I=F.ink, xi=Math.round(Xp)+3, bgB=I.bg[xi*3+2], bgR=I.bg[xi*3]; D.loop=bgB>55 && bgB-bgR>40;
  /* fold the columns into the map */
  if(!hold) mapAdd(D, F, Xp, S, pb, t);
  if(D.first==null || bL<D.first) D.first=bL; if(D.last==null || bR>D.last) D.last=bR;
  return true; }

function mapAdd(D, F, Xp, S, pb, t){ var I=F.ink, cw=I.cw, chs=MODE_CH[D.mode]||[], nl=Math.min(I.n, chs.length), mask=I.mask, k, x;
  var dx=Math.max(1, Math.round(S/64));   /* attack = rise over ~1/64 bar */
  var ci=chs.map(function(c){ return CH.indexOf(c); });
  for(x=dx;x<cw;x++){ if(mask[x]) continue; var b=pb+(x-Xp)/S, bar=Math.floor(b), sl=Math.floor((b-bar)*SPB); if(sl>=SPB) sl=SPB-1;
    var A=barArr(D, bar);
    for(k=0;k<nl;k++){ var o=k*cw+x, f=I.fill[o]; var base=(sl*CH.length+ci[k])*NF; A[base]+=1; A[base+1]+=f; A[base+2]+=I.ext[o];
      if(f>0){ var r=I.r[o], g=I.g[o], bb=I.b[o], sm=r+g+bb+1; A[base+3]+=f*r/sm; A[base+4]+=f*bb/sm; }
      var fp=mask[x-dx]?f:I.fill[k*cw+x-dx], at=f-fp; if(at>0) A[base+5]+=at; } } }

/* ======================= the frame ======================= */
/* frame = {t: seconds, tiles: {LN, MX, LOW, TOP} (any may be missing this frame)} */
function frame(R, fr){ var t=fr.t, T=fr.tiles||{}, d; R.n++; R.t=t; var res={t:t, decks:[]};
  if(T.TOP){ var tp=topRead(T.TOP); R.top=tp; R.topT=t;
    for(d=0;d<2;d++){ var D=R.decks[d];
      if(tp.sig[d]){ if(D.sig){ var df=sigDiff(D.sig, tp.sig[d]); if(df>0.35){ if(D.sigC && sigDiff(D.sigC, tp.sig[d])<0.2){ resetTrack(D,'title'); D.sig=tp.sig[d]; D.sigC=null; R.log.push([+t.toFixed(2),d,'track']); } else D.sigC=tp.sig[d]; } else { D.sigC=null; if(df>0.05) D.sig=tp.sig[d]; } } else D.sig=tp.sig[d]; }
      if(tp.mark[d]!=null) D.mark=tp.mark[d]; } }
  if(T.TR){ var tr=trRead(T.TR); R.tr=tr; for(d=0;d<2;d++){ if(tr.loop[d]!=null) R.decks[d].loopUI=tr.loop[d]; } }
  if(T.MX){ var mx=mixRead(T.MX), pm=R.mx; if(pm){ for(d=0;d<2;d++){ if(mx.fader[d]==null) mx.fader[d]=pm.fader[d]; if(mx.lay==='eq' && pm.eq) for(var kk in mx.eq[d]) if(mx.eq[d][kk]==null && pm.eq[d]) mx.eq[d][kk]=pm.eq[d][kk]; } } R.mx=mx; R.mxT=t; }   /* a missed read holds the last value */
  if(T.LOW){ var lw=lowRead(T.LOW); R.lw=lw; R.lwT=t; for(d=0;d<2;d++){ if(lw.play[d]!=null) R.decks[d].playUI=lw.play[d]; if(lw.nm[d]) { R.decks[d].nm=lw.nm[d]; R.decks[d].nmT=t; } } }
  if(T.LN){ var seen=0;
    for(d=0;d<2;d++){ var D2=R.decks[d], F=deckFrame(T.LN, d, (D2.mode && R.n%8!==d*4)?D2.mode:0); D2.lastF=F;
      if(F.ok){ if(deckUpdate(R, D2, F, t, T.LN)) seen++; lanesGain(D2, F); }
      else if(F.play!=null){ D2.on=true; D2.seenT=t; }
      res.decks.push({ok:F.ok, play:F.play, mode:F.mode}); }
    if(seen){ R.view='decks'; R.viewT=t; } else if(t-R.viewT>1) R.view=(R.lwT>t-1 && R.lw && R.lw.xf!=null)?'covered':'other'; }
  mixState(R); mixMoves(R);
  return res; }
/* how loud each lane is drawn now vs its brightest so far (a Neural Mix stem fader dims its lane) */
function lanesGain(D, F){ var I=F.ink, chs=MODE_CH[D.mode]||[], k; D.lv=D.lv||{};
  for(k=0;k<Math.min(I.n, chs.length);k++){ var c=chs[k], lv=I.lvl[k], n=I.nCol[k]; if(n<60) continue; var ref=D.lv[c]||0; ref=Math.max(lv, ref*0.999); D.lv[c]=ref; D.gain=D.gain||{}; D.gain[c]=ref>0?Math.min(1, lv/ref):1; } }
/* who is audible: channel fader^1.5 x crossfader x playing; the EQ low knob scales the bass / kick */
function mixState(R){ var mx=R.mx, lw=R.lw, out=[0,1].map(function(d){ var D=R.decks[d], f=mx&&mx.fader[d]!=null?mx.fader[d]:1, xf=lw&&lw.xf!=null?lw.xf:0, xg=d===0?(xf>0?1-xf:1):(xf<0?1+xf:1);
    var playing=D.playUI!=null?D.playUI:D.playing, low=mx&&mx.eq&&mx.eq[d]&&mx.eq[d].low!=null?mx.eq[d].low:0;
    return {d:d, gain:(D.on && playing && D.pb!=null)?Math.pow(Math.max(0,f),1.5)*Math.max(0,Math.min(1,xg)):0, fader:f, low:low, bassG:low<=-0.85?0.05:Math.max(0.05, 1+0.6*Math.min(0,low)), playing:!!playing}; });
  var m=out[0].gain>=out[1].gain?0:1; if(out[m].gain<=0.02) m=R.master!=null?R.master:m; R.master=m; R.mix=out; return out; }

/* ======================= reading the map ======================= */
/* per-bar summary of one deck: for each channel: e = mean fill, k[j] = attack at beat j (0..3), lo / hi = colour shares, cov = slots seen */
function barSum(D, bar){ var A=D.map[bar], o={bar:bar, cov:0, ch:{}}; if(!A) return o; var c, j, s, nCov=0;
  for(c=0;c<CH.length;c++){ var e=0, n=0, lo=0, hi=0, att=[0,0,0,0], ext=0, ns=0;
    for(s=0;s<SPB;s++){ var base=(s*CH.length+c)*NF, m=A[base]; if(!m) continue; ns++; var f=A[base+1]/m; e+=f; ext+=A[base+2]/m; lo+=A[base+3]/m; hi+=A[base+4]/m; var a=A[base+5]/m, bt=Math.floor(s/(SPB/4)), ps=s%(SPB/4); if(ps<=2 && a>att[bt]) att[bt]=a; }
    if(ns){ o.ch[CH[c]]={e:e/ns, ext:ext/ns, lo:lo/ns, hi:hi/ns, att:att, cov:ns/SPB}; if(ns>nCov) nCov=ns; } }
  o.cov=nCov/SPB; return o; }

/* ======================= MUSIC from the map: per bar, then events =======================
   Kick = the drums lane's RED ink (djay paints lows red: the kick's body; hats / snares are blue / white), bass = the bass lane,
   all relative to this track's own loud bars (90th percentile), so a quiet master or a dim lane doesn't matter. */
function barInfo(D, bar){ var s=barSum(D, bar), c=s.ch, o={bar:bar, cov:s.cov, k:null, d:null, b:null, v:null, h:null, x:null, att:null};
  if(c.D){ o.k=c.D.lo; o.d=c.D.e; o.att=c.D.att; } if(c.B) o.b=c.B.e; if(c.V) o.v=c.V.e; if(c.H){ o.h=c.H.e; if(o.b==null && D.mode===3) o.b=c.H.lo; } if(c.X){ o.x=c.X.e; if(o.k==null){ o.k=c.X.lo; o.d=c.X.e; o.att=c.X.att; } }
  return o; }
function pctl(a, p){ if(!a.length) return 0; var b=a.slice().sort(function(x,y){ return x-y; }); return b[Math.min(b.length-1, Math.floor(p*b.length))]; }
/* the track's reference levels (refreshed every 2 s; early on, sensible absolute floors) */
function refs(D, t){ if(D.ref && t-D.ref.t<2 && D.ref.n===D.mapN) return D.ref; var K=[], B=[], V=[], Dd=[];
  Object.keys(D.map).forEach(function(k){ var o=barInfo(D, +k); if(o.cov<0.5) return; if(o.k!=null) K.push(o.k); if(o.b!=null) B.push(o.b); if(o.v!=null) V.push(o.v); if(o.d!=null) Dd.push(o.d); });
  var kr=pctl(K,0.9), dr=pctl(Dd,0.9); D.ref={t:t, n:D.mapN, k:Math.max(0.12, kr), b:Math.max(0.08, pctl(B,0.9)), v:Math.max(0.08, pctl(V,0.9)), d:Math.max(0.15, dr), bars:K.length, kick:dr>0.05 && kr>=0.35*dr}; return D.ref; }   /* kick: the loud bars' drums are >= 35 % red = a four-on-the-floor kick */
/* section of one bar: FULL (the kick is in), HALF, NONE (no kick); null = not seen well enough */
function barState(D, o, ref){ if(!o || o.cov<0.4 || o.d==null) return null; var k=o.k/ref.k, dn=o.d/ref.d, bn=o.b!=null?o.b/ref.b:null;
  if(ref.kick){ return k>=0.5?'FULL':k<0.25?'NONE':'HALF'; }   /* a four-on-the-floor track: the red kick decides (a snare roll or a breakdown's bass is not the drop) */
  if(dn>=0.55 && (bn==null || bn>=0.4)) return 'FULL';   /* no red kick (trap: hats + an 808 in the bass lane): drums AND bass together */
  if(dn<0.3) return 'NONE'; return 'HALF'; }
/* events of one deck around now: DROP (the kick back after >= 2 bars without it; 1 bar = REENTRY), BREAK (the kick goes), BREATH (silent
   beats right before a drop), BUILD (the gap's last bars where the drum hits thicken). Each with its bar; the reader keeps when it was
   first known. States come from the last ~48 bars + everything seen ahead; events are emitted from 2 bars back to the right edge. */
function deckEvents(R, D, t){ if(D.pb==null) return []; var barS=D.rate>0?1/D.rate:2; if(t-D.jumpT<barS || t-D.modeAt<2*barS || t-(D.trackT||-1e9)<2*barS) return [];   /* settle first: a jump, a new layout or a new track */ var ref=refs(D, t), pbF=Math.floor(D.pb), b0=pbF-48, b1=Math.floor(D.last!=null?D.last:D.pb), out=[], st={}, info={}, b;
  for(b=b0;b<=b1+1;b++){ info[b]=barInfo(D, b); st[b]=barState(D, info[b], ref); }
  for(b=Math.max(b0+1,pbF-2);b<=b1;b++){
    if(st[b]==='FULL' && st[b-1] && st[b-1]!=='FULL'){ var g=0; while(b-1-g>b0 && st[b-1-g] && st[b-1-g]!=='FULL') g++;
      var k1=beatK(D, b, 0, ref), kPrev=Math.max(beatK(D, b-1, 2, ref)||0, beatK(D, b-1, 3, ref)||0), hard=k1!=null && k1>=0.5 && kPrev<0.3;
      var sure=Math.min(1, info[b].cov*1.5)*(st[b+1]==='FULL'?1:st[b+1]==null?0.85:0.5)*(hard?1:0.7);
      out.push({type:g>=2?'drop':'reentry', d:D.d, bar:b, gap:g, hard:hard, conf:+sure.toFixed(2)});
      var bt=breathBeats(D, b-1, ref); if(bt>0) out.push({type:'breath', d:D.d, bar:b, beats:bt, conf:+sure.toFixed(2)});
      if(g>=2){ var bu=buildBars(D, b, g, ref); if(bu>0) out.push({type:'build', d:D.d, bar:b-bu, len:bu, drop:b, conf:+sure.toFixed(2)}); } }
    if(st[b]==='NONE' && st[b-1]==='FULL' && st[b+1]!=='FULL') out.push({type:'break', d:D.d, bar:b, conf:+(st[b+1]==null?0.6:1).toFixed(2)}); }
  return out; }
/* the kick on beat j of a bar (red ink in the drums lane at the beat's first 3 slots) relative to the track's kick level */
function beatK(D, bar, j, ref){ var A=D.map[bar]; if(!A) return null; var ci=CH.indexOf(D.mode>=3?'D':'X'), m=null, s;
  for(s=j*SPB/4;s<j*SPB/4+3;s++){ var base=(s*CH.length+ci)*NF, n=A[base]; if(n){ var v=A[base+3]/n; if(m==null || v>m) m=v; } } return m==null?null:m/(ref.k*1.6); }
function beatE(D, bar, j){ var A=D.map[bar]; if(!A) return null; var e=0, n=0, ci=[CH.indexOf('D'), CH.indexOf('B'), CH.indexOf('X')], s;
  for(s=j*SPB/4;s<(j+1)*SPB/4;s++){ for(var q=0;q<ci.length;q++){ var base=(s*CH.length+ci[q])*NF, m=A[base]; if(m){ e+=A[base+1]/m; n++; } } } return n?e/n:null; }
function breathBeats(D, bar, ref){ var n=0; for(var j=3;j>=0;j--){ var e=beatE(D, bar, j); if(e==null || e>0.25*ref.d) break; n++; } if(n===4){ var e2=beatE(D, bar-1, 3); if(e2!=null && e2<=0.25*ref.d) n=5; } return n; }
function buildBars(D, drop, g, ref){ var n=0; for(var b=drop-1;b>=drop-Math.min(g,16);b--){ var o=barInfo(D, b); if(!o || o.att==null || o.cov<0.4) break; var a=(o.att[0]+o.att[1]+o.att[2]+o.att[3])/4; if(a<0.04 && o.d<0.35*ref.d) break; n++; } return n; }
/* time (reader clock) of a bar index on one deck, from its live grid */
function barTime(D, bar){ if(D.pb==null || !(D.rate>0)) return null; return D.pbT+(bar-D.pb)/D.rate; }

/* DJ MOVES make drops too: a deck brought in on its fader, its bass EQ released, its drums / bass stem faders raised -- while that deck's
   music is FULL. No foresight there (a hand), but the screen shows it within a frame. Logged as 'mixdrop' (gone the other way: 'mixcut'). */
function mixMoves(R){ var t=R.t, out=R.mv=R.mv||[]; if(!R.mix) return;
  R.decks.forEach(function(D, d){ var m=R.mix[d], pb=D.pb, st=pb==null?null:barState(D, barInfo(D, Math.floor(pb)), refs(D,t)), eff=m.gain*m.bassG;
    var g2=D.gain?Math.min(D.gain.D!=null?D.gain.D:1, D.gain.B!=null?D.gain.B:1):1; eff*=g2;
    var H=D.mvH=D.mvH||[]; H.push([t,eff]); while(H.length>2 && t-H[0][0]>1.2) H.shift(); var lo=1, hi=0, k; for(k=0;k<H.length;k++){ if(H[k][1]<lo) lo=H[k][1]; if(H[k][1]>hi) hi=H[k][1]; }
    if(D.mvAt!=null && t-D.mvAt<2) return;
    if(st==='FULL' && eff>0.6 && lo<0.25 && H[H.length-1][1]>=hi-0.05){ D.mvAt=t; out.push({type:'mixdrop', d:d, bar:Math.floor(pb), t:t, known:t, why:m.bassG<0.5?'eq':m.gain<0.5?'fader':'stems'}); if(out.length>50) out.shift(); }
    else if(st==='FULL' && hi>0.6 && eff<0.2 && lo<=eff+0.02){ D.mvAt=t; out.push({type:'mixcut', d:d, bar:Math.floor(pb), t:t, known:t}); if(out.length>50) out.shift(); } }); }

/* the reader's events: kept stable across frames (first-known time, confidence); an event's time freezes once it has happened */
function events(R){ var t=R.t, all=[];
  R.decks.forEach(function(D){ if(!D.on || D.pb==null) return; var E=deckEvents(R, D, t); D.trk=D.trk||{}; var keep={};
    E.forEach(function(e){ var key=D.track+':'+D.jumps+':'+e.type+':'+e.bar; keep[key]=1; var o=D.trk[key];
      if(!o){ o=D.trk[key]=e; o.known=t; o.knownBars=e.bar-D.pb; o.track=D.track; o.jumps=D.jumps; R.evN++; } else { o.conf=e.conf; o.gap=e.gap; o.beats=e.beats; o.len=e.len; o.hard=e.hard; o.gone=false; } });
    Object.keys(D.trk).forEach(function(k){ var o=D.trk[k]; if(o.track!==D.track || (o.jumps!==D.jumps && !o.passed)){ delete D.trk[k]; return; }
      if(!o.passed){ var tt=barTime(D, o.bar); if(tt!=null) o.t=tt; if(D.pb!=null && D.pb>=o.bar+0.02 && D.pb<o.bar+1) o.passed=true; }   /* frozen once the playhead is in that bar */
      o.inBars=o.bar-D.pb; if(!keep[k] && !o.passed) o.gone=true;
      if(o.bar<D.pb-16) delete D.trk[k]; else if(!o.gone) all.push(o); }); });
  R.ev=all; return all; }

/* ======================= what the show reads ======================= */
/* where a deck's playhead is at time t (bar index, extrapolated from its grid) */
function pbAt(D, t){ if(D.pb==null) return null; return D.pb+((D.playing && D.rate>0)?D.rate*(t-D.pbT):0); }
/* the stems at a bar position: fill 0..1 per channel (the map, i.e. what djay draws there), x this deck's gains now */
function levelsAt(R, d, b){ var D=R.decks[d], bar=Math.floor(b), A=D.map[bar], out={}; if(!A) return null; var sl=Math.max(0,Math.min(SPB-1, Math.floor((b-bar)*SPB))), ref=D.ref||{k:0.12,b:0.1,v:0.1,d:0.15};
  for(var c=0;c<CH.length;c++){ var base=(sl*CH.length+c)*NF, m=A[base]; if(!m) continue; out[CH[c]]=A[base+1]/m; if(CH[c]==='D' || CH[c]==='X') out.K=A[base+3]/m; }
  return out; }
function secAt(R, D, bar){ var ref=refs(D, R.t), st=barState(D, barInfo(D, bar), ref); if(!st) return null;
  var ev=D.trk?Object.keys(D.trk).map(function(k){ return D.trk[k]; }):[], lastDrop=null, inBuild=false;
  ev.forEach(function(e){ if((e.type==='drop' || e.type==='reentry') && e.bar<=bar && (lastDrop==null || e.bar>lastDrop)) lastDrop=e.bar; if(e.type==='build' && bar>=e.bar && bar<e.drop) inBuild=true; });
  if(st==='FULL') return (lastDrop!=null && bar-lastDrop<32)?'drop':'groove';
  if(inBuild) return 'build'; return st==='NONE'?'break':'groove'; }
/* the snapshot: view, master deck, the beat clock, each deck, the events ahead */
function state(R, tq){ var t=tq==null?R.t:tq, m=R.master==null?0:R.master, M=R.decks[m], o={v:VER, t:t, view:R.view, seen:R.viewT, master:m, clock:null, decks:[], next:[], now:null, mix:R.mix||null, n:R.n};
  var pbM=pbAt(M, t);
  if(pbM!=null && M.rate>0 && t-M.seenT<3){ var beat=pbM*4; o.clock={bpm:+(M.rate*240).toFixed(2), bar:pbM, beat:beat, phase:beat-Math.floor(beat), num:barNum(Math.floor(pbM)), bib:Math.floor(beat)-4*Math.floor(pbM), playing:M.playing, src:M.src, look:+(M.look||0).toFixed(2)}; }
  R.decks.forEach(function(D, d){ var pb=pbAt(D, t), mx=R.mix?R.mix[d]:null; o.decks.push({d:d, on:D.on && t-D.seenT<3, playing:!!(mx?mx.playing:D.playing), gain:mx?+mx.gain.toFixed(3):null, mode:D.mode, bar:pb, num:pb==null?null:barNum(Math.floor(pb)), bpm:D.rate>0?+(D.rate*240).toFixed(2):null, look:+(D.look||0).toFixed(2), loop:!!(D.loopUI || D.loop), lv:pb==null?null:levelsAt(R, d, pb), sec:pb==null?null:secAt(R, D, Math.floor(pb)), stems:D.gain||null, nm:D.nm&&t-D.nmT<5?D.nm:null, track:D.track}); });
  var ev=R.ev||[]; ev.forEach(function(e){ var D=R.decks[e.d], g=R.mix?R.mix[e.d].gain:1; if(e.t==null) return; var dt=e.t-t; if(dt<-2 || dt>120) return; if(D.loopUI && e.inBars>((D.look||2)+0.5)) return;
    o.next.push({type:e.type, d:e.d, bar:e.bar, num:barNum(e.bar), t:+e.t.toFixed(3), in:+dt.toFixed(3), inBars:+(e.bar-pbAt(D,t)).toFixed(2), conf:e.conf, gap:e.gap, beats:e.beats, len:e.len, hard:e.hard, known:+(e.known).toFixed(2), gain:+g.toFixed(3)}); });
  (R.mv||[]).forEach(function(e){ var dt=e.t-t; if(dt<-2 || dt>0.01) return; o.next.push({type:e.type, d:e.d, bar:e.bar, num:barNum(e.bar), t:+e.t.toFixed(3), in:+dt.toFixed(3), inBars:0, conf:1, known:+e.known.toFixed(2), why:e.why, gain:R.mix?+R.mix[e.d].gain.toFixed(3):1}); });
  o.next.sort(function(a,b){ return a.t-b.t; });
  if(o.decks[m] && o.decks[m].sec) o.now={sec:o.decks[m].sec, lv:o.decks[m].lv};
  return o; }

/* for pictures (the SiM's STEM VIEW): n samples of each channel's fill across bars [b0, b1) of one deck; seen = slots that were ever on screen */
function mapSample(R, d, b0, b1, n){ var D=R.decks[d], o={seen:new Float32Array(n)}, c, i; CH.forEach(function(ch){ o[ch]=new Float32Array(n); }); o.K=new Float32Array(n);
  for(i=0;i<n;i++){ var b=b0+(b1-b0)*(i+0.5)/n, bar=Math.floor(b), A=D.map[bar]; if(!A) continue; var sl=Math.max(0,Math.min(SPB-1,Math.floor((b-bar)*SPB)));
    for(c=0;c<CH.length;c++){ var base=(sl*CH.length+c)*NF, m=A[base]; if(!m) continue; o.seen[i]=1; o[CH[c]][i]=A[base+1]/m; if(CH[c]==='D' || (CH[c]==='X' && D.mode<3)) o.K[i]=A[base+3]/m; } }
  return o; }
/* one bar's section for the show: 'drop' (FULL within 32 bars of a drop), 'groove', 'build' (inside a build), 'break'; null = not seen */
function barSec(R, d, bar){ var D=R.decks[d]; if(!D.on) return null; return secAt(R, D, bar); }
function barKnown(R, d, bar){ var D=R.decks[d], o=barInfo(D, bar); return o.cov>=0.4; }

return {VER:VER, AT:AT, SPB:SPB, CH:CH, tileOf:tileOf, program:program, boxTile:boxTile, lines:lines, laneMode:laneMode, laneRows:laneRows, gridFit:gridFit, ink:ink, deckFrame:deckFrame,
  labelRead:labelRead, labelsFit:labelsFit, mixRead:mixRead, lowRead:lowRead, topRead:topRead, trRead:trRead, knob:knob, sigDiff:sigDiff, barIdx:barIdx, barNum:barNum, reader:reader, frame:frame, barSum:barSum, barInfo:barInfo, refs:refs, deckEvents:deckEvents, events:events, barTime:barTime, state:state, levelsAt:levelsAt, pbAt:pbAt, mapSample:mapSample, barSec:barSec, barKnown:barKnown};
})();
/*SR-END*/
