// The deck page: the panel built from /panel.json, its controls, the touchscreen and the state
// loop. Loaded first; displays.js, audio.js and drives.js add to it, main.js starts it.
"use strict";
const $=s=>document.querySelector(s);
const panel=$("#panel"),st=$("#st");
let P=null,ctl={},values={},leds={},views={};
const post=(u,b)=>fetch(u,{method:"POST",body:b}).catch(()=>{});

// ---------------------------------------------------------------- events to the server
let q=[],busy=false;
// SHIFT: hold it, double-click to lock it on (click again to unlock), or hold Shift on the
// keyboard, which holds both decks' SHIFT. Engine sees one press until nothing holds it.
const shifts={};
function shiftSync(id){const s=shifts[id],on=s.mouse||s.key||s.locked;
  if(on!==s.sent){s.sent=on;send(id+(on?" press":" release"))}
  s.d.classList.toggle("down",on);s.d.classList.toggle("locked",s.locked);s.d.textContent=s.locked?"SHIFT \u{1F512}":"SHIFT"}
function shiftBtn(c,d){const s=shifts[c.id]={d,mouse:false,key:false,locked:false,sent:false,last:0};
  d.title="Hold for shift. Double-click to lock it on. The keyboard's Shift key works too.";
  d.addEventListener("pointerdown",e=>{e.preventDefault();d.setPointerCapture(e.pointerId);const t=performance.now();
    if(s.locked){s.locked=false;s.last=0}else if(t-s.last<350){s.locked=true;s.last=0}else{s.last=t}
    s.mouse=true;shiftSync(c.id)});
  const up=()=>{if(s.mouse){s.mouse=false;shiftSync(c.id)}};
  d.addEventListener("pointerup",up);d.addEventListener("pointercancel",up);
  views[c.id]={led(){}}}
const typing=e=>{const t=e.target;return t&&(t.tagName==="INPUT"||t.tagName==="TEXTAREA"||t.tagName==="SELECT"||t.isContentEditable)};
addEventListener("keydown",e=>{if(e.key!=="Shift"||e.repeat||typing(e))return;for(const id in shifts){shifts[id].key=true;shiftSync(id)}});
addEventListener("keyup",e=>{if(e.key!=="Shift")return;for(const id in shifts){shifts[id].key=false;shiftSync(id)}});
addEventListener("blur",()=>{for(const id in shifts){if(shifts[id].key){shifts[id].key=false;shiftSync(id)}}});
function send(line){q.push(line);if(!busy)flush()}
async function flush(){busy=true;while(q.length){const b=q.splice(0).join("\n");await post("/control",b)}busy=false}

// ---------------------------------------------------------------- layout scaling
function fit(){panel.style.width=P.w+"px";panel.style.height=P.h+"px";const s=$("#stage"),k=Math.min(s.clientWidth/P.w,s.clientHeight/P.h)*0.985;
  panel.style.transform=`scale(${k})`;panel.style.position="absolute";
  panel.style.left=((s.clientWidth-P.w*k)/2)+"px";panel.style.top=((s.clientHeight-P.h*k)/2)+"px";panel._k=k}
addEventListener("resize",()=>P&&fit());

function el(c,cls){const d=document.createElement("div");d.className="c "+(cls||"");
  Object.assign(d.style,{left:c.x+"px",top:c.y+"px",width:c.w+"px",height:c.h+"px"});panel.appendChild(d);return d}
function label(d,text,below=true){if(!text)return;const l=document.createElement("div");l.className="lab"+(below?" below":"");l.textContent=text;d.appendChild(l)}
function drag(d,onMove,onDown,onUp){d.addEventListener("pointerdown",e=>{e.preventDefault();d.setPointerCapture(e.pointerId);
  let last={x:e.clientX,y:e.clientY};onDown&&onDown(e);
  const mv=e2=>{onMove(e2,(e2.clientX-last.x)/panel._k,(e2.clientY-last.y)/panel._k);last={x:e2.clientX,y:e2.clientY}};
  const up=e2=>{d.removeEventListener("pointermove",mv);d.removeEventListener("pointerup",up);d.removeEventListener("pointercancel",up);onUp&&onUp(e2)};
  d.addEventListener("pointermove",mv);d.addEventListener("pointerup",up);d.addEventListener("pointercancel",up)})}
const arcSvg=()=>'<svg viewBox="-60 -60 120 120"><path d="" fill="none" stroke="#4aa3ff" stroke-width="7" stroke-linecap="round"/></svg>';
function arcPath(f,center){const a0=-135,a=a0+270*f,c=center?0:-135;const s=Math.min(a,c),e=Math.max(a,c);
  if(e-s<.5)return"";const r=56,p=t=>[Math.sin(t*Math.PI/180)*r,-Math.cos(t*Math.PI/180)*r];
  const[x1,y1]=p(s),[x2,y2]=p(e);return`M${x1} ${y1}A${r} ${r} 0 ${e-s>180?1:0} 1 ${x2} ${y2}`}

// ---------------------------------------------------------------- controls
const builders={
 screen(c){const d=el(c,"screen");const cv=document.createElement("canvas");cv.width=1280;cv.height=800;d.appendChild(cv);screen(cv)},
 panel(c){el(c,"mixbg")},
 label(c){const d=el(c,"text"+(c.big?" big":""));d.textContent=c.lab},
 btn(c){const d=el(c,"btn"+(c.round?" round":"")+(c.small?" small":"")+(c.big?" big":""));d.textContent=c.lab;
  if(/_shift$/.test(c.id))return shiftBtn(c,d);
  d.addEventListener("pointerdown",e=>{e.preventDefault();d.setPointerCapture(e.pointerId);d.classList.add("down");send(c.id+" press")});
  const up=()=>{if(d.classList.contains("down")){d.classList.remove("down");send(c.id+" release")}};
  d.addEventListener("pointerup",up);d.addEventListener("pointercancel",up);
  views[c.id]={led(v){const col=c.col||"#f0f2f5";if(!v){d.style.background="";d.style.color="";d.style.boxShadow="";return}
    const a=v>=64?1:.45;d.style.background=mix(col,a);d.style.color=a>.6?"#111":"#fff";d.style.boxShadow=`0 0 ${10*a}px ${col}`}}},
 pad(c){const d=el(c,"pad");d.textContent=c.lab;
  d.addEventListener("pointerdown",e=>{e.preventDefault();d.setPointerCapture(e.pointerId);d.classList.add("down");send(c.id+" press")});
  const up=()=>{if(d.classList.contains("down")){d.classList.remove("down");send(c.id+" release")}};
  d.addEventListener("pointerup",up);d.addEventListener("pointercancel",up);
  views[c.id]={led(v){if(!v){d.style.background="";d.style.boxShadow="";return}
    const r=(v>>4)&3,g=(v>>2)&3,b=v&3,col=`rgb(${r*85},${g*85},${b*85})`;
    d.style.background=col;d.style.boxShadow=`0 0 14px ${col},inset 0 0 0 1px #ffffff40`}}},
 knob(c){const d=el(c,"knob");d.innerHTML=arcSvg()+'<div class="ptr"></div>';label(d,c.lab);
  const ptr=d.querySelector(".ptr"),arc=d.querySelector("path"),center=(c.d===64);
  const show=v=>{const f=v/127;ptr.style.transform=`rotate(${-135+270*f}deg)`;arc.setAttribute("d",arcPath(f,center))};
  let v=values[c.id]??c.d??0;show(v);
  const set=nv=>{nv=Math.max(0,Math.min(127,Math.round(nv)));if(nv!==v){v=nv;show(v);send(`${c.id} set ${v}`)}};
  drag(d,(e,dx,dy)=>set(v-dy*0.7+dx*0.2));
  d.addEventListener("wheel",e=>{e.preventDefault();set(v+(e.deltaY<0?3:-3))},{passive:false});
  d.addEventListener("dblclick",()=>set(c.d??0));
  views[c.id]={value(nv){v=nv;show(v)}}},
 enc(c){const d=el(c,"enc");d.innerHTML='<div class="cap"></div>';label(d,c.lab);const cap=d.querySelector(".cap");
  let acc=0,rot=0;const turn=n=>{rot+=n*15;d.style.backgroundImage=`repeating-conic-gradient(from ${rot}deg,#3d4146 0 6deg,#2e3135 6deg 12deg)`;send(`${c.id} turn ${n}`)};
  // Drag anywhere on it to turn. A click without moving pushes it; holding still holds the push.
  let moved=0,pushed=false,holdT=0;
  const push=()=>{if(!pushed&&c.push!=null){pushed=true;cap.classList.add("down");send(c.id+" press")}};
  drag(d,(e,dx,dy)=>{moved+=Math.abs(dx)+Math.abs(dy);if(moved<4)return;clearTimeout(holdT);
      acc+=(-dy+dx)/7;const n=Math.trunc(acc);if(n){acc-=n;turn(n)}},
    ()=>{moved=0;acc=0;clearTimeout(holdT);holdT=setTimeout(()=>{if(moved<4)push()},350)},
    ()=>{clearTimeout(holdT);if(moved<4&&!pushed)push();
      if(pushed){setTimeout(()=>{cap.classList.remove("down");send(c.id+" release");pushed=false},pushed?60:0)}});
  d.addEventListener("wheel",e=>{e.preventDefault();turn(e.deltaY<0?1:-1)},{passive:false});
  views[c.id]={led(v){cap.style.boxShadow=v?"0 0 10px #4aa3ff,inset 0 0 0 2px #4aa3ff":""}}},
 fader(c){vfader(c,127,true)},
 pitch(c){vfader(c,16383,false)},
 xfader(c){const d=el(c);const tr=document.createElement("div");tr.className="track";Object.assign(tr.style,{left:"0",right:"0",top:(c.h/2-3)+"px",height:"6px"});d.appendChild(tr);
  const cap=document.createElement("div");cap.className="cap2 xcap";Object.assign(cap.style,{width:"26px",top:"0",height:c.h+"px"});d.appendChild(cap);
  let v=values[c.id]??c.d??64;const show=()=>cap.style.left=(v/127*(c.w-26))+"px";show();
  const set=nv=>{nv=Math.max(0,Math.min(127,Math.round(nv)));if(nv!==v){v=nv;show();send(`${c.id} set ${v}`)}};
  drag(d,(e,dx)=>set(v+dx*127/(c.w-26)));d.addEventListener("dblclick",()=>set(64));
  views[c.id]={value(nv){v=nv;show()}}},
 jog(c){const d=el(c,"jog");d.innerHTML='<div class="top"></div><canvas class="lcd" width="320" height="320"></canvas><div class="mark"></div><div class="info"><span>'+c.lab+'</span></div>';
  const lcd=d.querySelector("canvas.lcd"),info=d.querySelector(".info");
  const mark=d.querySelector(".mark"),TPR=2048;let pos=0,touching=false;
  const show=()=>mark.style.transform=`rotate(${pos/TPR*360}deg)`;
  const ang=e=>{const r=d.getBoundingClientRect();return Math.atan2(e.clientY-(r.top+r.height/2),e.clientX-(r.left+r.width/2))};
  let a0=0,acc=0;
  drag(d,e=>{const a=ang(e);let da=a-a0;if(da>Math.PI)da-=2*Math.PI;if(da<-Math.PI)da+=2*Math.PI;a0=a;
      acc+=da/(2*Math.PI)*TPR;const n=Math.trunc(acc);if(n){acc-=n;pos+=n;show();send(`${c.id} spin ${n}`)}},
    e=>{a0=ang(e);const r=d.getBoundingClientRect(),dx=e.clientX-(r.left+r.width/2),dy=e.clientY-(r.top+r.height/2);
      touching=Math.hypot(dx,dy)<r.width*0.34;if(touching){d.classList.add("touched");send(c.id+" press")}},
    ()=>{if(touching){touching=false;d.classList.remove("touched");send(c.id+" release")}});
  d.addEventListener("wheel",e=>{e.preventDefault();const n=e.deltaY<0?24:-24;pos+=n;show();send(`${c.id} spin ${n}`)},{passive:false});
  views[c.id]={jog(st){const on=c.platter?drawPlatter(lcd,c.platter,platters[c.platter]):drawJogLcd(lcd,c.ch,st);info.style.display=on?"none":"flex"}}},
 sw(c){const d=el(c,"sw");label(d,c.labs?"":c.lab);
  const parts=c.labs.map((t,i)=>{const p=document.createElement("div");p.textContent=t;p.onclick=()=>{set(i)};d.appendChild(p);return p});
  let v=values[c.id]??c.d??0;const show=()=>parts.forEach((p,i)=>p.classList.toggle("on",i===v));show();
  const set=i=>{v=i;show();send(`${c.id} set ${i}`)};
  if(c.lab&&c.lab!==c.labs[1]){const l=document.createElement("div");l.className="lab below";l.textContent=c.lab;d.appendChild(l)}
  views[c.id]={value(nv){v=nv;show()}}},
 sel(c){const d=el(c,"sel");d.innerHTML='<div class="ptr"></div>';label(d,c.lab);const ptr=d.querySelector(".ptr");
  const n=c.vals.length,angs=c.labs.map((_,i)=>-60+120*i/(n-1));
  const opts=c.labs.map((t,i)=>{const o=document.createElement("div");o.className="opt";o.textContent=t;const a=angs[i]*Math.PI/180,R=c.w/2+11;
    o.style.left=(c.w/2+Math.sin(a)*R)+"px";o.style.top=(c.h/2-Math.cos(a)*R)+"px";d.appendChild(o);return o});
  let v=values[c.id]??c.d??0;const show=()=>{ptr.style.transform=`rotate(${angs[v]}deg)`;opts.forEach((o,i)=>o.classList.toggle("on",i===v))};show();
  const set=i=>{v=(i+n)%n;show();send(`${c.id} set ${v}`)};
  d.addEventListener("click",e=>set(e.shiftKey?v-1:v+1));d.addEventListener("wheel",e=>{e.preventDefault();set(v+(e.deltaY<0?1:-1))},{passive:false});
  views[c.id]={value(nv){v=nv;show()}}},
 oled(c){const d=el(c,"oled");const cv=document.createElement("canvas");d.appendChild(cv);let last=null;
  // area-average the 128x32 bitmap down (or up) to the canvas's real pixel size, so 1 px strokes stay visible as grey
  const draw=()=>{if(!last)return;const r=d.getBoundingClientRect(),dpr=window.devicePixelRatio||1,W=Math.max(1,Math.round(r.width*dpr)),H=Math.max(1,Math.round(r.height*dpr));
   if(cv.width!==W||cv.height!==H){cv.width=W;cv.height=H}const g=cv.getContext("2d"),img=g.createImageData(W,H),px=img.data,sx=128/W,sy=32/H;
   for(let ty=0;ty<H;ty++){const y0=ty*sy,y1=y0+sy;for(let tx=0;tx<W;tx++){const x0=tx*sx,x1=x0+sx;let a=0;
     for(let y=Math.floor(y0);y<y1&&y<32;y++){const wy=Math.min(y+1,y1)-Math.max(y,y0);for(let x=Math.floor(x0);x<x1&&x<128;x++)if(last[y*128+x])a+=wy*(Math.min(x+1,x1)-Math.max(x,x0))}
     const v=Math.min(1,Math.sqrt(a/(sx*sy))*1.15),o=(ty*W+tx)*4;px[o]=235*v;px[o+1]=245*v;px[o+2]=255*v;px[o+3]=255}}g.putImageData(img,0,0)};
  new ResizeObserver(draw).observe(d);
  views[c.id]={oled(b64){const s=atob(b64),m=new Uint8Array(4096);for(let p=0;p<4;p++)for(let x=0;x<128;x++){const v=s.charCodeAt(p*128+x);for(let bit=0;bit<8;bit++)m[(p*8+bit)*128+x]=v>>bit&1}last=m;draw()}}},
 vu(c){const d=el(c,"vu");const N=c.segs||6,segs=[];for(let i=0;i<N;i++){const s=document.createElement("i");d.appendChild(s);segs.push(s)}
  const cols=segs.map((s,i)=>i>=N-1?"#ff4b3e":i>=N-2?"#ffb02e":"#2bd46a");
  // SC LIVE 4 meters light one bit per segment; Prime 4 ones (inc) send a level 0-127.
  views[c.id]={cc(v){let n=0;if(c.inc)n=Math.round(v/127*N);else for(let b=v;b;b>>=1)n+=b&1;segs.forEach((s,i)=>s.style.background=i<n?cols[i]:"")}}},
};
function vfader(c,max,topIsMax){const d=el(c);const tr=document.createElement("div");tr.className="track";Object.assign(tr.style,{top:"0",bottom:"0",left:(c.w/2-3)+"px",width:"6px"});d.appendChild(tr);
  if(!topIsMax){const m=document.createElement("div");Object.assign(m.style,{position:"absolute",left:"-6px",right:"-6px",top:(c.h/2-1)+"px",height:"2px",background:"#555"});d.appendChild(m);
    const led=document.createElement("div");Object.assign(led.style,{position:"absolute",left:"-12px",top:(c.h/2-4)+"px",width:"8px",height:"8px",borderRadius:"50%",background:"#222"});d.appendChild(led);
    views[c.id+"#led"]=led}
  const capH=22,cap=document.createElement("div");cap.className="cap2";Object.assign(cap.style,{left:"-4px",right:"-4px",height:capH+"px"});d.appendChild(cap);label(d,c.lab);
  let v=values[c.id]??(topIsMax?c.d??0:8192);const span=c.h-capH;
  const show=()=>cap.style.top=((topIsMax?1-v/max:v/max)*span)+"px";show();
  const set=nv=>{nv=Math.max(0,Math.min(max,Math.round(nv)));if(nv!==v){v=nv;show();send(`${c.id} set ${v}`)}};
  drag(d,(e,dx,dy)=>set(v+(topIsMax?-1:1)*dy*max/span));
  d.addEventListener("dblclick",()=>set(topIsMax?(c.d??0):8192));
  d.addEventListener("wheel",e=>{e.preventDefault();set(v+(e.deltaY<0?1:-1)*(topIsMax?-1:1)*-max/64)},{passive:false});
  views[c.id]=Object.assign(views[c.id]||{},{value(nv){v=nv;show()}})}
function mix(hex,a){const n=parseInt(hex.slice(1),16),r=n>>16,g=(n>>8)&255,b=n&255,k=x=>Math.round(0x3a+(x-0x3a)*a);return`rgb(${k(r)},${k(g)},${k(b)})`}

// ---------------------------------------------------------------- LEDs and values from the server
function applyLeds(){
  for(const c of P.controls){if(!c.id)continue;const v=views[c.id];if(!v)continue;
    if(c.hw){if(v.led)v.led(values[c.id]?127:0);continue}  // the emulator's own mixer controls
    if(c.t==="oled"){const o=oleds[String(c.oled)];if(o&&o!==v.last){v.last=o;v.oled(o)}continue}
    const D=c.dev?`d${c.dev}`:"";  // which of the deck's MIDI devices (Prime 4: 1 = mixer)
    if(v.led){const key=c.t==="enc"?`${D}n${c.ch}.${c.push}`:`${D}n${c.ch}.${c.n}`;v.led(leds[key]||0)}
    if(v.cc)v.cc(leds[`${D}c${c.ch}.${c.cc}`]||0);
    if(c.t==="pitch"&&views[c.id+"#led"]){views[c.id+"#led"].style.background=leds[`${D}n${c.ch}.${c.led}`]?"#ff4b3e":"#222"}
    if(v.jog)v.jog(jogs[String(c.ch)])}}
async function stateLoop(){let seq=-1,first=true;
  for(;;){try{const r=await fetch("/state?since="+seq,{cache:"no-store"});const s=await r.json();
      if(s.seq!==seq||first){seq=s.seq;leds=s.leds;jogs=s.jog||{};platters=s.platters||{};oleds=s.oleds||{};if(first){values=s.values;for(const[k,v]of Object.entries(values))views[k]?.value?.(v);first=false}else if(s.values)Object.assign(values,s.values);applyLeds()}}
    catch(e){await new Promise(r=>setTimeout(r,1000))}}}

// ---------------------------------------------------------------- screen
function screen(cv){const g=cv.getContext("2d");let seq=0,img=null,frames=0,t0=performance.now();
  (async()=>{for(;;){try{const r=await fetch("/frame?since="+seq,{cache:"no-store"});if(r.status===204)continue;
      const b=await r.arrayBuffer(),h=new DataView(b);seq=h.getUint32(0,true);const w=h.getUint32(4,true),hh=h.getUint32(8,true),bpl=h.getUint32(12,true);
      if(cv.width!==w||cv.height!==hh){cv.width=w;cv.height=hh;img=null}if(!img)img=g.createImageData(w,hh);
      const src=new Uint8Array(b,16),dst=img.data;
      for(let y=0;y<hh;y++){let s=y*bpl,d=y*w*4;for(let x=0;x<w;x++,s+=4,d+=4){dst[d]=src[s+2];dst[d+1]=src[s+1];dst[d+2]=src[s];dst[d+3]=255}}
      g.putImageData(img,0,0);frames++;const t=performance.now();if(t-t0>1000){st.textContent=(frames*1000/(t-t0)).toFixed(1)+" fps";frames=0;t0=t}}
    catch(e){st.textContent="waiting for Engine";await new Promise(r=>setTimeout(r,1000))}}})();
  const pos=e=>{const r=cv.getBoundingClientRect();return[Math.round((e.clientX-r.left)*cv.width/r.width),Math.round((e.clientY-r.top)*cv.height/r.height)]};
  let down=false,tq=[],tb=false;const ts=l=>{tq.push(l);if(!tb)tf()};
  const tf=async()=>{tb=true;while(tq.length){await post("/input",tq.splice(0).join("\n")+"\n")}tb=false};
  cv.addEventListener("pointerdown",e=>{e.preventDefault();cv.setPointerCapture(e.pointerId);down=true;const[x,y]=pos(e);ts(`down ${x} ${y}`)});
  cv.addEventListener("pointermove",e=>{if(!down)return;const[x,y]=pos(e);ts(`move ${x} ${y}`)});
  cv.addEventListener("pointerup",e=>{if(!down)return;down=false;const[x,y]=pos(e);ts(`up ${x} ${y}`)});
  cv.addEventListener("wheel",e=>{e.preventDefault();const[x,y]=pos(e);ts(`wheel ${x} ${y} ${e.deltaY<0?120:-120}`)},{passive:false})}
