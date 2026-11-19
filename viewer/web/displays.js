// The decks' own displays, drawn from what the viewer decodes (viewer/displays.py).
"use strict";
// ---------------------------------------------------------------- jog displays
// The SC LIVE 4's jog centres are segment LCDs that Engine drives over MIDI
// (ControlSurfaceModules/LcdWheelDisplay.qml), on the deck's channel:
//   CC 0x30 position ring: 1-48 lights that segment, +64 inverts (all but that one), 0 off
//   CC 0x31-0x34 ring quadrants top/right/left/bottom, 0x35/0x36 top/bottom box, 0x37 "DECK",
//   0x39 "BPM", 0x3a time label, 0x3c dividing line, 0x3e BPM digits, 0x3f time digits
//   note 0x38: the active deck number as velocity; the time and BPM come as SysEx (viewer/surface.py).
let jogs={},platters={},oleds={};
const LCD_ON="#e9f1ff",LCD_DIM="#1b2027";
// The Prime 4's jog wheel screens (MIDI devices 2 and 3; the viewer decodes them): the track's
// artwork turning with the platter, the position ring and marker, the slip marker and the loop size.
const artCache={};
function artImg(dev,slot,ver){const k=`${dev}/${slot}`;const c=artCache[k];if(c&&c.ver===ver)return c.img.complete&&c.img.naturalWidth?c.img:null;
  const img=new Image();img.onload=()=>applyLeds();img.src=`/platter-art?dev=${dev}&slot=${slot}&v=${ver}`;artCache[k]={ver,img};return null}
function drawPlatter(cv,dev,st){const g=cv.getContext("2d"),W=cv.width,R=W/2;g.clearRect(0,0,W,W);if(!st)return false;
  const sh=st.show||[0,0,0,13],col=e=>{const c=(st.colors||{})[e];return c?`rgba(${c[1]},${c[2]},${c[3]},${(c[0]/255).toFixed(3)})`:null};
  g.save();g.globalAlpha=Math.max(0.15,(st.bright??127)/127);g.beginPath();g.arc(R,R,R,0,2*Math.PI);g.fillStyle="#000";g.fill();g.clip();
  const turn=a=>a*2*Math.PI;
  if(sh[0]&1){const ver=(st.art||{})[String(sh[2])];const img=ver&&artImg(dev,sh[2],ver);
    if(img){g.save();g.translate(R,R);g.rotate(turn(st.angle||0)+Math.PI);g.globalAlpha*=((st.colors||{})["0"]||[255])[0]/255;g.drawImage(img,-R,-R,W,W);g.restore()}}
  if(sh[0]&2){const c=col(1)||"#fff";g.strokeStyle=c;g.lineWidth=W*0.02;g.beginPath();g.arc(R,R,R*0.3,0,2*Math.PI);g.stroke()}
  if(sh[0]&16){const c=col(4);if(c){g.fillStyle=c;g.fillRect(0,0,W,W)}}
  if(sh[0]&4){const ring=col(2),mk=col(3)||"#fff",a=turn(st.angle||0)-Math.PI/2;
    if(ring){g.strokeStyle=ring;g.lineWidth=W*0.05;g.beginPath();g.arc(R,R,R*0.95,0,2*Math.PI);g.stroke()}
    g.strokeStyle=mk;g.lineWidth=W*0.06;g.lineCap="round";g.beginPath();g.moveTo(R+Math.cos(a)*R*0.72,R+Math.sin(a)*R*0.72);g.lineTo(R+Math.cos(a)*R*0.94,R+Math.sin(a)*R*0.94);g.stroke()}
  if(sh[0]&16){const c=col(5)||"#fff",a=turn(st.slip||0)-Math.PI/2;g.fillStyle=c;g.beginPath();g.arc(R+Math.cos(a)*R*0.83,R+Math.sin(a)*R*0.83,W*0.035,0,2*Math.PI);g.fill()}
  if(sh[1]&2&&st.loop){g.fillStyle=col(8)||"#fff";g.font=`bold ${Math.round(W*0.2)}px system-ui,sans-serif`;g.textAlign="center";g.textBaseline="middle";g.fillText(st.loop,R,R)}
  g.restore();return true}
function drawJogLcd(cv,ch,st){
  const L=k=>leds[`c${ch}.${k}`]||0,g=cv.getContext("2d"),W=cv.width,R=W/2;
  const needle=L(0x30),any=needle||L(0x31)||L(0x35)||L(0x37)||L(0x3e)||L(0x3f);
  g.clearRect(0,0,W,W);
  if(!any)return false;
  g.save();g.translate(R,R);
  g.fillStyle="#05070a";g.beginPath();g.arc(0,0,R,0,7);g.fill();
  // position ring, 48 segments from 12 o'clock clockwise
  const seg=needle&63,inv=needle>=64,N=48;
  for(let i=1;i<=N;i++){
    const lit=needle?(inv?i!==seg:i===seg):false;
    const a0=-Math.PI/2+(i-1)/N*2*Math.PI+0.012,a1=a0+2*Math.PI/N-0.024;
    g.strokeStyle=lit?LCD_ON:LCD_DIM;g.lineWidth=R*0.09;g.beginPath();g.arc(0,0,R*0.9,a0,a1);g.stroke()}
  // inner ring quadrants
  const quad=[[0x31,-Math.PI*0.75],[0x32,-Math.PI*0.25],[0x34,Math.PI*0.25],[0x33,Math.PI*0.75]];
  for(const[k,a]of quad){g.strokeStyle=L(k)?LCD_ON:LCD_DIM;g.lineWidth=R*0.025;g.beginPath();g.arc(0,0,R*0.76,a+0.04,a+Math.PI/2-0.04);g.stroke()}
  g.textAlign="center";g.textBaseline="middle";g.fillStyle=LCD_ON;g.strokeStyle=LCD_ON;
  // top box: DECK and the deck number
  if(L(0x35)){g.lineWidth=R*0.02;g.strokeRect(-R*0.36,-R*0.62,R*0.72,R*0.5)}
  if(L(0x37)){g.font=`600 ${R*0.11}px system-ui,sans-serif`;g.fillText("DECK",0,-R*0.52)}
  const deck=leds[`n${ch}.56`];if(deck){g.font=`700 ${R*0.3}px system-ui,sans-serif`;g.fillText(String(deck),0,-R*0.28)}
  if(L(0x3c)){g.lineWidth=R*0.02;g.beginPath();g.moveTo(-R*0.6,-R*0.04);g.lineTo(R*0.6,-R*0.04);g.stroke()}
  // BPM
  if(L(0x3e)&&st&&st.bpm!=null){g.font=`700 ${R*0.17}px ui-monospace,Menlo,Consolas,monospace`;g.fillText(st.bpm.toFixed(1),-R*0.08,R*0.12)}
  if(L(0x39)||L(0x3e)){g.font=`600 ${R*0.08}px system-ui,sans-serif`;g.fillText("BPM",R*0.4,R*0.14)}
  // time, bottom box
  if(L(0x36)){g.lineWidth=R*0.02;g.strokeRect(-R*0.42,R*0.26,R*0.84,R*0.26)}
  if(L(0x3f)&&st&&st.time){const t=st.time,m=t.h*60+t.m;
    g.font=`700 ${R*0.15}px ui-monospace,Menlo,Consolas,monospace`;
    g.fillText(`${t.minus?"-":""}${m}:${String(t.s).padStart(2,"0")}.${Math.floor(t.cs/10)}`,0,R*0.39)}
  g.restore();return true}
