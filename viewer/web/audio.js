// Listening to Engine's audio output in the browser, and the main meters.
"use strict";
// ---------------------------------------------------------------- audio
let actx=null,playing=false;
// Engine under emulation sometimes delivers audio late (it is busy drawing, or the host is).
// The player keeps a buffer that starts at 0.25 s and grows by 0.1 s (up to 1 s) every time it
// runs dry, so stalls stop being audible after the first one or two; a fresh start after a
// gap fades in over 5 ms instead of clicking.
async function audioLoop(){let pos=0,next=0,target=0.25,fresh=true;
  while(playing){try{const r=await fetch("/audio?pos="+pos,{cache:"no-store"});const b=await r.arrayBuffer();const h=new DataView(b);
      const np=Number(h.getBigUint64(0,true)),rate=h.getUint32(8,true),n=(b.byteLength-12)/4;
      if(!rate||!n){await new Promise(r=>setTimeout(r,200));continue}
      pos=np;if(!actx||actx.sampleRate!==rate){actx&&actx.close();actx=new AudioContext({sampleRate:rate,latencyHint:"playback"});next=0}
      const s=new Int16Array(b,12,n*2),buf=actx.createBuffer(2,n,rate),L=buf.getChannelData(0),R=buf.getChannelData(1);
      // Panels with their own MASTER / PHONES knobs (Prime 4) set the listening volume of those outputs.
      const g=outGain();let pl=0,pr=0;
      for(let i=0;i<n;i++){L[i]=s[2*i]/32768*g;R[i]=s[2*i+1]/32768*g;pl=Math.max(pl,Math.abs(L[i]));pr=Math.max(pr,Math.abs(R[i]))}
      meter(pl,pr);
      const now=actx.currentTime;
      if(next<now+0.01){if(next)target=Math.min(1,target+0.1);next=now+target;fresh=true}
      else if(next>now+target+0.5)next=now+target,fresh=true;
      if(fresh){const f=Math.min(n,Math.round(rate*0.005));for(let i=0;i<f;i++){L[i]*=i/f;R[i]*=i/f}fresh=false}
      const src=actx.createBufferSource();src.buffer=buf;src.connect(actx.destination);src.start(next);next+=n/rate}
    catch(e){await new Promise(r=>setTimeout(r,500))}}}
$("#listen").onclick=()=>{playing=!playing;$("#listen").classList.toggle("on",playing);$("#listen").textContent=playing?"Listening":"Listen";
  if(playing)audioLoop();else if(actx){actx.close();actx=null}};
// Which output is being listened to (its name from the model's outputs, P.outs), and the knob that sets its volume.
function outName(){const o=$("#pair").selectedOptions[0];return o?o.textContent.split(" (")[0]:""}
function outGain(){const k=outName()==="Main"?"master":outName()==="Phones"?"phones":null;
  if(!k||values[k]===undefined||!P||!P.controls.some(c=>c.id===k))return 1;return Math.pow(values[k]/100,2)}
// The main meters (Prime 4) show the level of what's playing in the browser, in dB from -40.
let mlast=0;function meter(l,r){const t=performance.now();if(t-mlast<50)return;mlast=t;
  const db=v=>v>0?Math.max(0,Math.min(127,(20*Math.log10(v)+40)/40*127)):0;views.vuL?.cc?.(db(l));views.vuR?.cc?.(db(r))}
// The model's output names (P.outs) go with its main audio device: the one with the most channels.
async function loadPairs(){try{const r=await(await fetch("/audio-devices")).json();const s=$("#pair");s.innerHTML="";
    const main=r.devices.reduce((a,d)=>!a||d.channels>a.channels?d:a,null);
    for(const d of r.devices)for(let p=0;p+1<d.channels;p+=2){const o=document.createElement("option");o.value=`${d.index} ${p} ${p+1}`;
      o.textContent=`${(d===main&&P&&P.outs||[])[p/2]||"Out "+(p+1)+"/"+(p+2)} (${d.name} ${p+1}/${p+2})`;s.appendChild(o)}
    if(r.select)s.value=r.select.join(" ")}catch(e){}}
$("#pair").onchange=e=>post("/audio-select",e.target.value);
