// The Windows check for 19a STEM MIRROR: a SMOKE copy of the Controller + the real stem-mirror.ps1 / StemMirror.cs (Windows PowerShell 5.1)
// reading a stand-in UxPlay window that plays djay frames. Results go to GitHub annotations (::notice / ::error).
const fs=require('fs'),path=require('path'),http=require('http'),cp=require('child_process');
const W=__dirname, PORT=18180, run=path.join(process.env.RUNNER_TEMP||W,'ctl'); fs.mkdirSync(run,{recursive:true}); fs.copyFileSync(path.join(W,'artnet-controller.js'),path.join(run,'artnet-controller.js'));
const req=(method,u,body)=>new Promise((res)=>{ const b=body==null?null:Buffer.from(JSON.stringify(body)); const r=http.request({host:'127.0.0.1',port:PORT,path:u,method,headers:b?{'Content-Type':'application/json','Content-Length':b.length}:{}},x=>{ const a=[]; x.on('data',d=>a.push(d)); x.on('end',()=>{ let j=null; try{ j=JSON.parse(Buffer.concat(a)); }catch(e){} res({s:x.statusCode,j}); }); }); r.on('error',()=>res({s:0})); if(b) r.write(b); r.end(); });
const sleep=ms=>new Promise(r=>setTimeout(r,ms)); let bad=0; const note=(ok,m)=>{ if(!ok) bad++; console.log((ok?'::notice title=ok::':'::error title=FAIL::')+m.replace(/\n/g,' ')); };
(async()=>{ const ch=cp.spawn(process.execPath,['artnet-controller.js'],{cwd:run,env:Object.assign({},process.env,{DMX_SMOKE:'1',DMX_SMOKE_PORT:String(PORT),STM_MIRROR_CMD:path.join(W,'mirror-shim.js')}),stdio:['ignore','ignore','pipe']});
  let cerr=''; ch.stderr.on('data',d=>{ cerr=(cerr+d).slice(-1500); });
  try{ for(let i=0;i<120;i++){ if((await req('GET','/health')).s===200) break; await sleep(250); }
    await req('POST','/liveshow',{stemMirror:true}); let st=null, maxFps=0, firstLive=null, preds=[], lastM=null;
    const frames=process.argv[2], startFile=path.join(process.env.RUNNER_TEMP||W,'start.txt'); let T0=null;
    for(let i=0;i<120;i++){ await sleep(500); const m=(await req('GET','/sr/state')).j; if(m && m.mirror && m.mirror.running && m.mirror.err && /no open window/.test(m.mirror.err)) break; if(i%10===9) console.log('waiting for the mirror reader: '+JSON.stringify(m&&m.mirror)); }
    console.log('the mirror reader is up and looking for a window; opening the stand-in UxPlay window');
    const flog=path.join(process.env.RUNNER_TEMP||W,'fake.log'), fd=fs.openSync(flog,'w'); const fk=cp.spawn('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(W,'fake-uxplay.ps1'),'-Frames',frames,'-Start',startFile],{stdio:['ignore',fd,fd]}); fk.on('exit',c=>console.log('stand-in window exited '+c));
    setTimeout(()=>{ try{ console.log('windows: '+cp.execSync('powershell.exe -NoProfile -Command "Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.ProcessName + \': \' + $_.MainWindowTitle }"',{encoding:'utf8'}).replace(/\r?\n/g,' | ')); }catch(e){ console.log('window list failed '+e.message); } }, 8000);
    const t0=Date.now();
    while(Date.now()-t0<40000){ await sleep(200); const r=await req('GET','/sr/state'); st=r.j; if(!st) continue; lastM=st.mirror; maxFps=Math.max(maxFps, st.mirror.fps||0); if(st.live && firstLive==null) firstLive=Date.now()-t0;
      if(T0==null && startFile && fs.existsSync(startFile)) T0=+fs.readFileSync(startFile,'utf8');
      const ft=st.full&&st.full.t!=null?st.full.t*1000:null; (st.next||[]).forEach(e=>{ if(e.type==='drop' && e.d===1 && e.num===97 && ft!=null) preds.push({now:Date.now(), at:ft+e.inMs}); });
      if(T0 && Date.now()>T0+19000) break; }
    console.log('mirror state: '+JSON.stringify(lastM)); console.log('reader: '+JSON.stringify({live:st&&st.live, view:st&&st.view, decks:st&&st.decks, clock:st&&st.clock, err:st&&st.err}));
    note(lastM && lastM.restarts===0 && !lastM.err, 'the mirror reader started (compiled by Windows PowerShell 5.1) '+(lastM&&lastM.err?'error: '+lastM.err:'')+' restarts '+(lastM&&lastM.restarts));
    note(maxFps>=8, 'frames per second: '+maxFps+' (12 asked); grab / tiles / send ms: '+JSON.stringify(lastM&&lastM.ms)+'; dpi '+(lastM&&lastM.dpi));
    note(lastM && lastM.pic && lastM.pic[2]>0, 'window "'+(lastM&&lastM.win)+'", djay picture '+JSON.stringify(lastM&&lastM.pic)+' ('+(lastM&&lastM.picFrom)+'), covered by: "'+(lastM&&lastM.cover)+'"');
    note(firstLive!=null, 'the stem reader went LIVE on the mirror after '+(firstLive/1000).toFixed(1)+' s');
    note(st && st.clock && Math.abs(st.clock.bpm-140)<1.5 && st.decks && st.decks[0].num!=null, 'reading: '+JSON.stringify(st&&st.decks&&st.decks.map(d=>d.num))+' '+(st&&st.clock?st.clock.bpm+' BPM':'no clock'));
    if(T0){ const truth=T0+15308-150, early=preds.filter(p=>p.now<truth-2000); note(early.length>0, 'the drop at bar 97 seen coming '+(preds.length?((truth-preds[0].now)/1000).toFixed(2)+' s ahead':'(never)'));
      if(early.length){ const e=early[early.length-1].at-truth; note(Math.abs(e)<200, 'drop predicted '+(e>=0?'+':'')+Math.round(e)+' ms from where the window shows it (minus the 150 ms delay)'); } }
    else note(false, 'the stand-in window never wrote its start time');
    await req('POST','/liveshow',{stemMirror:false}); await sleep(3000); st=(await req('GET','/sr/state')).j; note(st && !st.mirror.running, 'switching it off stops PowerShell');
    try{ const lg=fs.readFileSync(path.join(process.env.RUNNER_TEMP||W,'fake.log'),'utf8').trim(); if(lg) note(false,'stand-in window said: '+lg.slice(0,900)); }catch(e){}
  }catch(e){ note(false,'test crashed: '+e.message); } finally{ ch.kill(); if(cerr.trim()) console.log('controller stderr: '+cerr); }
  console.log(bad?'FAIL '+bad:'ALL OK'); process.exit(bad?1:0); })();
