// Stem Eye -- the PROGRAM: which crops of djay's screen to send, how shrunk, how often. The Controller serves it (GET /sr/program)
// so the reading can change without a new app build; the built-in copy is used until it answers (and when it can't).
import Foundation

struct TileSpec: Codable, Equatable {
    let id: String
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let s: Int
    let every: Int
    /// send it whole every time (no XOR delta): tiles that change every frame anyway (the scrolling lanes) or are sent rarely
    let key: Bool?
}

struct Program: Codable {
    let v: String
    let W: Int
    let H: Int
    let tiles: [TileSpec]
    let fps: Double?
    let keyEvery: Double?

    /// The 17c program: used until the Controller answers GET /sr/program (and when it can't).
    static let builtIn = Program(v: "17c", W: 2732, H: 2048, tiles: [
        TileSpec(id: "LN", x: 722, y: 266, w: 1290, h: 436, s: 2, every: 1, key: true),
        TileSpec(id: "MX", x: 1036, y: 860, w: 660, h: 920, s: 2, every: 1, key: nil),
        TileSpec(id: "LOW", x: 0, y: 860, w: 2732, h: 1188, s: 4, every: 2, key: nil),
        TileSpec(id: "TOP", x: 0, y: 30, w: 2732, h: 240, s: 2, every: 5, key: nil),
        TileSpec(id: "TR", x: 0, y: 700, w: 2732, h: 160, s: 4, every: 3, key: nil),
        TileSpec(id: "FS", x: 0, y: 0, w: 2732, h: 2048, s: 16, every: 24, key: true),
    ], fps: 12, keyEvery: 2)

    /// sane enough to use (a broken answer from the Controller must not break the broadcast)
    var usable: Bool {
        if W < 64 || H < 64 || tiles.isEmpty || tiles.count > 16 { return false }
        for t in tiles {
            if t.id.isEmpty || t.w < 1 || t.h < 1 || t.s < 1 || t.s > 64 || t.every < 1 || t.every > 600 { return false }
            if t.x < 0 || t.y < 0 || t.x + t.w > W + 64 || t.y + t.h > H + 64 { return false }
        }
        return true
    }
}
