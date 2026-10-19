// STM_MIRROR_CMD for the Windows check: the Controller's arguments -> the REAL stem-mirror.ps1 it wrote beside StemMirror.cs (a SMOKE copy never
// starts PowerShell itself), so this runs exactly what the mini PC runs.
const path=require('path'), cp=require('child_process'); const a=process.argv.slice(2); const cs=a[a.indexOf('-Cs')+1], ps=path.join(path.dirname(cs),'stem-mirror.ps1');
const m=cp.spawn('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',ps].concat(a),{stdio:['pipe','inherit','inherit'],windowsHide:true});
process.stdin.pipe(m.stdin); m.on('exit',c=>process.exit(c||0)); process.on('SIGTERM',()=>{ try{ m.kill(); }catch(e){} process.exit(0); });
