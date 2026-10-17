// Stem Eye CI check -- runs on GitHub's Mac (ci/check.sh). The iPad's own frame code (TileSampler + Pipeline, compiled for
// macOS) is fed a djay screen recording decoded to NV12 like ReplayKit's frames, and talks to a stand-in Controller
// (ci/reader-server.js: the Controller's own stem reader + packet decoding).
//   1. SAMPLER: the same tiles whichever way up the picture comes (quarter turns, byte for byte), in BGRA, in video range,
//      at half size; the deflate is raw DEFLATE; how long a frame takes
//   2. PIPELINE in real time: the reader sees djay's decks, locks the 140 BPM grid and calls the drop at bar 97 >= 2 s ahead;
//      clock sync, lost-packet recovery, heartbeats while the screen stands still, the FS thumbnail
//   3. PIPELINE with a portrait picture and a WRONG orientation tag: it turns the picture round by itself within ~7 s
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Compression

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
func ok(_ c: Bool, _ m: String) {
    print((c ? "PASS  " : "FAIL  ") + m)
    if !c { failures += 1 }
}

let args = CommandLine.arguments
if args.count < 3 {
    print("usage: stemeye-check <djay-clip.mp4> <http://127.0.0.1:18990>")
    exit(2)
}
let clipURL = URL(fileURLWithPath: args[1])
let server = args[2]

// MARK: - helpers

final class Res: @unchecked Sendable { var code = 0; var data: Data? }

func http(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (Int, [String: Any]?) {
    var req = URLRequest(url: URL(string: server + path)!)
    req.httpMethod = method
    req.timeoutInterval = 15
    if let b = body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    let res = Res()
    URLSession.shared.dataTask(with: req) { d, r, _ in
        res.data = d
        res.code = (r as? HTTPURLResponse)?.statusCode ?? 0
        sem.signal()
    }.resume()
    sem.wait()
    var j: [String: Any]? = nil
    if let d = res.data { j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    return (res.code, j)
}

/// every frame of the clip as NV12 (full range, like ReplayKit), with its time in the clip
func eachFrame(_ body: (CVPixelBuffer, Double) -> Bool) {
    let asset = AVURLAsset(url: clipURL)
    guard let track = asset.tracks(withMediaType: .video).first else { ok(false, "the clip has a video track"); return }
    do {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        if !reader.startReading() { ok(false, "decode the clip: \(String(describing: reader.error))"); return }
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if !body(pb, t) { reader.cancelReading(); break }
        }
    } catch {
        ok(false, "decode the clip: \(error)")
    }
}

func newBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    let st = CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb)
    precondition(st == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate \(st)")
    return pb!
}

func plane(_ pb: CVPixelBuffer, _ i: Int) -> (UnsafeMutablePointer<UInt8>, Int, Int, Int) {
    let p = CVPixelBufferGetBaseAddressOfPlane(pb, i)!.assumingMemoryBound(to: UInt8.self)
    return (p, CVPixelBufferGetBytesPerRowOfPlane(pb, i), CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i))
}

/// a copy turned k quarter turns COUNTER-clockwise: the sampler's rot k must stand it up again
func rotatedCCW(_ src: CVPixelBuffer, _ k: Int) -> CVPixelBuffer {
    let W = CVPixelBufferGetWidth(src), H = CVPixelBufferGetHeight(src)
    let dst = k % 2 == 1 ? newBuffer(H, W, CVPixelBufferGetPixelFormatType(src)) : newBuffer(W, H, CVPixelBufferGetPixelFormatType(src))
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
    for pi in 0..<2 {
        let bpp = pi == 0 ? 1 : 2
        let (sp, ss, sw, sh) = plane(src, pi)
        let (dp, ds, dw, dh) = plane(dst, pi)
        for y in 0..<dh {
            let drow = dp + y * ds
            for x in 0..<dw {
                let sx: Int, sy: Int
                switch k {
                case 1: sx = sw - 1 - y; sy = x
                case 2: sx = sw - 1 - x; sy = sh - 1 - y
                case 3: sx = y; sy = sh - 1 - x
                default: sx = x; sy = y
                }
                let so = sy * ss + sx * bpp
                drow[x * bpp] = sp[so]
                if bpp == 2 { drow[x * bpp + 1] = sp[so + 1] }
            }
        }
    }
    return dst
}

/// the same picture as BGRA (BT.709 full range), like a device that hands over RGB
func asBGRA(_ src: CVPixelBuffer) -> CVPixelBuffer {
    let W = CVPixelBufferGetWidth(src) & ~1, H = CVPixelBufferGetHeight(src) & ~1
    let dst = newBuffer(W, H, kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
    let (yp, ys, _, _) = plane(src, 0), (cp, cs, _, _) = plane(src, 1)
    let dp = CVPixelBufferGetBaseAddress(dst)!.assumingMemoryBound(to: UInt8.self), ds = CVPixelBufferGetBytesPerRow(dst)
    func c8(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v.rounded()))) }
    for y in 0..<H {
        for x in 0..<W {
            let Y = Double(yp[y * ys + x]), q = (y >> 1) * cs + (x & ~1)
            let Cb = Double(cp[q]) - 128, Cr = Double(cp[q + 1]) - 128
            let o = y * ds + x * 4
            dp[o + 2] = c8(Y + 1.5748 * Cr); dp[o + 1] = c8(Y - 0.1873 * Cb - 0.4681 * Cr); dp[o] = c8(Y + 1.8556 * Cb); dp[o + 3] = 255
        }
    }
    return dst
}

/// the same picture in VIDEO range (Y 16-235, C 16-240)
func asVideoRange(_ src: CVPixelBuffer) -> CVPixelBuffer {
    let W = CVPixelBufferGetWidth(src), H = CVPixelBufferGetHeight(src)
    let dst = newBuffer(W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
    for pi in 0..<2 {
        let (sp, ss, sw, sh) = plane(src, pi), (dp, ds, _, _) = plane(dst, pi)
        let n = pi == 0 ? sw : sw * 2
        for y in 0..<sh {
            for x in 0..<n {
                let v = Double(sp[y * ss + x])
                dp[y * ds + x] = UInt8((pi == 0 ? 16 + v * 219 / 255 : 128 + (v - 128) * 224 / 255).rounded())
            }
        }
    }
    return dst
}

/// the same picture at half size (a device whose capture is smaller than the screen)
func halfSize(_ src: CVPixelBuffer) -> CVPixelBuffer {
    let W = CVPixelBufferGetWidth(src) / 2, H = CVPixelBufferGetHeight(src) / 2
    let dst = newBuffer(W & ~1, H & ~1, CVPixelBufferGetPixelFormatType(src))
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
    for pi in 0..<2 {
        let bpp = pi == 0 ? 1 : 2
        let (sp, ss, _, _) = plane(src, pi), (dp, ds, dw, dh) = plane(dst, pi)
        for y in 0..<dh {
            for x in 0..<dw {
                for c in 0..<bpp {
                    let a = Int(sp[(2 * y) * ss + (2 * x) * bpp + c]) + Int(sp[(2 * y) * ss + (2 * x + 1) * bpp + c])
                    let b = Int(sp[(2 * y + 1) * ss + (2 * x) * bpp + c]) + Int(sp[(2 * y + 1) * ss + (2 * x + 1) * bpp + c])
                    dp[y * ds + x * bpp + c] = UInt8((a + b + 2) / 4)
                }
            }
        }
    }
    return dst
}

func rgb(_ b: [UInt8]) -> [Int] {
    var o = [Int](repeating: 0, count: b.count / 2 * 3)
    for i in 0..<(b.count / 2) {
        let v = Int(b[2 * i]) | (Int(b[2 * i + 1]) << 8)
        let r = (v >> 11) & 31, g = (v >> 5) & 63, bl = v & 31
        o[3 * i] = (r << 3) | (r >> 2); o[3 * i + 1] = (g << 2) | (g >> 4); o[3 * i + 2] = (bl << 3) | (bl >> 2)
    }
    return o
}

func diff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double) {
    let x = rgb(a), y = rgb(b)
    if x.count != y.count || x.isEmpty { return (999, 999) }
    var m = 0, s = 0
    for i in 0..<x.count { let d = abs(x[i] - y[i]); s += d; if d > m { m = d } }
    return (m, Double(s) / Double(x.count))
}

func sampleBuffer(_ pb: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
    var fd: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd) == noErr, let f = fd else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
                                    decodeTimeStamp: CMTime.invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: f,
                                                   sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
    return sb
}

let ids = Program.builtIn.tiles.map { $0.id }

// MARK: - 1. the sampler

print("== 1. sampler")
var checked = 0
var sampleMs: [Double] = []
eachFrame { pb, t in
    if t < 1.0 || checked >= 3 { return checked < 3 }
    if Int((t * 30).rounded()) % 45 != 0 { return true }      // a few frames, 1.5 s apart
    checked += 1
    let base = TileSampler()
    let t0 = Pipeline.hostNow()
    guard let out0 = try? base.sample(pb, rot: 0, nowS: 0, seq: 1) else { ok(false, "sample frame at \(t) s"); return false }
    sampleMs.append((Pipeline.hostNow() - t0) * 1000)
    if checked == 1 {
        ok(out0.dispW == 2732 && out0.dispH == 2048, "the clip is djay's 2732 x 2048 screen (\(out0.dispW) x \(out0.dispH))")
        ok(out0.tiles.count == ids.count, "the first frame sends every tile (\(out0.tiles.count) of \(ids.count))")
        // raw DEFLATE: the first tile's bytes inflate back to its pixels
        if let m = out0.tiles.first, let len = m["len"] as? Int, let px = base.lastPixels(m["id"] as? String ?? "") {
            var outb = [UInt8](repeating: 0, count: px.count + 16)
            let n = out0.payload.prefix(len).withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                outb.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, len, nil, COMPRESSION_ZLIB)
                }
            }
            ok(n == px.count && Array(outb[0..<px.count]) == px, "tile \(m["id"] ?? "?") inflates back to its \(px.count) bytes (raw DEFLATE)")
        }
    }
    for k in 1...3 {
        let rb = rotatedCCW(pb, k)
        let s = TileSampler()
        guard (try? s.sample(rb, rot: k, nowS: 0, seq: 1)) != nil else { ok(false, "sample the picture turned \(k * 90)"); continue }
        let same = ids.allSatisfy { s.lastPixels($0) == base.lastPixels($0) }
        ok(same, "frame \(checked): picture turned \(k * 90) degrees, rot \(k) gives the same tiles byte for byte")
    }
    let sb = TileSampler()
    if (try? sb.sample(asBGRA(pb), rot: 0, nowS: 0, seq: 1)) != nil {
        let d = ids.map { diff(sb.lastPixels($0) ?? [], base.lastPixels($0) ?? []) }
        let mx = d.map { $0.max }.max() ?? 999, mean = d.map { $0.mean }.max() ?? 999
        ok(mx <= 24 && mean <= 1.5, "frame \(checked): BGRA gives the same tiles (max \(mx), mean \(String(format: "%.2f", mean)) levels)")
    } else { ok(false, "sample a BGRA picture") }
    let sv = TileSampler()
    if (try? sv.sample(asVideoRange(pb), rot: 0, nowS: 0, seq: 1)) != nil {
        let d = ids.map { diff(sv.lastPixels($0) ?? [], base.lastPixels($0) ?? []) }
        let mx = d.map { $0.max }.max() ?? 999, mean = d.map { $0.mean }.max() ?? 999
        ok(mx <= 24 && mean <= 1.5, "frame \(checked): video range gives the same tiles (max \(mx), mean \(String(format: "%.2f", mean)) levels)")
    } else { ok(false, "sample a video-range picture") }
    let sh = TileSampler()
    if let oh = try? sh.sample(halfSize(pb), rot: 0, nowS: 0, seq: 1) {
        let d = ids.map { diff(sh.lastPixels($0) ?? [], base.lastPixels($0) ?? []) }
        let mean = d.map { $0.mean }.max() ?? 999
        ok(oh.dispW == 1366 && mean <= 8, "frame \(checked): a half-size capture still lands on the same crops (mean \(String(format: "%.2f", mean)) levels)")
    } else { ok(false, "sample a half-size picture") }
    // a second frame from the same sampler: deltas for the slow tiles, whole tiles where they must be
    if let out1 = try? base.sample(pb, rot: 0, nowS: 0.5, seq: 2) {
        let keyed = out1.tiles.filter { ($0["key"] as? Bool) == true }.compactMap { $0["id"] as? String }
        let deltas = out1.tiles.filter { ($0["key"] as? Bool) == false }
        let bases = deltas.allSatisfy { ($0["base"] as? Int) == 1 }
        ok(keyed == ["LN"] && !deltas.isEmpty && bases, "frame \(checked) again: LN whole, the rest XOR deltas on packet 1 (keys \(keyed))")
        let small = deltas.allSatisfy { ($0["len"] as? Int ?? 99999) < 4000 }
        ok(small, "an unchanged tile's delta is tiny (\(deltas.map { "\($0["id"]!) \($0["len"]!)" }.joined(separator: ", ")) bytes)")
    }
    return checked < 3
}
ok(checked == 3, "sampled \(checked) frames of the clip")
if !sampleMs.isEmpty {
    let avg = sampleMs.reduce(0, +) / Double(sampleMs.count)
    print("      one whole frame (every tile) takes \(String(format: "%.1f", avg)) ms here")
    ok(avg < 60, "sampling is fast enough (\(String(format: "%.1f", avg)) ms for a frame with every tile)")
}

// MARK: - 2 + 3. the pipeline against the stand-in Controller

final class Watch: @unchecked Sendable {
    let lock = NSLock()
    var last: Status?
    var flips: [Int] = []
    func set(_ s: Status) { lock.lock(); last = s; lock.unlock() }
    func get() -> Status? { lock.lock(); defer { lock.unlock() }; return last }
}

func run(_ name: String, turn: Int, tag: UInt32?, seconds: Double, every: Int, idle: Double) -> Watch {
    let w = Watch()
    _ = http("POST", "/reset", ["run": name])
    var s0 = Settings()
    s0.controller = server
    s0.rotation = -1
    s0.maxFps = 12
    let fixed = s0
    var cfg = Pipeline.Config()
    cfg.settings = { fixed }
    cfg.publish = { s in
        w.set(s)
        let off = s.offMs.map { String(format: "%.0f", $0) } ?? "-"
        print("      [\(name)] \(s.state) \(String(format: "%.1f", s.fps)) fps \(Int(s.kbps)) KB/s  sees djay: \(s.live)  rot \(s.rot) (\(s.rotFrom))  clock \(s.clock) off \(off) ms  \(s.detail) \(s.lastError)")
    }
    cfg.learnFlip = { f in w.lock.lock(); w.flips.append(f); w.lock.unlock() }
    cfg.device = "GitHub Mac (stem-eye CI)"
    cfg.appVersion = "ci"
    let pipe = Pipeline(cfg)
    if let why = pipe.start() { ok(false, "[\(name)] start: " + why); return w }
    let h0 = Pipeline.hostNow() + 0.5
    _ = http("POST", "/map", ["h0": h0])
    var n = 0, late = 0
    eachFrame { pb, p in
        if p > seconds { return false }
        n += 1
        if (n - 1) % every != 0 { return true }
        let due = h0 + p
        let wait = due - Pipeline.hostNow()
        if wait < -0.05 { late += 1; return true }       // behind (a slow runner): drop it, as ReplayKit would
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let buf = turn == 0 ? pb : rotatedCCW(pb, turn)
        if let sb = sampleBuffer(buf, pts: due) { pipe.video(sb, orientation: tag) }
        return true
    }
    Thread.sleep(forTimeInterval: idle)        // the screen stands still: ReplayKit would send nothing
    pipe.stop()
    if late > 0 { print("      [\(name)] \(late) frames dropped: this Mac decoded slower than real time") }
    return w
}

func report(_ kind: String) {
    let (code, j) = http("GET", "/check?kind=" + kind)
    guard code == 200, let r = j else { ok(false, "[\(kind)] the stand-in Controller answered /check (\(code))"); return }
    for m in (r["pass"] as? [String]) ?? [] { ok(true, "[\(kind)] " + m) }
    for m in (r["fail"] as? [String]) ?? [] { ok(false, "[\(kind)] " + m) }
    if let info = r["info"], let d = try? JSONSerialization.data(withJSONObject: info), let s = String(data: d, encoding: .utf8) {
        print("      [\(kind)] " + s)
    }
}

print("== 2. pipeline, real time, landscape picture")
let w1 = run("main", turn: 0, tag: nil, seconds: 18.0, every: 1, idle: 3.5)
report("main")
if let s = w1.get() {
    ok(s.clock == "pts", "frame times come from the frames' own timestamps (\(s.clock))")
    ok(s.errors == 0, "no network errors (\(s.errors) \(s.lastError))")
    ok(s.rotFrom == "shape" && s.rot == 0, "a landscape picture without a tag is used as it is (\(s.rot), \(s.rotFrom))")
} else { ok(false, "the pipeline published its status") }

print("== 3. pipeline, portrait picture with the wrong orientation tag")
// turned 90 degrees counter-clockwise = what ReplayKit's .right (6) means; tagged .left (8) instead -> upside down until it flips
let w2 = run("flip", turn: 1, tag: 8, seconds: 15.0, every: 2, idle: 1.0)
report("flip")
if let s = w2.get() {
    ok(s.live, "the Controller sees djay at the end (\(s.live))")
    ok(s.rotFrom.contains("flipped") && s.rot == 1, "the picture was turned round: rot \(s.rot) (\(s.rotFrom))")
} else { ok(false, "the pipeline published its status") }
w2.lock.lock(); let fl = w2.flips; w2.lock.unlock()
ok(fl == [2], "it remembers the half turn for the next broadcast (\(fl))")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
