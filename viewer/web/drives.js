// The Drives dialog and the Reboot button.
"use strict";
// ---------------------------------------------------------------- drives, reboot
async function drivesShow(list){list=list||await(await fetch("/drives")).json();const t=$("#dlist");t.innerHTML="";
  if(!list.length)t.innerHTML='<tr><td class="hint">Nothing plugged in.</td></tr>';
  for(const d of list){const tr=document.createElement("tr");tr.innerHTML=`<td><b></b></td><td></td><td></td><td></td>`;
    tr.children[0].firstChild.textContent=d.label;tr.children[1].textContent=d.kind==="sd"?"SD card":"USB drive";tr.children[2].textContent=d.folder+(d.ok?"":" (missing)");
    const b=document.createElement("button");b.textContent="Eject";b.onclick=async()=>{const r=await fetch("/drives",{method:"POST",body:JSON.stringify({action:"remove",label:d.label})});drivesShow((await r.json()).drives)};
    tr.children[3].appendChild(b);t.appendChild(tr)}}
$("#drivesBtn").onclick=()=>{$("#derr").textContent="";drivesShow();$("#drives").showModal()};
$("#dclose").onclick=()=>$("#drives").close();
$("#dadd").onclick=async()=>{const r=await fetch("/drives",{method:"POST",body:JSON.stringify({folder:$("#dfolder").value.trim(),kind:$("#dkind").value,label:$("#dlabel").value.trim()})});
  const j=await r.json();$("#derr").textContent=j.error||"";if(!j.error){$("#dfolder").value="";$("#dlabel").value=""}drivesShow(j.drives)};
$("#rebootBtn").onclick=async()=>{if(!confirm("Reboot the emulated deck? Engine takes a minute or two to come back."))return;
  await post("/reboot","");st.textContent="rebooting...";setTimeout(()=>location.reload(),15000)};
