(function(){
const WORDMARK='__WORDMARK__';
const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
const TEX=1.06, S=1024, P=S/2/TEX; // canvas px per unit radius
const TAU=Math.PI*2;

/* ---------- drawing helpers (canvas centred on the plate) ---------- */
function rnd(seed){let s=seed;return()=>(s=(s*16807)%2147483647)/2147483647}
const ring=(x,r,w,col)=>{x.beginPath();x.arc(0,0,r*P,0,TAU);x.lineWidth=w*1.4;x.strokeStyle=col;x.stroke()};
const band=(x,r1,r2,col)=>{x.beginPath();x.arc(0,0,r2*P,0,TAU);x.arc(0,0,r1*P,0,TAU,true);x.fillStyle=col;x.fill('evenodd')};
const disc=(x,r,col)=>{x.beginPath();x.arc(0,0,r*P,0,TAU);x.fillStyle=col;x.fill()};
const MS=1.9;
function around(x,n,r,fn,off=0,ms=MS){for(let i=0;i<n;i++){const a=off+i/n*TAU;x.save();x.rotate(a);x.translate(r*P,0);if(r>0)x.scale(ms,ms);fn(i,a);x.restore()}}
function petal(x,len,wid,col,stroke){x.beginPath();x.moveTo(0,0);x.quadraticCurveTo(len*.5,-wid,len,0);x.quadraticCurveTo(len*.5,wid,0,0);x.closePath();x.fillStyle=col;x.fill();if(stroke){x.lineWidth=stroke[1];x.strokeStyle=stroke[0];x.stroke()}}
function flower(x,k,len,wid,col,center,stroke){for(let i=0;i<k;i++){x.save();x.rotate(i/k*TAU);petal(x,len,wid,col,stroke);x.restore()}if(center){x.beginPath();x.arc(0,0,len*.28,0,TAU);x.fillStyle=center;x.fill()}}
function dot(x,X,Y,r,col){x.beginPath();x.arc(X,Y,r,0,TAU);x.fillStyle=col;x.fill()}
function stroke(x,pts,w,col){x.beginPath();x.moveTo(pts[0],pts[1]);for(let i=2;i<pts.length;i+=4)x.quadraticCurveTo(pts[i],pts[i+1],pts[i+2],pts[i+3]);x.lineWidth=w;x.lineCap='round';x.strokeStyle=col;x.stroke()}
function wash(x,r,col){const g=x.createRadialGradient(0,0,0,0,0,r*P);g.addColorStop(0,col);g.addColorStop(1,'rgba(0,0,0,0)');x.fillStyle=g;x.fillRect(-S/2,-S/2,S,S)}
// a two-tone brush stroke petal (Gzhel): dark at the root, fading to the tip
function gzhelPetal(x,len,wid,col){const g=x.createLinearGradient(0,0,len,0);g.addColorStop(0,col);g.addColorStop(.75,'rgba(26,62,158,.25)');g.addColorStop(1,'rgba(26,62,158,0)');petal(x,len,wid,g)}

/* ---------- number lettering, one style per plate ---------- */
// targets: c = colour map, m = metal map (white = gold), b = bump map (white = raised)
const INK={};
function inkCentre(font,N,track){const k=font+'|'+N+'|'+(track||0);if(INK[k])return INK[k];
  const t=document.createElement('canvas');t.width=t.height=S;const x=t.getContext('2d',{willReadFrequently:true});x.font=font;if(track)x.letterSpacing=track+'px';x.textAlign='center';x.textBaseline='alphabetic';x.fillStyle='#000';x.fillText(N,S/2,S/2);
  const d=x.getImageData(0,0,S,S).data;let x0=S,x1=-1,y0=S,y1=-1;
  for(let Y=0;Y<S;Y++){const row=Y*S*4;for(let X=0;X<S;X++)if(d[row+X*4+3]>60){if(X<x0)x0=X;if(X>x1)x1=X;if(Y<y0)y0=Y;if(Y>y1)y1=Y}}
  return INK[k]=x1<0?{dx:0,dy:0}:{dx:S/2-(x0+x1+1)/2,dy:S/2-(y0+y1+1)/2}}
function letter(L,a){
  if(!a.num||a.type.mode==='none')return;
  const N=a.num, st=a.type; const {c,m,b}=L;
  let size=st.size*(N.length>3?1:N.length>2?.72:N.length>1?1:1.15);
  let font=`${st.weight||''} ${size}px ${st.font}`.trim();
  {const t=document.createElement('canvas').getContext('2d');t.font=font;const w=t.measureText(N).width,max=st.max||1.18*P;if(w>max){size=size*max/w;font=`${st.weight||''} ${size}px ${st.font}`.trim()}}
  // centre the visible ink, not the type box: digits sit above the baseline and the box includes empty space
  const o=inkCentre(font,N,st.track);const y=o.dy;
  const each=(ctx,fn)=>{if(!ctx)return;ctx.save();ctx.font=font;ctx.textAlign='center';ctx.textBaseline='alphabetic';if(st.track)ctx.letterSpacing=st.track+'px';ctx.translate(o.dx,0);fn(ctx);ctx.restore()};
  if(st.mode==='paint'){each(c,x=>{if(st.wash){x.globalAlpha=.35;x.fillStyle=st.col;x.fillText(N,4,y+3);x.globalAlpha=1}if(st.shadow){x.fillStyle=st.shadow;x.fillText(N,7,y+6)}x.fillStyle=st.col;x.fillText(N,0,y);if(st.outline){x.lineWidth=st.outline[1];x.strokeStyle=st.outline[0];x.strokeText(N,0,y)}})}
  if(st.mode==='raised'){each(c,x=>{if(st.shadow){x.fillStyle=st.shadow;x.fillText(N,6,y+6)}x.fillStyle=st.col;x.fillText(N,0,y);if(st.outline){x.lineWidth=st.outline[1];x.strokeStyle=st.outline[0];x.strokeText(N,0,y)}});
    each(b,x=>{x.filter='blur(5px)';x.fillStyle='#fff';x.fillText(N,0,y)})}
  if(st.mode==='gilt'){each(c,x=>{x.fillStyle=st.col;x.fillText(N,0,y)});each(m,x=>{x.fillStyle='#fff';x.fillText(N,0,y)});each(b,x=>{x.filter='blur(3px)';x.fillStyle='#fff';x.fillText(N,0,y)})}
  if(st.mode==='outlineGilt'){each(c,x=>{x.fillStyle=st.col;x.fillText(N,0,y);x.lineWidth=st.lw;x.strokeStyle='#C9A24A';x.strokeText(N,0,y)});each(m,x=>{x.lineWidth=st.lw;x.strokeStyle='#fff';x.strokeText(N,0,y)})}
  if(st.mode==='inlay'){each(c,x=>{x.fillStyle=st.col;x.fillText(N,0,y);x.lineWidth=st.lw;x.strokeStyle=st.edge;x.strokeText(N,0,y)});each(b,x=>{x.filter='blur(2px)';x.fillStyle='#000';x.fillText(N,0,y)})}
  if(st.mode==='dots'){ // stamped dots, sampled from the letterforms
    const t=document.createElement('canvas');t.width=t.height=S;const tx=t.getContext('2d');tx.translate(S/2,S/2);tx.font=font;tx.textAlign='center';tx.fillStyle='#000';tx.fillText(N,o.dx,y);
    const d=tx.getImageData(0,0,S,S).data;const step=st.step;
    for(let Y=0;Y<S;Y+=step)for(let X=(Y/step)%2?Math.floor(step/2):0;X<S;X+=step){if(d[(Y*S+X)*4+3]>128){dot(c,X-S/2,Y-S/2,st.r,st.col);if(b)dot(b,X-S/2,Y-S/2,st.r*.8,'#fff')}}
  }
}

/* ---------- the twenty plates ---------- */
const COB='#1F428F';
// draw a motif so the middle of what is actually drawn lands on the plate's centre
const CEN={};
function centred(x,key,fn){let o=CEN[key];if(!o){const t=document.createElement('canvas');t.width=t.height=S;const c=t.getContext('2d',{willReadFrequently:true});c.translate(S/2,S/2);fn(c);
  const d=c.getImageData(0,0,S,S).data;let x0=S,x1=-1,y0=S,y1=-1;for(let Y=0;Y<S;Y++)for(let X=0;X<S;X++)if(d[(Y*S+X)*4+3]>40){if(X<x0)x0=X;if(X>x1)x1=X;if(Y<y0)y0=Y;if(Y>y1)y1=Y}
  o=CEN[key]=x1<0?{dx:0,dy:0}:{dx:S/2-(x0+x1+1)/2,dy:S/2-(y0+y1+1)/2}}
  x.save();x.translate(o.dx,o.dy);fn(x);x.restore()}
function star(x,R,r,col){x.beginPath();for(let i=0;i<10;i++){const t=-Math.PI/2+i*Math.PI/5,q=i%2?r:R;x.lineTo(q*Math.cos(t),q*Math.sin(t))}x.closePath();x.fillStyle=col;x.fill()}
// Delft/Gzhel/Jingdezhen style tulip spray: stem, two leaves, a cupped tulip
function tulip(x,col,wash){
  stroke(x,[0,30,-4,10,0,-6],4,col);
  for(const s of[-1,1]){x.save();x.translate(0,18);x.rotate(s>0?-.55:Math.PI+.55);petal(x,28,9,col);x.restore()}
  x.save();x.translate(0,-6);
  if(wash){x.globalAlpha=.3;x.beginPath();x.moveTo(-14,4);x.quadraticCurveTo(-18,-22,-5,-32);x.quadraticCurveTo(0,-16,5,-32);x.quadraticCurveTo(18,-22,14,4);x.closePath();x.fillStyle=col;x.fill();x.globalAlpha=1}
  x.beginPath();x.moveTo(-11,2);x.quadraticCurveTo(-15,-18,-4,-27);x.quadraticCurveTo(0,-14,4,-27);x.quadraticCurveTo(15,-18,11,2);x.closePath();x.lineWidth=3;x.strokeStyle=col;x.stroke();
  x.beginPath();x.moveTo(0,0);x.lineTo(0,-16);x.stroke();x.restore();
}
function lattice(x,a0,a1,r0,r1,col){ // diamond diaper clipped to a rim panel
  x.save();x.beginPath();x.arc(0,0,r1*P,a0,a1);x.arc(0,0,r0*P,a1,a0,true);x.closePath();x.clip();
  x.lineWidth=2;x.strokeStyle=col;for(let k=-S;k<S;k+=22){x.beginPath();x.moveTo(k,-S);x.lineTo(k+S,0);x.stroke();x.beginPath();x.moveTo(k,S);x.lineTo(k+S,0);x.stroke()}
  x.restore();
}
function rose(x,col,k=7,len=34,wid=14){for(let i=0;i<k;i++){x.save();x.rotate(i/k*TAU);gzhelPetal(x,len,wid,col);x.restore()}for(let i=0;i<5;i++){x.save();x.rotate(i/5*TAU+.3);gzhelPetal(x,len*.55,wid*.7,col);x.restore()}dot(x,0,0,len*.2,col)}
function crane(x){
  x.beginPath();x.ellipse(0,0,20,7,0,0,TAU);x.fillStyle='#F4F1E8';x.fill();x.lineWidth=1.5;x.strokeStyle='#2C2F2A';x.stroke();
  for(const s of[-1,1]){x.beginPath();x.moveTo(-4,0);x.quadraticCurveTo(-10,s*34,8,s*44);x.quadraticCurveTo(10,s*20,8,0);x.closePath();x.fillStyle='#F4F1E8';x.fill();x.stroke();
    x.beginPath();x.moveTo(4,s*30);x.quadraticCurveTo(8,s*40,8,s*44);x.lineWidth=5;x.strokeStyle='#2C2F2A';x.stroke();x.lineWidth=1.5}
  stroke(x,[20,0,30,-4,38,-2],3,'#2C2F2A');dot(x,38,-2,4,'#2C2F2A');dot(x,36,-4,1.6,'#C23A2B');stroke(x,[-20,0,-30,2,-42,6],2,'#2C2F2A');stroke(x,[-20,0,-30,6,-40,12],2,'#2C2F2A');
}
function crackle(x,seed,col,n,len){const r=rnd(seed);x.strokeStyle=col;x.lineWidth=1.2;for(let i=0;i<n;i++){let a=r()*TAU,d=(.15+r()*.85)*P,X=d*Math.cos(a),Y=d*Math.sin(a);x.beginPath();x.moveTo(X,Y);for(let k=0;k<4;k++){X+=(r()-.5)*len;Y+=(r()-.5)*len;x.lineTo(X,Y)}x.stroke()}}
function kintsugiSeams(x,col,w){ // gold-filled breaks: three seams that meet off-centre, with branches
  const r=rnd(23);
  const seam=(pts,ww)=>{x.beginPath();x.moveTo(pts[0][0]*P,pts[0][1]*P);for(const p of pts.slice(1))x.lineTo(p[0]*P,p[1]*P);x.lineWidth=ww;x.lineJoin='round';x.lineCap='round';x.strokeStyle=col;x.stroke()};
  const jag=(a,b,n)=>{const o=[a];for(let i=1;i<n;i++){const t=i/n;o.push([a[0]+(b[0]-a[0])*t+(r()-.5)*.05,a[1]+(b[1]-a[1])*t+(r()-.5)*.05])}o.push(b);return o};
  const hub=[.18,-.2];
  seam(jag([-1.0,-.32],hub,9),w);seam(jag(hub,[.62,-.8],7),w*.85);seam(jag(hub,[.45,.92],10),w);
  seam(jag([.3,.18],[.98,.12],6),w*.6);seam(jag([-.2,-.27],[-.55,.55],7),w*.55);seam(jag([.38,-.5],[.95,-.38],4),w*.45);
}

const A=[
// ---- Dishes logged ----
{id:'d1',g:'Dishes logged',n:'First dish',num:'1',dish:'Burrata at Bar Liberty',date:'Sun 14 Sep 2026',
 plate:'Diner restaurant ware',from:'United States, early 1900s',what:'Thick vitrified hotel china with two green bands, the plate every diner served on.',
 shape:{profile:'diner'},body:'#F5F0E4',glaze:{rough:.3},
 type:{mode:'paint',font:'"Alfa Slab One", serif',size:250,col:'#2F6B45'},
 draw(x){band(x,.85,.935,'#2F6B45');band(x,.79,.805,'#2F6B45');wash(x,.6,'rgba(255,255,255,.4)');
  }},
{id:'d10',g:'Dishes logged',n:'10 dishes',num:'10',dish:'Pork Xiao Long Bao at HuTong',date:'Mon 29 Sep 2026',
 plate:'Bolesławiec stoneware',from:'Silesia, Poland, 1800s onward',what:'Hand sponge-stamped cobalt "peacock eyes" on heavy cream stoneware.',
 shape:{profile:'rim',thick:1.3},body:'#F3EFE6',glaze:{rough:.3},
 type:{mode:'dots',font:'"Archivo Black", sans-serif',size:340,col:COB,step:17,r:7.2},
 draw(x){band(x,.955,1.01,COB);around(x,60,.983,()=>dot(x,0,0,3.2,'#fff'));
  around(x,16,.85,()=>{dot(x,0,0,30,COB);dot(x,0,0,21,'#5E9C4B');dot(x,0,0,13,'#F3EFE6');dot(x,0,0,8,COB);for(let k=0;k<10;k++){const t=k/10*TAU;dot(x,25*Math.cos(t),25*Math.sin(t),2.4,'#F3EFE6')}},0,1.35);
  around(x,16,.85,()=>{dot(x,0,0,5,COB)},TAU/32,1.6);ring(x,.74,4,COB);around(x,48,.705,()=>dot(x,0,0,4,'#5E9C4B'))}},
{id:'d25',g:'Dishes logged',n:'25 dishes',num:'25',dish:'Cacio e Pepe at Tipo 00',date:'Sat 18 Oct 2026',
 plate:'Delftware',from:'Delft, the Netherlands, 1600s',what:'Tin-glazed earthenware painted in cobalt: rim panels alternating tulip sprays and lattice, with a wreath in the well.',
 shape:{profile:'rim'},body:'#F6F4EE',glaze:{rough:.18},
 type:{mode:'paint',font:'"IM Fell English", serif',weight:'italic',size:240,col:'#24489A',wash:true},
 draw(x){const C='#24489A';ring(x,.985,8,C);ring(x,.958,2,C);ring(x,.742,4,C);ring(x,.72,1.5,C);
  for(let i=0;i<8;i++){const a0=i/8*TAU,a1=(i+1)/8*TAU;x.save();x.rotate(a0);x.beginPath();x.moveTo(.742*P,0);x.lineTo(.958*P,0);x.lineWidth=3;x.strokeStyle=C;x.stroke();x.restore();
    if(i%2)lattice(x,a0+.03,a1-.03,.77,.93,'rgba(36,72,154,.85)')}
  around(x,4,.85,()=>{ // a full flower spray filling the panel
    for(const s of[-1,1]){x.save();x.rotate(s*Math.PI/2);x.globalAlpha=.35;petal(x,44,13,C);x.globalAlpha=1;petal(x,38,8,C);x.restore();
      x.save();x.translate(-6,s*30);x.rotate(s*Math.PI/2+s*.6);petal(x,18,6,C);x.restore();dot(x,8,s*44,4,C);dot(x,-10,s*48,3,C)}
    x.globalAlpha=.3;flower(x,6,20,10,C);x.globalAlpha=1;flower(x,6,17,6,C);dot(x,0,0,6,'#F6F4EE');dot(x,0,0,3.5,C)},TAU/16,1.55);
  // wreath of small leaves around the number
  for(let k=0;k<22;k++){const t=k/22*TAU;if(Math.abs(t-Math.PI/2)<.4)continue;x.save();x.rotate(t);x.translate(.42*P,0);x.rotate(Math.PI/2+.5);x.globalAlpha=.4;petal(x,34,12,C);x.globalAlpha=1;petal(x,30,8,C);x.restore()}
  x.save();x.translate(0,.42*P);stroke(x,[-30,-12,0,6,30,-12],4,C);dot(x,0,4,7,C);x.restore()}},
{id:'d50',g:'Dishes logged',n:'50 dishes',num:'50',dish:'Lamb Shoulder at Rumi',date:'Thu 30 Oct 2026',
 plate:'Iznik',from:'İznik, Türkiye, 1500s',what:'Tulips and carnations in cobalt, turquoise and raised tomato red, with the wave-and-rock border.',
 shape:{profile:'deep'},body:'#FBF8F0',glaze:{rough:.15},
 type:{mode:'raised',font:'"Reem Kufi", sans-serif',weight:'700',size:250,col:'#C23A2B',outline:['#2A1E1A',3]},
 draw(x){band(x,.92,1.02,'#1C3F8C');
  around(x,20,.96,()=>{x.beginPath();x.arc(0,0,22,Math.PI*.5,Math.PI*1.9);x.lineWidth=6;x.strokeStyle='#FBF8F0';x.stroke();x.beginPath();x.arc(4,-4,9,0,TAU);x.lineWidth=3;x.stroke()},0,1);
  ring(x,.915,3,'#2A1E1A');ring(x,.7,3,'#2A1E1A');ring(x,.68,7,'#2BA39F');
  around(x,6,.72,(i)=>{x.rotate(Math.PI/2);
    stroke(x,[0,70,0,30,0,0],4,'#3E8A4C');x.save();x.translate(0,-10);
    x.beginPath();x.moveTo(-18,10);x.quadraticCurveTo(-22,-30,-6,-46);x.quadraticCurveTo(0,-20,6,-46);x.quadraticCurveTo(22,-30,18,10);x.closePath();x.fillStyle=i%2?'#C23A2B':'#1C3F8C';x.fill();x.lineWidth=2.5;x.strokeStyle='#2A1E1A';x.stroke();x.restore();
    x.save();x.translate(-26,40);x.rotate(-.9);petal(x,40,10,'#3E8A4C',['#2A1E1A',2]);x.restore();x.save();x.translate(26,40);x.rotate(Math.PI+.9);petal(x,40,10,'#3E8A4C',['#2A1E1A',2]);x.restore()});
  around(x,6,.6,()=>{flower(x,8,16,6,'#2BA39F','#1C3F8C',['#2A1E1A',1.5])},TAU/12)}},
{id:'d100',g:'Dishes logged',n:'100 dishes',num:'100',dish:'Spanner Crab Omelette at Supernormal',date:'Sat 25 Oct 2026',
 plate:'Imari',from:'Arita, Japan, late 1600s',what:'Panels of underglaze blue and iron red picked out in gold, on a lobed rim.',
 shape:{profile:'rim',edge:{type:'scallop',n:12,amp:.022}},body:'#FAF6EC',glaze:{rough:.16},metalPass:true,
 type:{mode:'outlineGilt',font:'"Shippori Mincho B1", serif',weight:'800',size:240,col:'#B3302A',lw:7},
 draw(x,mode){const gold=mode==='m'?'#fff':'#C9A24A',skip=mode==='m';
  for(let i=0;i<6;i++){const a0=i/6*TAU,a1=(i+1)/6*TAU;x.beginPath();x.arc(0,0,1.0*P,a0,a1);x.arc(0,0,.74*P,a1,a0,true);x.closePath();if(!skip){x.fillStyle=i%2?'#24407E':'#FAF6EC';x.fill()}}
  around(x,6,.87,(i)=>{x.rotate(Math.PI/2);if(i%2){for(let k=-1;k<=1;k++){x.beginPath();x.arc(k*40,0,16,0,Math.PI*1.6);x.lineWidth=4;x.strokeStyle=gold;x.stroke()}}
    else if(!skip){flower(x,16,34,7,'#B3302A','#C9A24A');flower(x,16,20,5,'#D9584A')}else dot(x,0,0,10,'#fff')},TAU/12);
  for(let i=0;i<6;i++){x.save();x.rotate(i/6*TAU);x.beginPath();x.moveTo(.74*P,0);x.lineTo(1.0*P,0);x.lineWidth=4;x.strokeStyle=gold;x.stroke();x.restore()}
  ring(x,.735,6,gold);if(!skip){ring(x,.66,10,'#B3302A')}ring(x,.63,3,gold);ring(x,.995,6,gold)}},
{id:'d250',g:'Dishes logged',n:'250 dishes',num:'250',dish:'Duck à l\'Orange at France-Soir',date:'Sun 3 May 2027',
 plate:'Royal Copenhagen Blue Fluted',from:'Copenhagen, Denmark, 1775',what:'Fluted ribs, fine lace edging and chrysanthemum sprays, all in cobalt.',
 shape:{profile:'rim',edge:{type:'flute',n:44,amp:.012}},body:'#F7F7F4',glaze:{rough:.14},
 type:{mode:'paint',font:'"Cormorant Garamond", serif',weight:'italic 600',size:240,col:'#1C3D8F'},
 draw(x){const C='#1C3D8F';
  around(x,44,0,()=>{x.beginPath();x.moveTo(.76*P,0);x.lineTo(.95*P,0);x.lineWidth=4;x.strokeStyle='rgba(28,61,143,.55)';x.stroke()});
  around(x,88,.985,()=>{x.beginPath();x.arc(0,0,7,Math.PI*.5,Math.PI*1.5);x.lineWidth=3;x.strokeStyle=C;x.stroke()},0,1);
  ring(x,.958,2,C);ring(x,.75,3,C);ring(x,.735,1.5,C);
  // four sprays over the ribs, each a branch of three flowers
  around(x,4,.855,()=>{x.rotate(Math.PI/2);stroke(x,[-34,8,-10,-10,30,4],3,C);
    for(const [X,Y,s] of [[-30,6,.8],[0,-6,1],[28,4,.8]]){x.save();x.translate(X,Y);x.scale(s,s);flower(x,8,14,5,C,'#F7F7F4');dot(x,0,0,3,C);x.restore()}
    for(const [X,Y,a] of [[-16,14,2.2],[14,14,.9],[-40,-4,3.6]]){x.save();x.translate(X,Y);x.rotate(a);petal(x,16,5,C);x.restore()}},TAU/8,2.4);
  x.save();x.translate(0,.44*P);x.scale(1.9,1.9);stroke(x,[-40,0,0,-14,40,0],3,C);flower(x,8,16,6,C,'#F7F7F4');dot(x,0,0,4,C);for(const s of[-1,1]){x.save();x.translate(s*30,-4);x.rotate(s>0?-.4:Math.PI+.4);petal(x,18,6,C);x.restore()}x.restore()}},
{id:'d500',g:'Dishes logged',n:'500 dishes',num:'500',dish:'Lobster Thermidor at Grossi Florentino',date:'Fri 1 Oct 2027',
 plate:'Sèvres',from:'Sèvres, France, 1700s',what:'A wide rim in royal blue, laurel garlands in raised gold, and a gold wreath around the centre.',
 shape:{profile:'wide'},body:'#FFFFFF',glaze:{rough:.12},metalPass:true,bumpPass:true,
 type:{mode:'gilt',font:'"Cinzel Decorative", serif',weight:'700',size:200,col:'#C79B3B'},
 draw(x,mode){const g=mode?'#fff':'#C9A24A';
  if(!mode)band(x,.75,.965,'#1D3A8A');
  ring(x,.75,8,g);ring(x,.965,8,g);ring(x,.995,5,g);ring(x,.72,2,g);
  around(x,36,.858,()=>{x.rotate(Math.PI/2);x.save();x.rotate(-.5);petal(x,26,7,g);x.restore();x.save();x.rotate(Math.PI+.5);petal(x,26,7,g);x.restore();dot(x,0,-14,3.5,g)});
  ring(x,.858,2.5,g);
  for(const s of[-1,1])for(let k=0;k<12;k++){const t=Math.PI/2+s*(.35+k*.18);x.save();x.rotate(t);x.translate(.46*P,0);x.rotate(s*.6);petal(x,48,14,g);x.restore()}
  x.save();x.translate(0,.48*P);x.beginPath();x.moveTo(-26,-6);x.quadraticCurveTo(0,20,26,-6);x.lineWidth=5;x.strokeStyle=g;x.stroke();x.restore()}},
// ---- Scores you gave ----
{id:'s5',g:'Scores you gave',n:'First 5.0',num:'5.0',dish:'Pavlova at Fratelli House',date:'Thu 2 Oct 2026',
 plate:'Coalport jewelled porcelain',from:'Shropshire, England, 1890s',what:'The grandest English table porcelain: a claret ground under raised gold scrolls, set with turquoise enamel "jewels", on a gadrooned gold edge. Five raised gold stars ring the well.',
 shape:{profile:'wide',edge:{type:'gadroon',n:40,amp:.018}},body:'#FBF6EA',glaze:{rough:.1},metalPass:true,bumpPass:true,
 type:{mode:'gilt',font:'"Playfair Display", serif',weight:'italic 900',size:300,col:'#C99A3A'},
 draw(x,mode){const G=mode?'#fff':'#C9A24A',J=mode==='m'?'#000':mode==='b'?'#fff':'#2FB0AA';
  const jewel=(r)=>{dot(x,0,0,r,J);if(!mode){x.lineWidth=1.5;x.strokeStyle='#8A6A22';x.beginPath();x.arc(0,0,r,0,TAU);x.stroke();dot(x,-r*.3,-r*.3,r*.35,'rgba(255,255,255,.75)')}};
  if(!mode){band(x,.7,.955,'#5C0F1F');x.save();x.beginPath();x.arc(0,0,.955*P,0,TAU);x.arc(0,0,.7*P,0,TAU,true);x.clip('evenodd');
    const rg=x.createRadialGradient(0,0,.7*P,0,0,.955*P);rg.addColorStop(0,'rgba(0,0,0,.3)');rg.addColorStop(.5,'rgba(255,255,255,.04)');rg.addColorStop(1,'rgba(0,0,0,.3)');x.fillStyle=rg;x.fillRect(-S/2,-S/2,S,S);x.restore()}
  band(x,.955,1.04,G);
  if(!mode)around(x,40,.995,()=>{x.beginPath();x.moveTo(-.035*P,0);x.lineTo(.04*P,0);x.lineWidth=3;x.strokeStyle='rgba(120,85,20,.5)';x.stroke()},0,1);
  ring(x,.7,7,G);ring(x,.675,2,G);
  around(x,12,.83,()=>{x.rotate(Math.PI/2);x.lineWidth=5;x.strokeStyle=G;x.lineCap='round';
    for(const s of[-1,1]){x.beginPath();x.moveTo(0,10);x.bezierCurveTo(s*14,10,s*30,-2,s*30,-14);x.bezierCurveTo(s*30,-25,s*20,-27,s*16,-19);x.stroke();
      x.save();x.translate(s*8,16);x.rotate(s>0?.3:Math.PI-.3);petal(x,24,6,G);x.restore()}
    x.save();x.translate(0,-4);jewel(9);x.restore()},0,1.5);
  around(x,12,.83,()=>jewel(7),TAU/24,1.4);
  around(x,60,.93,()=>dot(x,0,0,3.5,G),0,1);around(x,60,.725,()=>dot(x,0,0,3,G),0,1);
  around(x,5,.53,()=>{x.rotate(Math.PI/2);star(x,30,13,G)},-Math.PI/2,1);
  ring(x,.44,3,G);ring(x,.62,2,G)}},
{id:'s6',g:'Scores you gave',n:'First 6',num:'6',dish:'Kouign-Amann at Lune',date:'Wed 22 Oct 2026',
 plate:'Imperial yellow porcelain',from:'Jingdezhen, China, Qing dynasty',what:'A yellow glaze only the emperor could use, incised tone-on-tone with waves and clouds, with a gold rim.',
 shape:{profile:'rim'},body:'#F0C232',glaze:{rough:.12},metalPass:true,bumpPass:true,
 type:{mode:'paint',font:'"Zen Antique", serif',size:300,col:'#7A2E14'},
 draw(x,mode){const inc=mode==='b'?'#000':(mode==='m'?null:'#C99A12');const g=mode==='m'||mode==='b'?'#fff':'#D4AF37';
  if(!mode){const rg=x.createRadialGradient(-.3*P,-.35*P,0,0,0,P);rg.addColorStop(0,'rgba(255,240,170,.55)');rg.addColorStop(1,'rgba(180,120,0,.18)');x.fillStyle=rg;x.fillRect(-S/2,-S/2,S,S)}
  if(inc){ // incised waves on the rim and cloud scrolls in the well
    x.save();x.beginPath();x.arc(0,0,.95*P,0,TAU);x.arc(0,0,.76*P,0,TAU,true);x.clip('evenodd');
    for(let row=0;row<5;row++){const r0=.78+row*.04;for(let k=0;k<48;k++){const t=k/48*TAU+(row%2)*TAU/96;x.beginPath();x.arc(r0*P*Math.cos(t),r0*P*Math.sin(t),16,t+Math.PI*.9,t+Math.PI*2.1);x.lineWidth=2.4;x.strokeStyle=inc;x.stroke()}}x.restore();
    around(x,8,.56,()=>{x.rotate(Math.PI/2);x.lineWidth=2.6;x.strokeStyle=inc;for(const s of[-1,1]){x.beginPath();x.arc(s*14,0,12,0,TAU*.8);x.stroke();x.beginPath();x.arc(s*14,0,6,0,TAU*.7);x.stroke()}x.beginPath();x.moveTo(-26,8);x.quadraticCurveTo(0,22,26,8);x.stroke()},TAU/16,1.6);
    ring(x,.42,1.6,inc);ring(x,.4,1,inc)}
  if(mode!=='b'){ring(x,.995,9,g);ring(x,.755,3,g)}}},
{id:'s05',g:'Scores you gave',n:'First 0.5',num:'0.5',dish:'Truffle Fries at The Crafty Squire',date:'Tue 4 Nov 2026',
 plate:'Kintsugi',from:'Japan, 1400s onward',what:'A dark raku plate, broken and mended with gold. An honest score is worth keeping.',
 shape:{profile:'coupe'},body:'#25201E',glaze:{rough:.45,clear:.5},metalPass:true,bumpPass:true,
 type:{mode:'gilt',font:'"Yuji Syuku", serif',size:250,col:'#D4AF37'},
 draw(x,mode){const g=mode?'#fff':'#D4AF37';
  if(!mode){const r=rnd(31);for(let i=0;i<1400;i++){const t=r()*TAU,d=Math.sqrt(r())*1.02*P;dot(x,d*Math.cos(t),d*Math.sin(t),.5+r()*2.2,`rgba(${150+r()*60|0},${120+r()*40|0},${100+r()*30|0},${.06+r()*.14})`)}
    const rg=x.createRadialGradient(0,0,.2*P,0,0,P);rg.addColorStop(0,'rgba(90,60,40,.0)');rg.addColorStop(.85,'rgba(120,80,50,.25)');rg.addColorStop(1,'rgba(20,14,12,.4)');x.fillStyle=rg;x.fillRect(-S/2,-S/2,S,S)}
  kintsugiSeams(x,g,mode==='b'?9:6)}},
// ---- One-offs ----
{id:'odrink',g:'One-offs',n:'First drink',num:null,kind:'glass',sym:'a clear cut window with a frosted engraved vine',dish:'Mezcal Negroni at Bar Margaux',date:'Fri 10 Oct 2026',
 plate:'Bohemian ruby glass',from:'Bohemia, Czech lands, 1800s',what:'A goblet flashed with ruby glass, cut through to clear windows and facets, with a gold rim. Turn it round for the engraving.',
 type:{mode:'none'}},
{id:'odessert',g:'One-offs',n:'First dessert',num:null,sym:'none: the leaf is the award',backInk:'#2F5A2A',dish:'Pastel de Nata at Fábrica',date:'Sat 11 Oct 2026',
 plate:'Bordallo Pinheiro cabbage leaf',from:'Caldas da Rainha, Portugal, 1880s',what:'Majolica moulded as a cabbage leaf, with raised veins and a pale heart.',
 shape:{profile:'coupe',edge:{type:'leaf',n:16,amp:.05}},body:'#7FB25E',glaze:{rough:.14},bumpPass:true,
 type:{mode:'none'},
 draw(x,mode){if(mode==='b'){x.fillStyle='#808080';x.fillRect(-S/2,-S/2,S,S);x.strokeStyle='#fff';
    for(let k=0;k<16;k++){const t=k/16*TAU;x.save();x.rotate(t);stroke(x,[.18*P,0,.6*P,6,1.0*P,-4],9,'#fff');for(let j=1;j<5;j++){const r0=(.3+j*.15)*P;stroke(x,[r0,2,r0+26,-12,r0+50,-30],4,'#fff');stroke(x,[r0,2,r0+26,16,r0+50,34],4,'#fff')}x.restore()}return}
  const rg=x.createRadialGradient(0,0,0,0,0,P);rg.addColorStop(0,'#F2F0C8');rg.addColorStop(.38,'#DCE9B0');rg.addColorStop(.62,'#9CC772');rg.addColorStop(.9,'#5E9A46');rg.addColorStop(1,'#3E7A34');x.fillStyle=rg;x.fillRect(-S/2,-S/2,S,S);
  for(let k=0;k<16;k++){const t=k/16*TAU;x.save();x.rotate(t);stroke(x,[.2*P,0,.6*P,6,1.0*P,-4],7,'rgba(245,245,210,.75)');for(let j=1;j<5;j++){const r0=(.3+j*.15)*P;stroke(x,[r0,2,r0+26,-12,r0+50,-30],3,'rgba(245,245,210,.55)');stroke(x,[r0,2,r0+26,16,r0+50,34],3,'rgba(245,245,210,.55)')}x.restore()}}},
{id:'ocountry',g:'One-offs',n:'Dish in a new country',num:null,sym:'a compass rose',backInk:'#FFFFFF',dish:'Pho Bo at Phở Thìn, Hanoi',date:'Mon 19 Jan 2027',
 plate:'Rishtan lyagan',from:'Rishtan, Uzbekistan, on the Silk Road',what:'Turquoise "ishkor" ash glaze over almonds and flowers, on a broad flat serving dish, with a compass rose for the journey.',
 shape:{profile:'wide'},body:'#1E85A3',glaze:{rough:.12},
 type:{mode:'none'},
 draw(x){const g=x.createRadialGradient(0,0,0,0,0,P);g.addColorStop(0,'#2A9DB8');g.addColorStop(1,'#145F80');x.fillStyle=g;x.fillRect(-S/2,-S/2,S,S);
  band(x,.95,1.02,'#0F3E58');around(x,72,.985,()=>dot(x,0,0,3,'#F5F1E6'),0,1);
  around(x,14,.86,()=>{x.rotate(Math.PI/2);x.beginPath();x.moveTo(0,30);x.bezierCurveTo(30,10,20,-30,0,-38);x.bezierCurveTo(-8,-20,-24,6,0,30);x.fillStyle='#F5F1E6';x.fill();x.lineWidth=2;x.strokeStyle='#0F3E58';x.stroke();
    x.beginPath();x.moveTo(0,22);x.bezierCurveTo(16,8,12,-18,2,-26);x.lineWidth=3;x.strokeStyle='#8A4B2A';x.stroke();dot(x,4,-4,3,'#1E85A3')});
  ring(x,.74,4,'#F5F1E6');ring(x,.72,1.5,'#0F3E58');
  around(x,8,.58,()=>{flower(x,5,22,11,'#F5F1E6','#8A4B2A',['#0F3E58',1.5])},TAU/16);
  const W='#F5F1E6',D='#0F3E58';ring(x,.4,3,W);around(x,32,.4,()=>dot(x,0,0,3,W),0,1);
  for(let i=0;i<8;i++){const L=(i%2?.22:.34)*P,w=(i%2?.045:.065)*P;x.save();x.rotate(i/8*TAU-Math.PI/2);for(const sd of[-1,1]){x.beginPath();x.moveTo(0,0);x.lineTo(L,0);x.lineTo(w*.9,sd*w);x.closePath();x.fillStyle=sd>0?W:'#BFDDE3';x.fill();x.lineWidth=2;x.lineJoin='round';x.strokeStyle=D;x.stroke()}x.restore()}
  dot(x,0,0,.055*P,'#8A4B2A');x.lineWidth=2;x.strokeStyle=D;x.beginPath();x.arc(0,0,.055*P,0,TAU);x.stroke();dot(x,0,0,.022*P,W)}},
{id:'owith',g:'One-offs',n:'Ate with someone',num:null,sym:'a roundel of two cranes in flight, inlaid',backInk:'#FFFFFF',dish:'Peking Duck at Flower Drum, with @paris',date:'Sat 1 Nov 2026',
 plate:'Goryeo celadon',from:'Korea, 1100s',what:'Grey-green celadon inlaid in white and black with cranes flying in pairs, on a lobed dish, and two cranes circling each other at the centre.',
 shape:{profile:'coupe',edge:{type:'scallop',n:6,amp:.03}},body:'#A9C2A6',glaze:{rough:.12},
 type:{mode:'none'},
 draw(x){const g=x.createRadialGradient(0,0,.2*P,0,0,P);g.addColorStop(0,'rgba(80,120,90,.0)');g.addColorStop(.7,'rgba(70,110,80,.22)');g.addColorStop(1,'rgba(255,255,255,.12)');x.fillStyle=g;x.fillRect(-S/2,-S/2,S,S);
  crackle(x,9,'rgba(60,90,70,.12)',50,50);
  ring(x,.93,3,'#F4F1E8');ring(x,.92,1.4,'#2C2F2A');
  around(x,3,.74,()=>{x.rotate(Math.PI/2+.25);x.save();x.translate(-22,-14);crane(x);x.restore();x.save();x.translate(22,18);crane(x);x.restore()},0,2.0);
  around(x,6,.86,()=>{for(let k=0;k<3;k++){x.beginPath();x.arc(k*14-14,0,9,Math.PI,TAU);x.lineWidth=3;x.strokeStyle='#F4F1E8';x.stroke()}},TAU/12);
  ring(x,.47,3,'#F4F1E8');around(x,24,.47,()=>{x.rotate(Math.PI/2);petal(x,22,7,'#F4F1E8',['#2C2F2A',1])});
  ring(x,.4,1.4,'#2C2F2A');
  around(x,4,.3,()=>{x.lineWidth=2.5;x.strokeStyle='#F4F1E8';x.beginPath();x.arc(0,0,9,Math.PI,TAU*.95);x.stroke();x.beginPath();x.arc(15,3,6,Math.PI,TAU*.9);x.stroke()},Math.PI/4,1.5);
  around(x,2,.14,()=>{x.rotate(Math.PI/2);x.translate(-8,0);crane(x)},-Math.PI/2+.4,2.6)}},
{id:'osave',g:'One-offs',n:'Dish saved by someone',num:null,sym:'a lotus in copper red',backInk:'#22408C',dish:'Kingfish Crudo at Saint Peter, saved by @paris',date:'Fri 24 Oct 2026',
 plate:'Jingdezhen blue-and-white',from:'Jingdezhen, China, Ming dynasty',what:'Cobalt lotus scrolls in layered washes and a cloud-collar border, with a lotus in copper red at the centre, the hardest colour a Ming kiln could fire.',
 shape:{profile:'rim'},body:'#F3F6F7',glaze:{rough:.12},
 type:{mode:'none'},
 draw(x){const C='#22408C';band(x,.965,1.01,C);ring(x,.94,3,C);
  x.beginPath();for(let i=0;i<=360;i++){const t=i/360*TAU,r=(.85+.045*Math.sin(t*8))*P;i?x.lineTo(r*Math.cos(t),r*Math.sin(t)):x.moveTo(r*Math.cos(t),r*Math.sin(t))}x.lineWidth=5;x.strokeStyle=C;x.stroke();
  around(x,8,.85,()=>{x.rotate(Math.PI/2);x.globalAlpha=.35;for(let k=-2;k<=2;k++){x.save();x.rotate(-Math.PI/2+k*.4);petal(x,34,12,C);x.restore()}x.globalAlpha=1;for(let k=-2;k<=2;k++){x.save();x.rotate(-Math.PI/2+k*.4);petal(x,30,7,C);x.restore()}dot(x,0,-2,5,C);
    for(const s of[-1,1]){x.save();x.translate(s*26,10);x.rotate(s>0?.4:Math.PI-.4);x.globalAlpha=.45;petal(x,24,10,C);x.globalAlpha=1;petal(x,20,5,C);x.restore()}},0,1.6);
  // ruyi cloud collar pointing into the well
  around(x,12,.715,()=>{x.rotate(Math.PI/2);x.beginPath();x.moveTo(-22,-6);x.bezierCurveTo(-22,14,-6,10,0,22);x.bezierCurveTo(6,10,22,14,22,-6);x.lineWidth=3;x.strokeStyle=C;x.stroke();x.globalAlpha=.25;x.fillStyle=C;x.fill();x.globalAlpha=1},0,1.3);
  ring(x,.745,3,C);ring(x,.45,2.5,C);
  const R='#A4232B';centred(x,'lotus',x=>{x.scale(3.3,3.3);
  for(const s of[-1,1]){x.save();x.translate(s*10,10);x.rotate(s>0?.35:Math.PI-.35);x.globalAlpha=.4;petal(x,46,16,C);x.globalAlpha=1;petal(x,40,8,C);x.restore()}
  stroke(x,[0,8,-3,22,0,34],3,C);
  for(const k of[-3,3,-2,2,-1,1,0]){x.save();x.translate(0,4);x.rotate(-Math.PI/2+k*.3);const L=50-Math.abs(k)*6;x.globalAlpha=.45;petal(x,L,16,R);x.globalAlpha=1;petal(x,L-4,9,R);x.lineWidth=1;x.strokeStyle='#7A1520';x.stroke();x.restore()}
  })}},
{id:'o10s',g:'One-offs',n:'10 saves',num:'10',dish:'Your dishes have been saved 10 times',date:'Sun 9 Nov 2026',
 plate:'Wedgwood jasperware',from:'Staffordshire, England, 1770s',what:'Unglazed pale-blue stoneware with white cameo laurels and beading in raised relief.',
 shape:{profile:'rim'},body:'#8EA8C8',glaze:{rough:.85,clear:0},bumpPass:true,
 type:{mode:'raised',font:'"Bodoni Moda", serif',weight:'600',size:250,col:'#F7F6F2'},
 draw(x,mode){const W=mode==='b'?'#fff':'#F7F6F2';
  around(x,72,.97,()=>dot(x,0,0,6,W),0,1);ring(x,.93,4,W);
  around(x,40,.84,()=>{x.rotate(Math.PI/2);x.save();x.rotate(-.45);petal(x,30,9,W);x.restore();x.save();x.rotate(Math.PI+.45);petal(x,30,9,W);x.restore()},0,1.6);
  ring(x,.745,5,W);ring(x,.72,2,W);
  for(const s of[-1,1])for(let k=0;k<9;k++){const t=Math.PI/2+s*(.5+k*.2);x.save();x.rotate(t);x.translate(.5*P,0);x.rotate(s*.7);petal(x,44,13,W);x.restore()}
  x.save();x.translate(0,.52*P);dot(x,0,0,10,W);x.restore()}},
{id:'o3same',g:'One-offs',n:'Same dish 3 times',num:null,sym:'three Gzhel roses',backInk:'#1A3E9E',dish:'Pork Xiao Long Bao at HuTong, third time',date:'Wed 12 Nov 2026',
 plate:'Gzhel',from:'Gzhel, Russia, 1800s',what:'The "Gzhel rose": single cobalt brushstrokes that fade from deep to pale, with a grass border.',
 shape:{profile:'rim'},body:'#FBFBFD',glaze:{rough:.12},
 type:{mode:'none'},
 draw(x){const C='#1A3E9E';ring(x,.99,7,C);ring(x,.962,2,C);ring(x,.742,4,C);
  around(x,96,.95,()=>{x.rotate(Math.PI);gzhelPetal(x,22,4,C)},0,1);
  around(x,8,.85,()=>{x.rotate(Math.PI/2);rose(x,C,8,32,14);for(const s of[-1,1]){x.save();x.translate(s*36,6);x.rotate(s>0?.2:Math.PI-.2);gzhelPetal(x,26,9,C);x.restore()}},0,1.9);
  around(x,8,.85,()=>{x.rotate(Math.PI/2);stroke(x,[-12,6,0,-8,12,6],3,C);dot(x,0,-12,4,C);dot(x,-8,-16,3,C);dot(x,8,-16,3,C)},TAU/16,1.8);
  around(x,3,.33,()=>{x.rotate(Math.PI/2);for(const s of[-1,1]){x.save();x.translate(s*8,0);x.rotate(s>0?-.35:Math.PI+.35);gzhelPetal(x,34,11,C);x.restore()}},Math.PI/2,2.6);
  around(x,3,.24,()=>rose(x,C,8,30,15),-Math.PI/2,3.1)}},
{id:'o5entry',g:'One-offs',n:'5 dishes in one entry',num:null,sym:'five raised bowl rings',backInk:'#4A3212',dish:'Banquet at Shandong Mama, 5 dishes',date:'Sat 15 Nov 2026',
 plate:'Brass thali',from:'Rajasthan, India',what:'A hammered brass thali, the plate built to hold a whole meal, with five raised bowl rings and engraved bands.',
 shape:{profile:'thali'},body:'#C79A4A',glaze:{rough:.3,clear:.25,metal:.95,allMetal:true},bumpPass:true,
 type:{mode:'none'},
 draw(x,mode){if(mode==='b'){x.fillStyle='#808080';x.fillRect(-S/2,-S/2,S,S);const r=rnd(5);for(let i=0;i<900;i++){const t=r()*TAU,d=Math.sqrt(r())*P;dot(x,d*Math.cos(t),d*Math.sin(t),6+r()*10,`rgba(${r()<.5?0:255},${r()<.5?0:255},${r()<.5?0:255},.06)`)}
    for(const rr of[.9,.86,.36])ring(x,rr,3,'#000');around(x,5,.62,()=>{x.beginPath();x.arc(0,0,.16*P,0,TAU);x.lineWidth=14;x.strokeStyle='#fff';x.stroke()},-Math.PI/2,1);ring(x,.98,10,'#fff');
    x.save();x.rotate(-Math.PI/2);flower(x,12,.24*P,.05*P,'rgba(0,0,0,0)',null,['#000',4]);x.restore();ring(x,.27,3,'#000');dot(x,0,0,.04*P,'#fff');return}
  const r=rnd(5);for(let i=0;i<900;i++){const t=r()*TAU,d=Math.sqrt(r())*P;dot(x,d*Math.cos(t),d*Math.sin(t),6+r()*10,r()<.5?'rgba(255,230,170,.07)':'rgba(90,60,20,.07)')}
  for(const rr of[.9,.86,.36])ring(x,rr,2,'#6B4A1C');around(x,72,.88,()=>dot(x,0,0,2.4,'#6B4A1C'),0,1);
  around(x,5,.62,(i)=>{x.beginPath();x.arc(0,0,.16*P,0,TAU);x.lineWidth=6;x.strokeStyle='#E8C27A';x.stroke();x.beginPath();x.arc(0,0,.13*P,0,TAU);x.lineWidth=2;x.strokeStyle='#6B4A1C';x.stroke()},-Math.PI/2,1);
  x.save();x.rotate(-Math.PI/2);flower(x,12,.24*P,.05*P,'rgba(0,0,0,0)',null,['#6B4A1C',2.4]);x.restore();ring(x,.27,2,'#6B4A1C');dot(x,0,0,.04*P,'#E8C27A')}},
{id:'o3day',g:'One-offs',n:'3 entries in one day',num:null,sym:'a morning sun, a midday sun and a crescent moon',backInk:'#22449A',dish:'Breakfast, lunch and dinner on Sat 22 Nov',date:'Sat 22 Nov 2026',
 plate:'Fez pottery',from:'Fez, Morocco',what:'Cobalt on white in eight-point stars and interlaced zellij geometry, with the day painted across the centre: morning sun, midday sun, moon.',
 shape:{profile:'deep'},body:'#F3EEE3',glaze:{rough:.2},
 type:{mode:'none'},
 draw(x){const C='#22449A';band(x,.95,1.02,C);around(x,64,.985,()=>dot(x,0,0,2.6,'#F3EEE3'),0,1);
  around(x,24,.86,(i)=>{x.rotate(Math.PI/2);x.beginPath();x.moveTo(0,-34);x.lineTo(16,0);x.lineTo(0,34);x.lineTo(-16,0);x.closePath();x.fillStyle=i%2?C:'rgba(34,68,154,.35)';x.fill();x.lineWidth=1.5;x.strokeStyle=C;x.stroke()},0,1.5);
  ring(x,.77,5,C);ring(x,.745,2,C);
  for(const [r1,r2,w,off] of [[.43,.56,5,0],[.47,.61,2,TAU/32]]){x.beginPath();for(let i=0;i<16;i++){const r=(i%2?r1:r2)*P,t=i/16*TAU-Math.PI/2+off;x.lineTo(r*Math.cos(t),r*Math.sin(t))}x.closePath();x.lineWidth=w;x.strokeStyle=C;x.stroke()}
  around(x,8,.66,()=>{x.rotate(Math.PI/4);x.fillStyle=C;x.fillRect(-8,-8,16,16)},TAU/16,1);
  around(x,8,.505,()=>dot(x,0,0,5,C),0,1);
  const sun=(r,n,ray)=>{for(let k=0;k<n;k++){x.save();x.rotate(k/n*TAU);x.beginPath();x.moveTo(r+5,-5);x.lineTo(r+ray,0);x.lineTo(r+5,5);x.closePath();x.fillStyle=C;x.fill();x.restore()}dot(x,0,0,r,C);dot(x,0,0,r*.55,'#F3EEE3');dot(x,0,0,r*.3,C)};
  x.save();x.translate(-.26*P,.08*P);x.scale(1.75,1.75);sun(22,8,14);x.restore();
  x.save();x.translate(0,-.1*P);x.scale(1.6,1.6);sun(32,12,18);x.restore();
  x.save();x.translate(.26*P,.08*P);x.scale(1.7,1.7);dot(x,0,0,30,C);dot(x,13,-9,27,'#F3EEE3');x.save();x.translate(14,-4);x.rotate(.2);star(x,10,4,C);x.restore();x.restore()}},
{id:'o5place',g:'One-offs',n:'5 dishes at one place',num:null,sym:'five pomegranates around a rosette',backInk:'#1F3E8C',dish:'Five dishes at Tipo 00',date:'Thu 27 Nov 2026',
 plate:'Deruta majolica',from:'Deruta, Umbria, Italy, 1500s',what:'Renaissance majolica: ochre acanthus scrolls on a cobalt rim, with green and yellow bands, and five pomegranates, the Umbrian sign of plenty, at the centre.',
 shape:{profile:'rim'},body:'#F4E9CF',glaze:{rough:.16},
 type:{mode:'none'},
 draw(x){const B='#1F3E8C',O='#D9962B',G='#4E8A3C';band(x,.76,.97,B);ring(x,.985,6,O);ring(x,.755,6,O);ring(x,.725,4,G);
  around(x,10,.865,(i)=>{x.rotate(Math.PI/2);x.lineWidth=4;x.strokeStyle=O;x.beginPath();x.moveTo(-34,8);x.bezierCurveTo(-20,-22,10,-22,12,0);x.bezierCurveTo(14,14,0,16,-2,6);x.stroke();
    for(const [X,Y,a] of [[-24,-8,-2.3],[-6,-16,-1.6],[14,-10,-.6]]){x.save();x.translate(X,Y);x.rotate(a);petal(x,16,6,O);x.restore()}dot(x,26,6,6,'#F4E9CF');dot(x,26,6,3,G)},0,2.1);
  ring(x,.5,3,B);around(x,32,.5,(i)=>dot(x,0,0,4,i%2?O:G),0,1);
  around(x,5,.27,()=>{x.rotate(Math.PI/2);for(const s of[-1,1]){x.save();x.translate(s*6,6);x.rotate(s>0?-.5:Math.PI+.5);petal(x,26,8,G,[B,1.5]);x.restore()}},-Math.PI/2+TAU/10,2.0);
  around(x,5,.28,()=>{x.rotate(Math.PI/2);dot(x,0,0,24,'#C9542A');x.lineWidth=3;x.strokeStyle=B;x.beginPath();x.arc(0,0,24,0,TAU);x.stroke();
    x.beginPath();x.moveTo(-9,-21);x.lineTo(-6,-33);x.lineTo(0,-26);x.lineTo(6,-33);x.lineTo(9,-21);x.closePath();x.fillStyle=O;x.fill();x.lineWidth=2;x.stroke();
    for(const[X,Y]of[[-7,3],[4,-4],[7,9],[-2,13],[-11,-6],[10,-12]])dot(x,X,Y,3,'#F4E9CF');dot(x,-9,-9,5,'rgba(255,255,255,.3)')},-Math.PI/2,2.25);
  flower(x,8,40,14,O,B,[B,2])}}
];
const TINTC={};
function tint(x,img,col,w){const h=Math.round(w*359/758);const k=col+w;let t=TINTC[k];if(!t){t=document.createElement('canvas');t.width=w*2;t.height=h*2;const tx=t.getContext('2d');tx.drawImage(img,0,0,w*2,h*2);tx.globalCompositeOperation='source-in';tx.fillStyle=col;tx.fillRect(0,0,w*2,h*2);TINTC[k]=t}x.drawImage(t,-w/2,-h/2,w,h)}
function arcText(x,text,r,top,font,col,sp){x.save();x.font=font;x.fillStyle=col;x.textAlign='center';x.textBaseline='middle';
  const ch=[...text],w=ch.map(c=>x.measureText(c).width+sp),tot=w.reduce((a,b)=>a+b,0)-sp,ang=tot/r;let acc=0;
  for(let i=0;i<ch.length;i++){const mid=acc+(w[i]-sp)/2;const a=top?-Math.PI/2-ang/2+mid/r:Math.PI/2+ang/2-mid/r;x.save();x.rotate(a);x.translate(r,0);x.rotate(top?Math.PI/2:-Math.PI/2);x.fillText(ch[i],0,0);x.restore();acc+=w[i]}x.restore()}
function wrap(x,text,maxW){const words=text.split(' ');const lines=[];let cur='';for(const w of words){const t=cur?cur+' '+w:w;if(x.measureText(t).width>maxW&&cur){lines.push(cur);cur=w}else cur=t}if(cur)lines.push(cur);return lines}

/* ---------- textures ---------- */
function blank(col){const c=document.createElement('canvas');c.width=c.height=S;const x=c.getContext('2d');x.translate(S/2,S/2);if(col){x.fillStyle=col;x.fillRect(-S/2,-S/2,S,S)}return [c,x]}
function maps(a,off){
  const [cc,c]=blank(off?'#F2EEE7':a.body);
  if(off) return {c:cc};
  a.draw(c,null);
  let mm=null,bb=null,m=null,b=null;
  if(a.metalPass||['gilt','outlineGilt'].includes(a.type.mode)){[mm,m]=blank('#000');if(a.metalPass)a.draw(m,'m')}
  if(a.bumpPass||['raised','gilt','inlay','dots','seal'].includes(a.type.mode)){[bb,b]=blank('#808080');if(a.bumpPass)a.draw(b,'b')}
  letter({c,m,b},a);
  return {c:cc,m:mm,b:bb};
}
// The backstamp: everything sits inside the foot ring, with a clear margin.
function back(a,off){
  const [cc,x]=blank(off?'#F2EEE7':a.body);if(off)return cc;
  const ink=a.backInk||(['#FFFFFF','#F7F6F2','#F4F1E8'].includes(a.type.col)?'#FFFFFF':a.type.col);
  if(a.id==='s05'){x.globalAlpha=.6}
  const R=.47*P; // inside the foot ring at .53
  x.beginPath();x.arc(0,0,R,0,TAU);x.lineWidth=2.5;x.strokeStyle=ink;x.stroke();
  x.beginPath();x.arc(0,0,R-12,0,TAU);x.lineWidth=1;x.stroke();
  arcText(x,a.n.toUpperCase(),R-38,true,'600 25px "Bricolage Grotesque", sans-serif',ink,4);
  arcText(x,'MADE FOR @EAMON',R-38,false,'600 21px "Bricolage Grotesque", sans-serif',ink,4);
  if(wordImg){x.save();x.translate(0,-62);tint(x,wordImg,ink,150);x.restore()}
  x.fillStyle=ink;x.textAlign='center';x.textBaseline='alphabetic';
  x.font='italic 400 27px Newsreader, Georgia, serif';
  const lines=wrap(x,a.dish,250).slice(0,3);let y=lines.length>2?6:22;
  for(const l of lines){x.fillText(l,0,y);y+=32}
  x.font='500 21px "Bricolage Grotesque", sans-serif';x.fillText(a.date,0,y+10);
  x.globalAlpha=1;
  return cc;
}

/* ---------- geometry: profile revolved, then shaped at the edge ---------- */
const PROF={
 rim:{top:[[0,.075],[.5,.075],[.62,.078],[.69,.095],[.735,.135],[.8,.165],[.9,.19],[.97,.205],[1.0,.208],[1.018,.2]],
      lip:[[1.018,.2],[1.026,.186],[1.024,.172],[1.012,.162]],
      bot:[[1.012,.162],[.95,.15],[.82,.12],[.72,.075],[.64,.03],[.6,0],[.585,-.022],[.56,-.026],[.54,-.018],[.53,.008],[.4,.018],[0,.02]]},
 wide:{top:[[0,.07],[.55,.072],[.66,.08],[.72,.12],[.76,.15],[.9,.165],[.98,.172],[1.012,.17]],
      lip:[[1.012,.17],[1.022,.158],[1.02,.144],[1.006,.136]],
      bot:[[1.006,.136],[.9,.13],[.76,.11],[.7,.07],[.64,.03],[.62,0],[.6,-.024],[.575,-.028],[.555,-.02],[.545,.008],[.4,.016],[0,.018]]},
 deep:{top:[[0,.06],[.42,.062],[.55,.09],[.65,.17],[.72,.25],[.8,.29],[.92,.315],[1.0,.325],[1.018,.318]],
      lip:[[1.018,.318],[1.028,.302],[1.024,.286],[1.01,.278]],
      bot:[[1.01,.278],[.9,.26],[.78,.23],[.68,.15],[.58,.06],[.5,.0],[.485,-.026],[.46,-.03],[.44,-.02],[.43,.008],[.3,.014],[0,.016]]},
 coupe:{top:[[0,.07],[.45,.072],[.65,.09],[.8,.13],[.9,.17],[.97,.205],[1.0,.22],[1.014,.214]],
      lip:[[1.014,.214],[1.02,.2],[1.016,.188],[1.004,.182]],
      bot:[[1.004,.182],[.92,.15],[.8,.105],[.66,.06],[.56,.02],[.52,0],[.5,-.02],[.48,-.024],[.46,-.016],[.45,.008],[.3,.014],[0,.016]]},
 thali:{top:[[0,.04],[.82,.04],[.9,.048],[.95,.08],[.985,.15],[1.0,.175],[1.012,.178]],
      lip:[[1.012,.178],[1.02,.168],[1.018,.156],[1.004,.15]],
      bot:[[1.004,.15],[.97,.1],[.93,.04],[.88,.005],[.8,0],[0,0]]},
 diner:{top:[[0,.1],[.5,.1],[.62,.105],[.7,.13],[.76,.175],[.86,.205],[.95,.225],[.99,.235]],
      lip:[[.99,.235],[1.02,.225],[1.035,.195],[1.03,.16],[1.0,.14]],
      bot:[[1.0,.14],[.9,.12],[.78,.09],[.68,.05],[.6,0],[.585,-.03],[.555,-.035],[.53,-.025],[.52,.008],[.4,.02],[0,.022]]}
};
function edgeFn(edge){
  if(!edge) return null;
  const sm=(r)=>Math.max(0,Math.min(1,(r-.6)/.35));
  if(edge.type==='scallop') return (r,t)=>[r*(1+edge.amp*sm(r)*(Math.abs(Math.cos(t*edge.n/2))*2-1)),0];
  if(edge.type==='gadroon'){const g=(r)=>Math.max(0,Math.min(1,(r-.93)/.06));return (r,t)=>{const c=Math.cos(t*edge.n);return [r*(1+.008*g(r)*c),edge.amp*g(r)*c]}}
  if(edge.type==='flute') return (r,t)=>[r*(1+.006*sm(r)*Math.cos(t*edge.n)),edge.amp*sm(r)*Math.cos(t*edge.n)];
  if(edge.type==='leaf'){const L=edge.n,v=Array.from({length:L},(_, i)=>.7+.6*((Math.sin(i*12.9898)*43758.5453)%1+1)%1);return (r,t)=>{const tt=((t%TAU)+TAU)%TAU,i=Math.floor(tt/TAU*L)%L;const s=Math.pow(Math.abs(Math.sin(tt*L/2)),.45);return [r*(1+edge.amp*sm(r)*(s*v[i]-.55)),.03*sm(r)*Math.sin(tt*L)*s]}}
  if(edge.type==='octagon'){const n=edge.n,k=Math.PI/n;return (r,t)=>{let u=((t%(2*k))+2*k)%(2*k)-k;const poly=Math.cos(k)/Math.cos(u);return [r*(1+(poly*1.035-1)*sm(r)),0]}}
}
function lathe(pts,flipU,shape,thick){
  const g=new THREE.LatheGeometry(pts.map(p=>new THREE.Vector2(p[0],p[1]*thick)),200);
  const pos=g.attributes.position,uv=g.attributes.uv,f=edgeFn(shape.edge);
  for(let i=0;i<pos.count;i++){const X=pos.getX(i),Z=pos.getZ(i),Y=pos.getY(i);
    uv.setXY(i,(flipU?-X:X)/(2*TEX)+.5,1-(Z/(2*TEX)+.5));
    if(f){const r=Math.hypot(X,Z),t=Math.atan2(X,Z);const [r2,dy]=f(r,t);if(r>1e-6){pos.setX(i,X*r2/r);pos.setZ(i,Z*r2/r)}pos.setY(i,Y+dy)}}
  uv.needsUpdate=true;g.computeVertexNormals();return g;
}

/* ---------- scene ---------- */
let wordImg=null;
const canvas=document.getElementById('stage');
const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:true,preserveDrawingBuffer:true});
renderer.setPixelRatio(Math.min(2,devicePixelRatio||1));
renderer.outputEncoding=THREE.sRGBEncoding;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.05;
renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
const scene=new THREE.Scene();
const camera=new THREE.PerspectiveCamera(28,1,.1,50);camera.position.set(0,0,6.3);
(function env(){const pm=new THREE.PMREMGenerator(renderer);const s=new THREE.Scene();
  s.add(new THREE.Mesh(new THREE.BoxGeometry(12,12,12),new THREE.MeshBasicMaterial({color:0x564d48,side:THREE.BackSide})));
  const panel=(w,h,x,y,z,c,ry,rx)=>{const m=new THREE.Mesh(new THREE.PlaneGeometry(w,h),new THREE.MeshBasicMaterial({color:c,side:THREE.DoubleSide}));m.position.set(x,y,z);m.rotation.set(rx||0,ry||0,0);s.add(m)};
  panel(6,3,-2,4.5,2,0xffffff,0,Math.PI/2);panel(2.4,4,-5.8,1,1,0xfff1e2,Math.PI/2);panel(1.4,4,5.8,0,0,0xe6ecfb,-Math.PI/2);panel(8,1.2,0,-1,5.9,0xd8cdc1,0);
  scene.environment=pm.fromScene(s,.035).texture})();
const key=new THREE.DirectionalLight(0xffffff,.85);key.position.set(-1.6,2.6,6);key.castShadow=true;key.shadow.mapSize.set(1024,1024);key.shadow.radius=6;scene.add(key);
scene.add(new THREE.AmbientLight(0xffffff,.15));
const pivot=new THREE.Group();scene.add(pivot);
const plate=new THREE.Group();plate.rotation.x=Math.PI/2;pivot.add(plate);
const catcher=new THREE.Mesh(new THREE.PlaneGeometry(8,8),new THREE.ShadowMaterial({opacity:.10}));catcher.position.z=-.6;catcher.receiveShadow=true;scene.add(catcher);
let meshes=[],live=[];
function tex(c,srgb){const t=new THREE.CanvasTexture(c);if(srgb)t.encoding=THREE.sRGBEncoding;t.anisotropy=8;return t}
const glassG=new THREE.Group();pivot.add(glassG);
let dark=false;const shadowOp=()=>dark?.3:.1;
function build(a,off){
  for(const g of[plate,glassG])while(g.children.length){const m=g.children.pop();if(m.geometry)m.geometry.dispose()}for(const o of live)o.dispose();meshes=[];live=[];
  curKind=a.kind||null;catcher.material.opacity=a.kind==='glass'?0:shadowOp();
  if(a.kind==='glass')return buildGlass(a,off);
  const pr=PROF[a.shape.profile],th=a.shape.thick||1;
  const gTop=lathe(pr.top.concat(pr.lip),false,a.shape,th),gBot=lathe(pr.bot,true,a.shape,th);
  const mp=maps(a,off);const fc=tex(mp.c,true),bc=tex(back(a,off),true);live.push(fc,bc);
  const gl=a.glaze||{};const base={roughness:off?.8:(gl.rough??.2),clearcoat:off?0:(gl.clear??1),clearcoatRoughness:.06,metalness:0,envMapIntensity:off?.4:1.1,side:THREE.DoubleSide};
  const top=new THREE.MeshPhysicalMaterial(Object.assign({map:fc},base));
  if(!off&&mp.m){const t=tex(mp.m);live.push(t);top.metalnessMap=t;top.metalness=1;top.roughnessMap=null}
  if(!off&&gl.metal){top.metalness=gl.metal;top.metalnessMap=null}
  if(!off&&mp.b){const t=tex(mp.b);live.push(t);top.bumpMap=t;top.bumpScale=.012}
  const bot=new THREE.MeshPhysicalMaterial(Object.assign({map:bc},base,{metalness:gl.allMetal?gl.metal:0}));
  live.push(top,bot);
  const m1=new THREE.Mesh(gTop,top),m2=new THREE.Mesh(gBot,bot);m1.castShadow=m2.castShadow=true;plate.add(m1,m2);meshes=[m1,m2];
}
/* ---------- the glass: a ruby-flashed Bohemian goblet; the engraving is on the far side ---------- */
function glassTex(a,off){
  const W=2048,H=1024,c=document.createElement('canvas'),m=document.createElement('canvas');c.width=m.width=W;c.height=m.height=H;
  const x=c.getContext('2d'),mx=m.getContext('2d');mx.fillStyle='#000';mx.fillRect(0,0,W,H);
  const CLEAR='rgba(222,231,238,.22)',FROST='rgba(244,240,242,.6)';x.fillStyle=CLEAR;x.fillRect(0,0,W,H);
  if(off)return {c,m:null};
  const FL=690;  // the ruby flash runs from the rim down to here; below it is clear cut glass
  x.fillStyle='rgba(152,12,40,.96)';x.fillRect(0,0,W,FL);
  const g=x.createLinearGradient(0,0,0,FL);g.addColorStop(0,'rgba(50,0,10,.35)');g.addColorStop(1,'rgba(50,0,10,0)');x.fillStyle=g;x.fillRect(0,0,W,FL);
  const gold=(fn)=>{for(const [ctx,col] of [[x,'#D4AF37'],[mx,'#fff']]){ctx.save();fn(ctx,col);ctx.restore()}};
  const windowAt=(cx,cy,rx,ry)=>{x.save();x.beginPath();x.ellipse(cx,cy,rx,ry,0,0,TAU);x.clip();x.clearRect(cx-rx,cy-ry,rx*2,ry*2);x.fillStyle=FROST;x.fillRect(cx-rx,cy-ry,rx*2,ry*2);x.restore();
    gold((k,col)=>{k.beginPath();k.ellipse(cx,cy,rx+5,ry+5,0,0,TAU);k.lineWidth=6;k.strokeStyle=col;k.stroke()})};
  // front: a tall oval window engraved with a vine; round "printies" at the sides; olive cuts along the flash edge
  gold((k,col)=>{k.beginPath();k.ellipse(512,350,140,220,0,0,TAU);k.lineWidth=7;k.strokeStyle=col;k.stroke();k.beginPath();k.ellipse(512,350,128,208,0,0,TAU);k.lineWidth=2.5;k.stroke()});
  for(const cx of[0,1024,2048])windowAt(cx,330,62,62);
  for(let cx=64;cx<W;cx+=128){if(cx>1290&&cx<1780)continue;windowAt(cx,620,22,40)}
  gold((k,col)=>{k.fillStyle=col;k.fillRect(0,0,W,22);k.fillRect(0,34,W,4);k.fillRect(0,FL-3,W,6)});
  // the frosted vine in the front window
  x.save();x.translate(512,350);x.scale(.8,1);const F='rgba(255,232,236,.9)';
  stroke(x,[0,190,-30,90,10,0,50,-90,0,-180],6,F);
  for(const [X,Y,a] of[[-20,120,-2.4],[18,40,-.6],[-6,-50,-2.6],[30,-120,-.5]]){x.save();x.translate(X,Y);x.rotate(a);petal(x,70,26,F);x.restore()}
  for(const [cx,cy] of[[40,95],[-40,-5]])for(let r=0;r<4;r++)for(let k=0;k<=3-r;k++)dot(x,cx+(k-(3-r)/2)*20,cy+r*18,9,F);
  x.restore();
  // below the flash: cut flutes
  x.fillStyle='rgba(140,12,38,.97)';x.fillRect(0,FL+3,W,H-FL-3);
  for(let cx=0;cx<W;cx+=64){const fg=x.createLinearGradient(cx-30,0,cx+30,0);fg.addColorStop(0,'rgba(255,190,200,0)');fg.addColorStop(.5,'rgba(255,200,210,.3)');fg.addColorStop(1,'rgba(255,190,200,0)');
    x.fillStyle=fg;x.beginPath();x.moveTo(cx-26,FL+14);x.lineTo(cx+26,FL+14);x.lineTo(cx+4,H);x.lineTo(cx-4,H);x.closePath();x.fill()}
  // the engraving, cut through the ruby on the far side
  x.save();x.translate(1536,0);x.scale(.8,1);const E='rgba(255,232,236,.9)';
  if(wordImg){x.save();x.translate(0,150);tint(x,wordImg,'#FFE8EC',230);x.restore()}
  x.fillStyle=E;x.textAlign='center';x.textBaseline='alphabetic';
  x.font='600 34px "Bricolage Grotesque", sans-serif';x.letterSpacing='6px';x.fillText(a.n.toUpperCase(),0,282);x.letterSpacing='0px';
  x.font='italic 400 44px Newsreader, Georgia, serif';const lines=wrap(x,a.dish,420).slice(0,3);let y=360;for(const l of lines){x.fillText(l,0,y);y+=52}
  x.font='500 32px "Bricolage Grotesque", sans-serif';x.fillText(a.date,0,y+12);
  x.font='600 26px "Bricolage Grotesque", sans-serif';x.letterSpacing='5px';x.fillText('MADE FOR @EAMON',0,y+86);
  x.restore();
  return {c,m};
}
function buildGlass(a,off){
  const B0=.57,BH=1.43,pts=[new THREE.Vector2(.0005,B0-.004)];for(let i=0;i<=64;i++){const t=i/64;pts.push(new THREE.Vector2(.045+.535*Math.pow(Math.sin(t*Math.PI/2),.8),B0+BH*t))}
  const bowl=new THREE.LatheGeometry(pts,180,-Math.PI/2,TAU);
  const gt=glassTex(a,off);const t=tex(gt.c,true);live.push(t);
  const mat=new THREE.MeshPhysicalMaterial({map:t,roughness:.05,metalness:gt.m?1:0,clearcoat:1,clearcoatRoughness:.03,envMapIntensity:1.8,side:THREE.FrontSide});
  if(gt.m){const mt=tex(gt.m);live.push(mt);mat.metalnessMap=mt}
  // foot and stem: one smooth curve, many segments, solid ruby glass so it reads on any background
  const fp=new THREE.SplineCurve([[0,0],[.3,0],[.41,.004],[.44,.016],[.42,.032],[.3,.05],[.16,.08],[.085,.15],[.07,.26],[.085,.33],[.125,.385],[.09,.44],[.068,.5],[.06,.555],[.05,.6]].map(p=>new THREE.Vector2(p[0],p[1]))).getPoints(220);
  const foot=new THREE.LatheGeometry(fp,200);
  const fmat=off?new THREE.MeshPhysicalMaterial({color:0xE4E9EC,roughness:.08,clearcoat:1,envMapIntensity:1.6}):new THREE.MeshPhysicalMaterial({color:new THREE.Color(0x7E0C22).convertSRGBToLinear(),roughness:.06,clearcoat:1,clearcoatRoughness:.03,envMapIntensity:1.8});
  live.push(mat,fmat);
  // the inside wall first, then the outside, so the far side shows through the glass rather than over it
  const inner=mat.clone();inner.side=THREE.BackSide;inner.color=new THREE.Color(.55,.5,.5);live.push(inner);
  const m1=new THREE.Mesh(foot,fmat),m2=new THREE.Mesh(bowl,inner),m3=new THREE.Mesh(bowl,mat);m1.renderOrder=1;m2.renderOrder=2;m3.renderOrder=3;glassG.add(m1,m2,m3);
  if(!off){const rm=new THREE.MeshPhysicalMaterial({color:0xD4AF37,metalness:1,roughness:.22,envMapIntensity:1.4});live.push(rm);const rim=new THREE.Mesh(new THREE.TorusGeometry(.58,.014,12,180),rm);rim.rotation.x=Math.PI/2;rim.position.y=B0+BH;glassG.add(rim);
    for(const [r,y,w] of[[.438,.016,.009],[.124,.385,.008],[.07,.555,.012]]){const g=new THREE.Mesh(new THREE.TorusGeometry(r,w,12,180),rm);g.rotation.x=Math.PI/2;g.position.y=y;glassG.add(g)}}
  glassG.scale.setScalar(.98);glassG.position.y=-1.0*.98;
}
function show(a){
  build(a,false);
  document.getElementById('t').textContent=a.n;
  document.getElementById('o').textContent=a.plate+', '+a.from;
  document.getElementById('w').textContent=a.dish;
  document.getElementById('d').textContent=a.date;
}

/* ---------- motion ---------- */
let spinZ=0,curKind=null,rot=0,vel=0,tilt=0,drag=false,lastX=0,lastY=0,lastT=0,target=0,intro=null,idle=0;
function resize(){const w=canvas.clientWidth;renderer.setSize(w,w,false)}
canvas.addEventListener('pointerdown',e=>{drag=true;if(intro){intro=null;pivot.position.set(0,0,0);key.position.x=-1.6;canvas.style.opacity=1}lastX=e.clientX;lastY=e.clientY;lastT=performance.now();canvas.setPointerCapture(e.pointerId)});
canvas.addEventListener('pointermove',e=>{if(!drag)return;const now=performance.now(),dx=e.clientX-lastX,dy=e.clientY-lastY,dt=Math.max(8,now-lastT);const k=Math.PI/canvas.clientWidth*1.4;rot+=dx*k;tilt=Math.max(-.5,Math.min(.5,tilt+dy*k*.5));vel=dx*k/dt*16;lastX=e.clientX;lastY=e.clientY;lastT=now});
const end=()=>{if(!drag)return;drag=false;target=Math.round((rot+vel*12)/Math.PI)*Math.PI};
canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',end);
document.getElementById('flip').onclick=()=>{if(intro){intro=null;pivot.position.set(0,0,0);key.position.x=-1.6;canvas.style.opacity=1}target=Math.round(rot/Math.PI)*Math.PI+Math.PI;vel=reduce?0:.02;if(reduce)rot=target};
document.getElementById('play').onclick=()=>playIntro();
function playIntro(){if(reduce){rot=target=0;return}intro={t0:performance.now()};target=0;vel=0;tilt=0}
let last=performance.now();
function tick(now){const dt=Math.min(50,now-last)/16.67;last=now;
  if(intro){const t=Math.min(1,(now-intro.t0)/2200),e=1-Math.pow(1-t,4),u=1-e;const sw=Math.sin(e*Math.PI);if(curKind==='glass'){rot=-TAU*u;spinZ=0;tilt=.18*sw}else{rot=-.55*sw;spinZ=-TAU*u;tilt=.4*Math.sin(e*Math.PI*1.25)*(1-e*.6)}pivot.position.z=-1.6*u;pivot.position.y=-.22*u;canvas.style.opacity=Math.min(1,t*3);key.position.x=-1.6+5*u;if(t>=1){intro=null;pivot.position.set(0,0,0);rot=0;tilt=0;target=0;vel=0;key.position.x=-1.6;canvas.style.opacity=1}}
  else if(!drag){vel=(vel+(target-rot)*.045*dt)*Math.pow(.88,dt);rot+=vel*dt;tilt+=(0-tilt)*.06*dt;idle+=.012*dt}
  pivot.rotation.y=rot;pivot.rotation.x=tilt+(drag||intro?0:Math.sin(idle)*.07);pivot.rotation.y+=(drag||intro?0:Math.sin(idle*.8+1)*.09);pivot.rotation.z=intro?spinZ:(drag?0:Math.sin(idle*.7)*.03);
  renderer.render(scene,camera);requestAnimationFrame(tick)}

/* ---------- the set, rendered from the same plates ---------- */
function shoot(a,off){pivot.position.set(0,0,0);pivot.rotation.set(a.kind==='glass'?.22:-.32,.38,0);build(a,off);renderer.render(scene,camera);return renderer.domElement.toDataURL('image/png')}
function grid(){
  const sets=document.getElementById('sets');sets.innerHTML='';const groups={};
  for(const a of A){if(!groups[a.g]){const h=document.createElement('div');h.className='grp';h.textContent=a.g;const r=document.createElement('div');r.className='row';sets.append(h,r);groups[a.g]=r}
    const b=document.createElement('button');b.className='th';b.setAttribute('aria-pressed',a.id==='d25');b.innerHTML=`<div class="ph"></div><div class="n">${a.n}</div>`;
    b.onclick=()=>{sets.querySelectorAll('.th').forEach(x=>x.setAttribute('aria-pressed','false'));b.setAttribute('aria-pressed','true');show(a);playIntro();canvas.scrollIntoView({behavior:reduce?'auto':'smooth',block:'center'})};
    groups[a.g].appendChild(b);a.btn=b}
  // render the stills one per frame so the page stays responsive
  const size=renderer.getSize(new THREE.Vector2());let i=0;
  const step=()=>{if(i>=A.length){renderer.setSize(size.x,size.y,false);camera.position.z=6.3;catcher.visible=true;show(A.find(a=>a.id===(window.PLATE_START||'d25')));playIntro();requestAnimationFrame(tick);window.plateShow=(id)=>{show(A.find(a=>a.id===id));playIntro()};window.dispatchEvent(new CustomEvent('plates-ready',{detail:A}));return}
    const SZ=window.PLATE_STILL||220;renderer.setSize(SZ,SZ,false);camera.position.z=4.7;catcher.visible=false;const a=A[i++];const url=shoot(a,false);a.url=url;if(window.PLATE_OFF)a.offUrl=shoot(a,true);
    a.btn.querySelector('.ph').outerHTML=`<img alt="" src="${url}">`;setTimeout(step,0)};
  step();
}
function table(){const tb=document.querySelector('#tbl tbody');let g='',h='';
  const how={paint:'painted',raised:'raised in thick glaze',gilt:'raised gold',outlineGilt:'red, outlined in gold',inlay:'inlaid white with a black edge',dots:'built from stamped dots'};
  for(const a of A){if(a.g!==g){g=a.g;h+=`<tr class="g"><td colspan="4">${g}</td></tr>`}
    const num=a.num?`${a.type.font.split(',')[0].replace(/"/g,'')}, ${how[a.type.mode]}`:`No number: ${a.sym}`;
    h+=`<tr><td>${a.n}</td><td>${a.plate}<br><span style="color:var(--muted)">${a.from}</span></td><td>${a.what}</td><td>${num}</td></tr>`}
  tb.innerHTML=h}

function setTheme(t){document.documentElement.dataset.theme=t;dark=t==='dark';document.querySelectorAll('.seg button').forEach(b=>b.setAttribute('aria-pressed',b.dataset.t===t));if(catcher.material.opacity>0)catcher.material.opacity=shadowOp()}
document.querySelectorAll('.seg button').forEach(b=>b.onclick=()=>setTheme(b.dataset.t));
setTheme(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
function start(){resize();addEventListener('resize',resize);table();grid()}
const img=new Image();img.onload=()=>{wordImg=img;go()};img.onerror=go;img.src=WORDMARK;
let started=false;function go(){if(started)return;started=true;
  const fams=A.filter(a=>a.type.font).map(a=>`${a.type.weight||''} 40px ${a.type.font}`).concat(['italic 600 40px Newsreader','600 30px "Bricolage Grotesque"']);
  Promise.all(fams.map(f=>document.fonts?document.fonts.load(f).catch(()=>{}):0)).then(()=>document.fonts&&document.fonts.ready).catch(()=>{}).then(start)}
})();
