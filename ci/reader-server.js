// Stem Eye CI -- a stand-in for the lighting Controller's stem reader, for the check on GitHub's Mac (ci/check.sh).
// The SAME reader (ci/sr-block.js = the SR block cut from artnet-controller.js; SR_FILE=<path to artnet-controller.js> reads it
// from the Controller itself) and the SAME packet decoding as the Controller's worker (STM_MAIN), the same routes
// (GET /sr/program, POST /sr/push), plus what a test needs: POST /reset, POST /map, GET /check. No npm modules.
// Like the real Controller it sometimes loses a frame (every 37th push is not read), so the app's key-frame recovery is exercised.
'use strict';
const http = require('http'), zlib = require('zlib'), fs = require('fs'), path = require('path');
const PORT = +(process.argv[2] || process.env.PORT || 18990);
const SRC = process.env.SR_FILE || path.join(__dirname, 'sr-block.js');

function loadSR() {
  let src = fs.readFileSync(SRC, 'utf8');
  const a = src.lastIndexOf('/*SR-' + 'BEGIN'), b = src.indexOf('/*SR-' + 'END*/', a);
  if (a < 0 || b < 0) throw new Error('no SR block in ' + SRC);
  src = src.slice(a, b + 10);
  return (new Function(src + '\n;return SR;'))();
}
const SR = loadSR();

/* the Controller's GET /sr/program (17c + FS): what the app sends */
function programOf() {
  const p = SR.program();
  p.tiles.forEach(t => { if (t.id === 'LN') t.key = true; });
  p.tiles.push({ id: 'FS', x: 0, y: 0, w: SR.AT.W, h: SR.AT.H, s: 16, every: 24, key: true });
  p.fmt = '565'; p.enc = 'z'; p.keyEvery = 2; p.fps = 12; p.push = '/sr/push';
  return p;
}

/* ---- the Controller's worker (STM_MAIN), verbatim apart from the bookkeeping ---- */
function from565(b, n) { var px = new Uint8Array(n * 3), i, j; for (i = 0, j = 0; i < n; i++, j += 2) { var v = b[j] | (b[j + 1] << 8), r = (v >> 11) & 31, g = (v >> 5) & 63, bl = v & 31; px[i * 3] = (r << 3) | (r >> 2); px[i * 3 + 1] = (g << 2) | (g >> 4); px[i * 3 + 2] = (bl << 3) | (bl >> 2); } return px; }
function decode(W, buf, tf) {
  if (buf.toString('latin1', 0, 4) !== 'SRP1') throw new Error('not a stem packet');
  var hl = buf.readUInt32LE(4), H = JSON.parse(buf.toString('utf8', 8, 8 + hl)), off = 8 + hl, tiles = {}, need = [], kb = 0, bad = [];
  (H.tiles || []).forEach(function (d) {
    var raw = buf.subarray(off, off + d.len); off += d.len; kb += d.len; if (!SR.AT.tiles[d.id]) { W.extra[d.id] = (W.extra[d.id] || 0) + 1; return; }
    var cw = Math.round(d.w / d.s), ch = Math.round(d.h / d.s), b;
    try { b = d.enc === 'raw' ? Buffer.from(raw) : zlib.inflateRawSync(raw); } catch (e) { need.push(d.id); bad.push(d.id + ': inflate ' + e.message); return; }
    if (b.length !== cw * ch * 2) { need.push(d.id); bad.push(d.id + ': ' + b.length + ' bytes, expected ' + (cw * ch * 2)); return; }
    if (d.key === false) { var p = W.prev[d.id]; if (!p || p.b.length !== b.length || p.seq !== d.base) { need.push(d.id); W.mismatch.push({ seq: H.seq, id: d.id, base: d.base, had: p ? p.seq : null }); return; } for (var i = 0; i < b.length; i++) b[i] ^= p.b[i]; }
    W.prev[d.id] = { b: b, seq: H.seq }; var px = d.fmt === '888' ? new Uint8Array(b.buffer, b.byteOffset, b.length) : from565(b, cw * ch);
    tiles[d.id] = { id: d.id, x: d.x, y: d.y, w: d.w, h: d.h, s: d.s, cw: cw, ch: ch, px: px };
  });
  if (off !== buf.length) bad.push('packet length ' + buf.length + ' but tiles end at ' + off);
  SR.frame(W.R, { t: tf / 1000, tiles: tiles }); SR.events(W.R); var st = SR.state(W.R);
  return { H, st, need, bad, n: Object.keys(tiles).length, ids: Object.keys(tiles) };
}

/* ---- one test run ---- */
let W = null;
function newRun(name) { W = { name: name || 'run', R: SR.reader({}), prev: {}, need: {}, n: 0, push: 0, lost: 0, frames: [], h0: null, mismatch: [], extra: {}, bad: [], progGets: W ? W.progGets : 0, live: false, liveAt: 0 }; }
newRun('start');

function readRaw(req) { return new Promise((res, rej) => { const parts = []; req.on('data', c => parts.push(c)); req.on('end', () => res(Buffer.concat(parts))); req.on('error', rej); }); }
function json(res, code, o) { res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(o)); }

http.createServer(async (req, res) => {
  const u = req.url.split('?')[0], qs = new URLSearchParams(req.url.split('?')[1] || '');
  try {
    if (req.method === 'GET' && u === '/sr/program') { W.progGets++; return json(res, 200, programOf()); }
    if (req.method === 'POST' && u === '/sr/push') {
      const rx = Date.now(), buf = await readRaw(req);
      let H; try { if (buf.toString('latin1', 0, 4) !== 'SRP1') throw new Error('bad magic'); const hl = buf.readUInt32LE(4); if (hl > 65536) throw new Error('bad header'); H = JSON.parse(buf.toString('utf8', 8, 8 + hl)); }
      catch (e) { W.bad.push('400: ' + e.message); return json(res, 400, { ok: false, error: 'not a stem packet: ' + e.message }); }
      const tf = (typeof H.t === 'number' && typeof H.off === 'number') ? H.t * 1000 + H.off : rx - 25;
      W.push++;
      const f = { seq: H.seq, t: H.t, off: H.off, rx, tf, ids: (H.tiles || []).map(d => d.id), keys: (H.tiles || []).filter(d => d.key !== false).map(d => d.id), app: H.app || {}, w: H.w, h: H.h, lost: false, hb: H.hb === true };
      if (f.hb) { if (W.live) W.liveAt = Date.now(); }     // the Controller (17c): a heartbeat = the last picture still stands -> keep the reading alive, read nothing
      else if (W.push % 37 === 0) { f.lost = true; W.lost++; }   // the Controller dropped it (busy): never read
      else {
        const d = decode(W, buf, tf); W.n++;
        f.view = d.st.view; f.bpm = d.st.clock ? d.st.clock.bpm : null; f.need = d.need; f.bad = d.bad;
        d.need.forEach(id => { W.need[id] = 1; }); d.bad.forEach(b => W.bad.push('seq ' + H.seq + ' ' + b));
        const e = d.st.next.find(x => x.num === 97 && x.d === 0 && x.type === 'drop'); if (e) f.drop = { t: e.t, known: e.known };
        if (d.st.view === 'decks') { W.live = true; W.liveAt = Date.now(); }
      }
      W.frames.push(f);
      const need = Object.keys(W.need); W.need = {};
      return json(res, 200, { ok: true, rx, t: Date.now(), need, prog: SR.VER, fps: 12, live: W.live && Date.now() - W.liveAt < 1500 });
    }
    if (req.method === 'POST' && u === '/reset') { const b = JSON.parse((await readRaw(req)).toString() || '{}'); newRun(b.run); return json(res, 200, { ok: true, run: W.name }); }
    if (req.method === 'POST' && u === '/map') { const b = JSON.parse((await readRaw(req)).toString() || '{}'); W.h0 = b.h0; return json(res, 200, { ok: true }); }
    if (req.method === 'GET' && u === '/check') return json(res, 200, check(qs.get('kind') || W.name));
    if (req.method === 'GET' && u === '/frames') return json(res, 200, W.frames);
    json(res, 404, { ok: false, error: 'no route ' + u });
  } catch (e) { json(res, 500, { ok: false, error: String(e && e.stack || e) }); }
}).listen(PORT, '127.0.0.1', () => console.log('stand-in Controller (stem reader ' + SR.VER + ') on http://127.0.0.1:' + PORT));

/* ---- what the run must show ---- */
function check(kind) {
  const P = [], F = [], info = {}; const ok = (c, m) => (c ? P : F).push(m);
  const fr = W.frames, read = fr.filter(f => !f.lost && f.view !== undefined), h0 = W.h0;
  info.pushes = W.push; info.read = read.length; info.lost = W.lost; info.progGets = W.progGets;
  ok(W.progGets >= 1, 'the app asked for the program (GET /sr/program x' + W.progGets + ')');
  ok(W.bad.length === 0, 'every tile decoded cleanly' + (W.bad.length ? ': ' + W.bad.slice(0, 5).join(' | ') : ''));
  // delta chain: a lost packet breaks it -> the reader asks for a whole tile -> the app sends one within 3 packets
  let unrec = 0, needs = 0;
  fr.forEach((f, i) => { (f.need || []).forEach(id => { needs++; const later = fr.slice(i + 1, i + 6).filter(g => g.ids.indexOf(id) >= 0); if (!later.length || later[0].keys.indexOf(id) < 0) { if (fr.length - i > 6) unrec++; } }); });
  info.needs = needs; info.mismatches = W.mismatch.length;
  ok(unrec === 0, 'every tile the reader asked for came back whole (' + needs + ' asks, ' + unrec + ' not answered)');
  // clock: the frame times (the iPad clock + the measured offset) land on the Controller's clock
  const lag = read.slice(10).filter(f => typeof f.off === 'number').map(f => f.tf - f.rx).sort((a, b) => a - b);
  if (lag.length) { info.clock = { median: Math.round(lag[lag.length >> 1]), min: Math.round(lag[0]), max: Math.round(lag[lag.length - 1]) }; ok(Math.abs(info.clock.median) < 150, 'frame times synced to this clock (capture - arrival: median ' + info.clock.median + ' ms)'); }
  else ok(false, 'no frame carried a clock offset');
  if (kind === 'main') {
    const span = fr.length ? (fr[fr.length - 1].rx - fr[0].rx) / 1000 : 0, rate = read.length / Math.max(1, span);
    info.rate = +rate.toFixed(1);
    ok(read.length >= 120, 'frames read: ' + read.length + ' (' + info.rate + ' a second)');
    const late = read.filter(f => h0 != null && f.t - h0 > 1 && f.t - h0 < 18);
    const decks = late.filter(f => f.view === 'decks').length; info.decks = decks + '/' + late.length;
    ok(late.length > 0 && decks >= 0.9 * late.length, 'the reader sees djay\'s decks in ' + decks + ' of ' + late.length + ' frames');
    const bpm = read.filter(f => f.bpm && h0 != null && f.t - h0 > 13 && f.t - h0 < 18).map(f => f.bpm).sort((a, b) => a - b);   // the last 5 s of the clip
    info.bpm = bpm.length ? bpm[bpm.length >> 1] : null; info.bpmRange = bpm.length ? [bpm[0], bpm[bpm.length - 1]] : null;
    ok(info.bpm && Math.abs(info.bpm - 140) < 1.0, 'djay\'s grid read at ' + info.bpm + ' BPM (140; ' + JSON.stringify(info.bpmRange) + ' over the last 5 s)');
    const first = read.find(f => f.drop);
    if (first && h0 != null) { const tc = first.drop.t - first.off / 1000 - h0, ahead = first.drop.t - first.drop.known; info.drop = { at: +tc.toFixed(3), ahead: +ahead.toFixed(2) };
      ok(Math.abs(tc - 15.30) < 0.1, 'the drop (deck 1, bar 97) lands at ' + tc.toFixed(3) + ' s in the clip (15.30 expected)');
      ok(ahead >= 2.0, 'the drop is known ' + ahead.toFixed(2) + ' s ahead (>= 2 s)'); }
    else ok(false, 'the drop at bar 97 was never seen');
    const hb = fr.filter(f => f.hb && h0 != null && f.t - h0 > 18.2).length; info.heartbeats = hb;
    ok(hb >= 2, 'heartbeats while the screen stood still: ' + hb);
    const fs16 = W.extra.FS || 0; info.FS = fs16; ok(fs16 >= 2, 'the whole-screen thumbnail (FS) arrived ' + fs16 + ' times');
    const cnt = id => fr.filter(f => f.ids.indexOf(id) >= 0).length; info.tiles = { LN: cnt('LN'), MX: cnt('MX'), LOW: cnt('LOW'), TOP: cnt('TOP'), TR: cnt('TR') };
    ok(info.tiles.MX >= 0.9 * info.tiles.LN - 6 && info.tiles.LOW >= 0.4 * info.tiles.LN - 6 && info.tiles.TOP >= 0.15 * info.tiles.LN && info.tiles.TR >= 0.25 * info.tiles.LN, 'every tile at its rate ' + JSON.stringify(info.tiles));
    const wh = read.filter(f => f.w === 2732 && f.h === 2048).length; ok(wh === read.length, 'frames report the 2732 x 2048 screen (' + wh + '/' + read.length + ')');
  }
  if (kind === 'flip') {
    const rots = []; fr.forEach(f => { const r = f.app.rot; if (!rots.length || rots[rots.length - 1].rot !== r) rots.push({ rot: r, t: h0 != null ? +(f.t - h0).toFixed(2) : null, from: f.app.rotFrom }); });
    info.rotations = rots;
    ok(rots.length >= 2, 'the picture was turned the other way up (' + rots.map(r => r.rot + '@' + r.t + 's').join(' -> ') + ')');
    const flipAt = rots.length >= 2 ? rots[1].t : null;
    ok(flipAt != null && flipAt >= 5 && flipAt <= 9, 'after about 6 s without djay (' + flipAt + ' s)');
    const after = read.filter(f => flipAt != null && h0 != null && f.t - h0 > flipAt + 1.5);
    const decks = after.filter(f => f.view === 'decks').length; info.decksAfter = decks + '/' + after.length;
    ok(after.length > 10 && decks >= 0.9 * after.length, 'then the reader sees djay\'s decks (' + decks + '/' + after.length + ')');
    ok(rots.length === 2, 'and it stays that way (' + rots.length + ' rotations)');
  }
  return { kind, pass: P, fail: F, info };
}
