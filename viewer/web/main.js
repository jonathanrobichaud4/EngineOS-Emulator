// Loads the panel for this deck's model and starts everything. Loaded last.
"use strict";
// ---------------------------------------------------------------- start
(async()=>{P=await(await fetch("/panel.json")).json();
  if(P.name){$("#model").textContent=P.name;document.title="EngineOS Emulator: "+P.name}
  try{values=(await(await fetch("/state?since=-2")).json()).values}catch(e){}
  for(const c of P.controls)(builders[c.t]||(()=>{}))(c);
  fit();stateLoop();loadPairs();setInterval(loadPairs,10000)})();
