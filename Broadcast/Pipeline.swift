// Stem Eye -- the broadcast's engine: screen frames in -> tiles -> POST /sr/push on the Controller, about 12 a second.
//   * one request in flight; a frame that arrives while one is out is skipped (never queued: old pictures are useless)
//   * every frame carries its capture time on this iPad's clock + the offset to the Controller's clock, measured NTP-style off
//     every answer (the Controller's rx / t vs our send / receive), so the Controller knows when each picture was on the screen
//   * the Controller's answer can ask for whole tiles again (need), a frame rate, or a new program (prog)
//   * ReplayKit sends nothing while the screen stands still: a HEARTBEAT (a header with hb:true, no tiles) every second
//     tells the Controller the last picture still stands (it keeps its reading, without reading a frame again)
//   * rotation: ReplayKit's orientation tag (or the picture's shape); if the Controller can't see djay's decks for 6 s the
//     picture is tried the other way up, until it does once (then kept, and remembered)
// No ReplayKit / UIKit in here: the same file runs in the macOS check on GitHub (ci/), fed from a djay screen recording.
import Foundation
import CoreMedia
import CoreVideo
import ImageIO

final class Pipeline {
    struct Config {
        var settings: () -> Settings = { Shared.settings() }
        var publish: (Status) -> Void = { Shared.setStatus($0) }
        /// the automatic rotation was found to be half a turn off: remember it for the next broadcast
        var learnFlip: (Int) -> Void = { f in
            var s = Shared.load(Settings.self, "settings") ?? Settings()
            if s.flip != f { s.flip = f; Shared.save(s) }
        }
        var device = Pipeline.deviceName()
        var appVersion = Pipeline.appVersion()
    }

    private struct Reply: Decodable {
        let ok: Bool?
        let rx: Double?
        let t: Double?
        let need: [String]?
        let prog: String?
        let fps: Double?
        let live: Bool?
        let error: String?
    }

    let q = DispatchQueue(label: "stemeye.pipeline", qos: .userInitiated)
    private let cfg: Config
    private let session: URLSession
    private let sampler = TileSampler()
    private var settings = Settings()
    private var base: URL?
    private var running = false
    private var paused = false
    private var timer: DispatchSourceTimer?

    // sending
    private var busy = false
    private var seq = 0
    private var lastSend = 0.0          // host clock s
    private var lastFrame = 0.0
    private var nextTry = 0.0
    private var fails = 0
    private var serverFps = 12.0
    private var fetching = false
    private var lastProgTry = -100.0
    private var progNote = "built-in"
    // clock sync
    private var offMs: Double?
    private var bestDelta = Double.greatestFiniteMagnitude
    private var rttMs: Double?
    // rotation
    private var flip = 0
    private var rotLocked = false
    private var confirmedRot = -1         // the rotation the Controller recognised djay with (automatic mode)
    private var notLiveSince = 0.0
    private var lastRot = -1
    private var rotFrom = ""
    private var clockSrc = ""
    // what the Controller says
    private var live = false
    private var liveAt = 0.0
    // stats
    private var sent = 0, errors = 0, heartbeats = 0, skipped = 0
    private var sentBytes = 0
    private var lastError = ""
    private var problem = ""
    private var screen = "", buffer = ""
    private var lastW = Program.builtIn.W, lastH = Program.builtIn.H
    private var statAt = 0.0, statSent = 0, statBytes = 0
    private var settingsAt = 0.0
    private var state = "idle"

    init(_ cfg: Config = Config()) {
        self.cfg = cfg
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 6
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        oq.underlyingQueue = q            // every answer is handled on q: all state lives on one queue
        session = URLSession(configuration: c, delegate: nil, delegateQueue: oq)
    }

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    // MARK: - ReplayKit calls these (from its own threads)

    /// nil = started; else why not (shown to the user as the broadcast's error)
    func start() -> String? {
        return q.sync { () -> String? in
            settings = cfg.settings()
            settingsAt = Pipeline.hostNow()
            flip = settings.rotation < 0 ? (settings.flip & 2) : 0
            base = Shared.baseURL(settings.controller)
            guard base != nil else {
                state = "no address"
                publish(force: true)
                return "Open the Stem Eye app and enter the Controller's address first."
            }
            running = true
            paused = false
            state = "connecting"
            fetchProgram()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            publish(force: true)
            return nil
        }
    }

    func pause(_ p: Bool) {
        q.sync {
            paused = p
            state = p ? "paused" : "connecting"
            publish(force: true)
        }
    }

    func stop() {
        q.sync {
            running = false
            timer?.cancel()
            timer = nil
            state = "stopped"
            publish(force: true)
        }
        session.invalidateAndCancel()
    }

    /// one screen frame; orientation = ReplayKit's RPVideoSampleOrientationKey (a CGImagePropertyOrientation), if any
    func video(_ sb: CMSampleBuffer, orientation: UInt32?) {
        q.sync { onVideo(sb, orientation) }
    }

    // MARK: - frames

    private func onVideo(_ sb: CMSampleBuffer, _ orient: UInt32?) {
        let now = Pipeline.hostNow()
        lastFrame = now
        guard running, !paused, let base = base else { return }
        if busy { skipped += 1; return }
        if now < nextTry { return }
        let fps = max(1, min(settings.maxFps, serverFps))
        if lastSend > 0 && now - lastSend < 1.0 / fps - 0.006 { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // the capture time: ReplayKit stamps frames on the host clock -- anything else (a test clip) -> the arrival time
        var t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if !t.isFinite || abs(now - t) > 1.0 { t = now; clockSrc = "arrival" } else { clockSrc = "pts" }
        let r = pickRotation(orient, pb)
        if r != lastRot { sampler.forceKeys(); lastRot = r }
        seq += 1
        do {
            let out = try sampler.sample(pb, rot: r, nowS: now, seq: seq)
            screen = "\(out.dispW) x \(out.dispH)"
            buffer = "\(CVPixelBufferGetWidth(pb)) x \(CVPixelBufferGetHeight(pb)) " + TileSampler.fourCC(CVPixelBufferGetPixelFormatType(pb))
            lastW = out.dispW
            lastH = out.dispH
            if out.tiles.isEmpty { return }
            let pkt = try packet(tiles: out.tiles, payload: out.payload, t: t, w: out.dispW, h: out.dispH, r: r)
            problem = ""
            post(pkt, to: base, now: now)
        } catch {
            problem = "\(error)"
            screen = ""
            buffer = "\(CVPixelBufferGetWidth(pb)) x \(CVPixelBufferGetHeight(pb)) " + TileSampler.fourCC(CVPixelBufferGetPixelFormatType(pb))
        }
    }

    /// quarter turns clockwise that stand the picture up
    private func pickRotation(_ o: UInt32?, _ pb: CVPixelBuffer) -> Int {
        if settings.rotation >= 0 { rotFrom = "manual"; return settings.rotation & 3 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var r = -1
        var from = "shape"
        if let o = o, let e = CGImagePropertyOrientation(rawValue: o) {
            switch e {
            case .up, .upMirrored: r = 0
            case .right, .rightMirrored: r = 1
            case .down, .downMirrored: r = 2
            case .left, .leftMirrored: r = 3
            @unknown default: r = -1
            }
            from = "tag"
            // djay runs landscape: a tag that would make the picture portrait is not believed
            if r >= 0 && ((r % 2 == 0) ? (w < h) : (w > h)) { r = -1; from = "shape (tag says portrait)" }
        }
        if r < 0 {
            // no usable tag: the rotation the Controller already recognised djay with, if the picture has the same shape
            if rotLocked, confirmedRot >= 0, (confirmedRot % 2 == 1) == (w < h) { rotFrom = "learned"; return confirmedRot }
            r = w >= h ? 0 : 1
        }
        rotFrom = flip != 0 ? from + " + flipped" : from
        return (r + flip) & 3
    }

    private func packet(tiles: [[String: Any]], payload: Data, t: Double, w: Int, h: Int, r: Int, hb: Bool = false) throws -> Data {
        let app: [String: Any] = ["ver": cfg.appVersion, "fps": max(1, min(settings.maxFps, serverFps)), "rot": r, "rotFrom": rotFrom,
                                  "clock": clockSrc, "prog": sampler.program.v]
        var head: [String: Any] = ["v": 1, "dev": cfg.device, "seq": seq, "t": t, "w": w, "h": h, "tiles": tiles, "app": app]
        if hb { head["hb"] = true }
        if let o = offMs { head["off"] = o } else { head["off"] = NSNull() }
        let hj = try JSONSerialization.data(withJSONObject: head, options: [])
        var d = Data(capacity: 8 + hj.count + payload.count)
        d.append(contentsOf: [0x53, 0x52, 0x50, 0x31])                       // "SRP1"
        let n = UInt32(hj.count)
        d.append(contentsOf: [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)])
        d.append(hj)
        d.append(payload)
        return d
    }

    // MARK: - network

    private func post(_ body: Data, to base: URL, now: Double) {
        var req = URLRequest(url: base.appendingPathComponent("sr/push"))
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 2.5
        busy = true
        lastSend = now
        let t0 = Pipeline.hostNow()
        let n = body.count
        session.uploadTask(with: req, from: body) { [weak self] data, resp, err in
            self?.answer(data, resp, err, t0: t0, bytes: n)
        }.resume()
    }

    private func answer(_ data: Data?, _ resp: URLResponse?, _ err: Error?, t0: Double, bytes: Int) {
        let t1 = Pipeline.hostNow()
        busy = false
        guard running else { return }
        if let e = err { fail("can't reach the Controller: " + e.localizedDescription); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let d = data, let j = try? JSONDecoder().decode(Reply.self, from: d), j.ok != false else {
            if code == 404 { fail("the Controller has no stem reader -- update it to build 17c or later") }
            else {
                var why = ""
                if let d = data, let j = try? JSONDecoder().decode(Reply.self, from: d), let e = j.error { why = ": " + e }
                fail("the Controller answered \(code)" + why)
            }
            return
        }
        fails = 0
        nextTry = 0
        sent += 1
        sentBytes += bytes
        if state != "sending" { state = "sending" }
        // clock: NTP style -- offset = ((rx - t0) + (t - t1)) / 2, trusted from the quickest exchanges
        if let rx = j.rx, let ts = j.t {
            let a = t0 * 1000, b = t1 * 1000
            let delta = (b - a) - (ts - rx)
            let o = ((rx - a) + (ts - b)) / 2
            rttMs = b - a
            bestDelta += 0.02                   // drifts up slowly, so a changed network is learned again
            if delta < bestDelta + 4 {
                bestDelta = min(bestDelta, delta)
                if let p = offMs, abs(o - p) < 1000 { offMs = p * 0.8 + o * 0.2 } else { offMs = o }
            }
        }
        if let need = j.need, !need.isEmpty { sampler.needKey.formUnion(need) }
        if let f = j.fps, f >= 1, f <= 30 { serverFps = f }
        let now = t1
        live = j.live ?? false
        if live { liveAt = now }
        let progChanged = j.prog.map { $0 != sampler.program.v } ?? false
        if (progChanged || progNote == "built-in"), !fetching, now - lastProgTry > 5 { fetchProgram() }   // also: the first fetch failed
        autoRotate(now)
    }

    private func fail(_ why: String) {
        errors += 1
        fails += 1
        lastError = why
        nextTry = Pipeline.hostNow() + min(3.0, 0.25 * pow(2.0, Double(min(fails, 6) - 1)))
        sampler.forceKeys()               // the Controller may have missed the base of the next delta
        if fails >= 3 { state = "can't reach" }
    }

    /// the picture the other way up until the Controller recognises djay once (automatic rotation only)
    private func autoRotate(_ now: Double) {
        guard settings.rotation < 0, !rotLocked else { return }
        if live {
            rotLocked = true
            confirmedRot = lastRot
            notLiveSince = 0
            cfg.learnFlip(flip)
            return
        }
        if notLiveSince == 0 { notLiveSince = now; return }
        if now - notLiveSince > 6 {
            flip = (flip + 2) & 3
            notLiveSince = now
            sampler.forceKeys()
        }
    }

    private func fetchProgram() {
        guard let base = base, !fetching else { return }
        fetching = true
        lastProgTry = Pipeline.hostNow()
        var req = URLRequest(url: base.appendingPathComponent("sr/program"))
        req.timeoutInterval = 3
        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.fetching = false
            guard err == nil, (resp as? HTTPURLResponse)?.statusCode == 200, let d = data,
                  let p = try? JSONDecoder().decode(Program.self, from: d), p.usable else { return }
            if p.v != self.sampler.program.v || p.tiles != self.sampler.program.tiles || p.keyEvery != self.sampler.program.keyEvery {
                self.sampler.setProgram(p)        // new tiles -> all whole next frame
            }
            self.progNote = "Controller " + p.v
        }.resume()
    }

    // MARK: - every half second

    private func tick() {
        guard running else { return }
        let now = Pipeline.hostNow()
        if now - settingsAt > 2 { reloadSettings(now) }
        // a still screen: ReplayKit sends nothing -> a heartbeat: 'the last picture still stands' (no tiles, ~300 bytes)
        if !paused && !busy && now >= nextTry && now - lastSend > 1.0 && now - lastFrame > 0.9 && lastRot >= 0, let base = base {
            seq += 1
            heartbeats += 1
            if let pkt = try? packet(tiles: [], payload: Data(), t: now, w: lastW, h: lastH, r: lastRot, hb: true) {
                post(pkt, to: base, now: now)
            }
        }
        publish(force: false)
    }

    private func reloadSettings(_ now: Double) {
        settingsAt = now
        let s = cfg.settings()
        if s.controller != settings.controller {
            base = Shared.baseURL(s.controller)
            offMs = nil
            bestDelta = Double.greatestFiniteMagnitude
            sampler.forceKeys()
            fetchProgram()
        }
        if s.rotation != settings.rotation {
            rotLocked = false
            confirmedRot = -1
            notLiveSince = 0
            flip = s.rotation < 0 ? (s.flip & 2) : 0
            sampler.forceKeys()
        }
        settings = s
    }

    private func publish(force: Bool) {
        let now = Pipeline.hostNow()
        if !force && now - statAt < 2 { return }
        let dt = max(0.5, now - statAt)
        var s = Status()
        s.state = state
        if !problem.isEmpty { s.detail = problem }
        else if running && !paused && lastFrame == 0 { s.detail = "no picture from ReplayKit yet" }
        else if running && !paused && now - lastFrame > 3 { s.detail = "the screen is standing still (the lanes are re-sent every second)" }
        s.fps = statAt > 0 ? Double(sent - statSent) / dt : 0
        s.kbps = statAt > 0 ? Double(sentBytes - statBytes) / dt / 1024 : 0
        s.sent = sent
        s.errors = errors
        s.lastError = lastError
        s.rot = lastRot < 0 ? 0 : lastRot
        s.rotFrom = rotFrom
        s.live = live && now - liveAt < 3
        s.prog = progNote
        s.screen = screen
        s.buffer = buffer
        s.clock = clockSrc
        s.offMs = offMs
        s.rttMs = rttMs
        s.controller = base?.absoluteString ?? ""
        statAt = now
        statSent = sent
        statBytes = sentBytes
        cfg.publish(s)
    }

    // MARK: - who we are

    static func deviceName() -> String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw -> String in
            let b = raw.prefix(while: { $0 != 0 })
            return String(decoding: b, as: UTF8.self)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return machine + " (OS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))"
    }

    static func appVersion() -> String {
        let i = Bundle.main.infoDictionary ?? [:]
        let a = (i["CFBundleShortVersionString"] as? String) ?? "?"
        let b = (i["CFBundleVersion"] as? String) ?? "?"
        return a + " (" + b + ")"
    }
}
