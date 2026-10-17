// Stem Eye -- turns one screen frame into the Controller's TILES: crops of djay's screen, each shrunk by its own factor (a box
// average), as RGB565 little-endian, XOR'd against the last copy sent (except the tiles that change every frame), raw-DEFLATE'd.
// The crops + rates come from the Controller (GET /sr/program), so the reading can change without a new app build.
// Screen coordinates are djay's landscape screen (2732 x 2048 on a 12.9" iPad Pro). ReplayKit hands the picture over in the
// iPad's own (portrait) orientation -> 'rot' = quarter turns clockwise that stand it up.
// Foundation + CoreVideo + Compression only: the same file is compiled into the macOS check on GitHub (ci/).
import Foundation
import CoreVideo
import Compression

final class TileSampler {
    /// What one frame produced: the per-tile descriptions (for the packet header) + their bytes, back to back.
    struct Out {
        var tiles: [[String: Any]] = []
        var payload = Data()
        var dispW = 0
        var dispH = 0
        var keys = 0
        var raw = 0
    }

    enum Problem: Error, CustomStringConvertible {
        case format(OSType), portrait(Int, Int), locked, planes
        var description: String {
            switch self {
            case .format(let f): return "unsupported picture format " + TileSampler.fourCC(f)
            case .portrait(let w, let h): return "the picture is portrait (\(w) x \(h)) -- turn the iPad to landscape (or set the rotation)"
            case .locked: return "could not read the picture"
            case .planes: return "the picture has no pixel planes"
            }
        }
    }

    private(set) var program = Program.builtIn
    /// tiles the Controller asked to get whole again (it could not apply a delta)
    var needKey = Set<String>()

    private var tiles: [Tile] = []
    private var frameNo = 0
    private let scratch: UnsafeMutableRawPointer
    private var zbuf = [UInt8]()

    init() {
        let n = max(64, compression_encode_scratch_buffer_size(COMPRESSION_ZLIB))
        scratch = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        setProgram(Program.builtIn)
    }
    deinit { scratch.deallocate() }

    func setProgram(_ p: Program) {
        program = p
        tiles = p.tiles.map { Tile($0) }
        frameNo = 0
    }

    /// the next frame sends every tile whole (after a lost packet, a new rotation, a reconnect)
    func forceKeys() { for t in tiles { t.hasLast = false } }

    /// the pixels of a tile from the last frame (RGB565 LE) -- for the checks in ci/
    func lastPixels(_ id: String) -> [UInt8]? { tiles.first(where: { $0.spec.id == id })?.cur }

    /// Sample one frame. rot = quarter turns clockwise that stand the picture up. nowS = seconds on any steady clock (key timing).
    /// seq = the packet's sequence number (a delta names the packet that carried its base).
    func sample(_ pb: CVPixelBuffer, rot: Int, nowS: Double, seq: Int) throws -> Out {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let nv12 = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if !nv12 && fmt != kCVPixelFormatType_32BGRA { throw Problem.format(fmt) }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { throw Problem.locked }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        var src: Source
        if nv12 {
            guard CVPixelBufferGetPlaneCount(pb) >= 2,
                  let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                  let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { throw Problem.planes }
            src = Source(nv12: true,
                         p0: UnsafePointer(yb.assumingMemoryBound(to: UInt8.self)), s0: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                         p1: UnsafePointer(cb.assumingMemoryBound(to: UInt8.self)), s1: CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                         bw: CVPixelBufferGetWidthOfPlane(pb, 0), bh: CVPixelBufferGetHeightOfPlane(pb, 0),
                         full: fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, m709: TileSampler.is709(pb))
        } else {
            guard let b = CVPixelBufferGetBaseAddress(pb) else { throw Problem.planes }
            let p = UnsafePointer(b.assumingMemoryBound(to: UInt8.self))
            src = Source(nv12: false, p0: p, s0: CVPixelBufferGetBytesPerRow(pb), p1: p, s1: 0,
                         bw: CVPixelBufferGetWidth(pb), bh: CVPixelBufferGetHeight(pb), full: true, m709: true)
        }
        // NV12 chroma is one CbCr pair per 2 x 2 pixels: an odd size never happens on a screen, but stay inside the plane
        if src.nv12 { src.bw &= ~1; src.bh &= ~1 }
        if src.bw < 2 || src.bh < 2 { throw Problem.planes }

        let r = ((rot % 4) + 4) % 4
        let dispW = (r % 2 == 0) ? src.bw : src.bh
        let dispH = (r % 2 == 0) ? src.bh : src.bw
        if dispW < dispH { throw Problem.portrait(dispW, dispH) }
        let geo = Geo(nv12: src.nv12, bw: src.bw, bh: src.bh, s0: src.s0, s1: src.s1, r: r, dispW: dispW, dispH: dispH)

        var out = Out()
        out.dispW = dispW
        out.dispH = dispH
        let keyEvery = program.keyEvery ?? 2
        for t in tiles where frameNo % max(1, t.spec.every) == 0 {
            if t.geo != geo { t.build(geo, W: program.W, H: program.H); t.hasLast = false }
            shrink(src, t)
            let always = t.spec.key ?? (t.spec.id == "LN" || t.spec.id == "FS")
            let key = always || !t.hasLast || needKey.contains(t.spec.id) || nowS - t.keyAt >= keyEvery
            var meta: [String: Any] = ["id": t.spec.id, "x": t.spec.x, "y": t.spec.y, "w": t.spec.w, "h": t.spec.h, "s": t.spec.s,
                                       "fmt": "565", "key": key]
            if !key {
                meta["base"] = t.lastSeq
                t.xor.withUnsafeMutableBufferPointer { b in
                    t.cur.withUnsafeBufferPointer { c in
                        t.last.withUnsafeBufferPointer { p in
                            for i in 0..<b.count { b[i] = c[i] ^ p[i] }
                        }
                    }
                }
            }
            let body = key ? t.cur : t.xor
            if let z = deflate(body) {
                meta["enc"] = "z"; meta["len"] = z.count; out.payload.append(z)
            } else {
                meta["enc"] = "raw"; meta["len"] = body.count; out.payload.append(contentsOf: body)
            }
            out.tiles.append(meta)
            out.raw += body.count
            if key { out.keys += 1; t.keyAt = nowS; needKey.remove(t.spec.id) }
            // 'last' = what the Controller now holds (copied in place: no allocation per frame)
            t.last.withUnsafeMutableBufferPointer { l in
                t.cur.withUnsafeBufferPointer { c in
                    if let d = l.baseAddress, let s = c.baseAddress { memcpy(d, s, min(l.count, c.count)) }
                }
            }
            t.hasLast = true
            t.lastSeq = seq
        }
        frameNo += 1
        return out
    }

    // MARK: - pixels

    private struct Source {
        let nv12: Bool
        let p0: UnsafePointer<UInt8>
        let s0: Int
        let p1: UnsafePointer<UInt8>
        let s1: Int
        var bw: Int
        var bh: Int
        let full: Bool
        let m709: Bool
    }

    /// everything the sample maps depend on
    private struct Geo: Equatable {
        let nv12: Bool, bw: Int, bh: Int, s0: Int, s1: Int, r: Int, dispW: Int, dispH: Int
    }

    /// One tile: its spec, its sample maps (byte offsets into the picture, split into a column part + a row part -- each buffer
    /// coordinate depends on only one screen coordinate for every quarter turn, so offset = col[x] + row[y]), and its pixels.
    private final class Tile {
        let spec: TileSpec
        let cw: Int, ch: Int
        var m = 1                         // samples per block side
        var colA = [Int](), rowA = [Int]()   // luma (NV12) / pixel (BGRA) offsets
        var colC = [Int](), rowC = [Int]()   // chroma pair offsets (NV12)
        var geo: Geo? = nil
        var cur: [UInt8]                  // this frame's pixels
        var last: [UInt8]                 // the copy the Controller holds
        var xor: [UInt8]                  // cur ^ last (a delta)
        var hasLast = false
        var lastSeq = 0
        var keyAt = -Double.greatestFiniteMagnitude

        init(_ s: TileSpec) {
            spec = s
            // the Controller sizes a tile as Math.round(w / s) x Math.round(h / s): the same here
            cw = max(1, Int((Double(s.w) / Double(s.s)).rounded()))
            ch = max(1, Int((Double(s.h) / Double(s.s)).rounded()))
            cur = [UInt8](repeating: 0, count: cw * ch * 2)
            last = [UInt8](repeating: 0, count: cw * ch * 2)
            xor = [UInt8](repeating: 0, count: cw * ch * 2)
        }

        func build(_ g: Geo, W: Int, H: Int) {
            geo = g
            let s = spec.s
            // full box average for small blocks (what the reader was tuned on); 4 x 4 evenly spread samples for big ones
            let step = s <= 4 ? 1 : max(1, s / 4)
            m = (s + step - 1) / step
            let exact = g.dispW == W && g.dispH == H
            let kx = Double(g.dispW) / Double(W), ky = Double(g.dispH) / Double(H)
            func disp(_ v: Int, _ k: Double, _ lim: Int) -> Int {
                let d = exact ? v : Int((Double(v) + 0.5) * k)
                return min(max(d, 0), lim - 1)
            }
            colA = [Int](repeating: 0, count: cw * m); colC = colA
            rowA = [Int](repeating: 0, count: ch * m); rowC = rowA
            let bpp = g.nv12 ? 1 : 4
            for tx in 0..<cw {
                for i in 0..<m {
                    let dx = disp(spec.x + tx * s + min(s - 1, i * step + step / 2), kx, g.dispW)
                    // which buffer coordinate a screen column drives, per quarter turn (display (dx,dy) -> buffer (bx,by)):
                    // r0: (dx, dy)   r1: (dy, bh-1-dx)   r2: (bw-1-dx, bh-1-dy)   r3: (bw-1-dy, dx)
                    var bx = 0, by = 0
                    switch g.r {
                    case 1: by = g.bh - 1 - dx
                    case 2: bx = g.bw - 1 - dx
                    case 3: by = dx
                    default: bx = dx
                    }
                    let k = tx * m + i
                    colA[k] = by * g.s0 + bx * bpp
                    colC[k] = (by >> 1) * g.s1 + (bx & ~1)
                }
            }
            for ty in 0..<ch {
                for j in 0..<m {
                    let dy = disp(spec.y + ty * s + min(s - 1, j * step + step / 2), ky, g.dispH)
                    var bx = 0, by = 0
                    switch g.r {
                    case 1: bx = dy
                    case 2: by = g.bh - 1 - dy
                    case 3: bx = g.bw - 1 - dy
                    default: by = dy
                    }
                    let k = ty * m + j
                    rowA[k] = by * g.s0 + bx * bpp
                    rowC[k] = (by >> 1) * g.s1 + (bx & ~1)
                }
            }
        }
    }

    private static func is709(_ pb: CVPixelBuffer) -> Bool {
        guard let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) else { return true }
        let s = (m as? String) ?? ""
        return !s.contains("601")
    }

    static func fourCC(_ f: OSType) -> String {
        let b = [UInt8((f >> 24) & 255), UInt8((f >> 16) & 255), UInt8((f >> 8) & 255), UInt8(f & 255)]
        if b.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: b, as: UTF8.self) }
        return String(f)
    }

    /// Box-average every s x s block of the tile into one RGB565 pixel.
    private func shrink(_ src: Source, _ t: Tile) {
        let cw = t.cw, ch = t.ch, m = t.m, n = m * m
        let y0 = src.p0, c0 = src.p1
        let nv12 = src.nv12, full = src.full, m709 = src.m709
        // YCbCr -> RGB (full-range values; video range is stretched first)
        let kr: Double = m709 ? 1.5748 : 1.402, kgb: Double = m709 ? 0.1873 : 0.344136
        let kgr: Double = m709 ? 0.4681 : 0.714136, kb: Double = m709 ? 1.8556 : 1.772
        let yScale = full ? 1.0 : 255.0 / 219.0, cScale = full ? 1.0 : 255.0 / 224.0, yOff = full ? 0.0 : 16.0
        let inv = 1.0 / Double(n)
        t.cur.withUnsafeMutableBufferPointer { out in
        t.colA.withUnsafeBufferPointer { cA in
        t.rowA.withUnsafeBufferPointer { rA in
        t.colC.withUnsafeBufferPointer { cC in
        t.rowC.withUnsafeBufferPointer { rC in
            for ty in 0..<ch {
                let rb = ty * m
                for tx in 0..<cw {
                    let cb = tx * m
                    var a0 = 0, a1 = 0, a2 = 0
                    for j in 0..<m {
                        let ra = rA[rb + j], rc = rC[rb + j]
                        for i in 0..<m {
                            if nv12 {
                                a0 += Int(y0[ra + cA[cb + i]])
                                let c = rc + cC[cb + i]
                                a1 += Int(c0[c]); a2 += Int(c0[c + 1])
                            } else {
                                let q = ra + cA[cb + i]
                                a0 += Int(y0[q + 2]); a1 += Int(y0[q + 1]); a2 += Int(y0[q])   // B G R A -> R G B
                            }
                        }
                    }
                    var R: Int, G: Int, B: Int
                    if nv12 {
                        let Y = (Double(a0) * inv - yOff) * yScale
                        let Cb = (Double(a1) * inv - 128.0) * cScale, Cr = (Double(a2) * inv - 128.0) * cScale
                        R = Int((Y + kr * Cr).rounded()); G = Int((Y - kgb * Cb - kgr * Cr).rounded()); B = Int((Y + kb * Cb).rounded())
                        R = min(255, max(0, R)); G = min(255, max(0, G)); B = min(255, max(0, B))
                    } else {
                        R = (a0 + n / 2) / n; G = (a1 + n / 2) / n; B = (a2 + n / 2) / n
                    }
                    let v = ((R >> 3) << 11) | ((G >> 2) << 5) | (B >> 3)
                    let o = (ty * cw + tx) * 2
                    out[o] = UInt8(truncatingIfNeeded: v)
                    out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            }
        }}}}}
    }

    /// raw DEFLATE (RFC 1951 -- the Controller inflates with zlib.inflateRawSync). nil = did not fit / failed -> send it raw.
    private func deflate(_ b: [UInt8]) -> Data? {
        if b.isEmpty { return Data() }
        let cap = b.count + b.count / 16 + 1024
        if zbuf.count < cap { zbuf = [UInt8](repeating: 0, count: cap) }
        let n = b.withUnsafeBufferPointer { sp -> Int in
            zbuf.withUnsafeMutableBufferPointer { dp -> Int in
                guard let s = sp.baseAddress, let d = dp.baseAddress else { return 0 }
                return compression_encode_buffer(d, cap, s, b.count, scratch, COMPRESSION_ZLIB)
            }
        }
        if n <= 0 || n >= b.count { return nil }
        return Data(zbuf[0..<n])
    }
}
