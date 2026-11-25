import Foundation

/// pixview's picture format (cmf-watch-sdk sdk/examples/pixview/src/rle.rs): 16 colours, one byte per run
/// `cccc nnnn` (run n + 1; n == 15 takes one more byte e: run 16 + e), runs never cross a row.
public enum Rle {
    public static let msgMax = 128

    public static func rgb565(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt16 {
        UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
    }

    /// Palette indices (0..15), row by row → run tokens.
    public static func tokens(_ px: [UInt8], width w: Int, height h: Int) -> Data {
        var out = Data()
        out.reserveCapacity(w * h / 4)
        for y in 0..<h {
            var x = 0
            let row = y * w
            while x < w {
                let c = px[row + x]
                var n = 1
                while x + n < w, px[row + x + n] == c, n < 271 { n += 1 }
                if n <= 15 {
                    out.append(c << 4 | UInt8(n - 1))
                } else {
                    out.append(c << 4 | 15)
                    out.append(UInt8(n - 16))
                }
                x += n
            }
        }
        return out
    }

    /// The `I` message: w:u16 h:u16 scale:u8 x0:i16 y0:i16 palette:16×u16, little endian.
    public static func header(width: Int, height: Int, scale: UInt8 = 1, x0: Int16 = 0, y0: Int16 = 0,
                              palette: [UInt16]) -> Data {
        var d = Data([UInt8(ascii: "I")])
        d.le(UInt16(width)); d.le(UInt16(height)); d.append(scale)
        d.le(UInt16(bitPattern: x0)); d.le(UInt16(bitPattern: y0))
        for i in 0..<16 { d.le(i < palette.count ? palette[i] : 0) }
        return d
    }

    /// `I`, `D seq tokens…` (126 bytes each), `E`.
    public static func messages(header: Data, tokens: Data) -> [Data] {
        var out = [header]
        var seq: UInt8 = 0
        var i = tokens.startIndex
        while i < tokens.endIndex {
            let j = min(i + msgMax - 2, tokens.endIndex)
            out.append(Data([UInt8(ascii: "D"), seq]) + tokens[i..<j])
            seq &+= 1
            i = j
        }
        out.append(Data([UInt8(ascii: "E")]))
        return out
    }

    /// RGB (3 bytes a pixel) → the messages of one picture, 16 colours by median cut.
    public static func picture(rgb: [UInt8], width: Int, height: Int, scale: UInt8 = 1, x0: Int16 = 0,
                               y0: Int16 = 0) -> [Data] {
        let (palette, idx) = Quantize.medianCut(rgb: rgb, colours: 16)
        let pal = palette.map { rgb565($0.0, $0.1, $0.2) }
        return messages(header: header(width: width, height: height, scale: scale, x0: x0, y0: y0, palette: pal),
                        tokens: tokens(idx, width: width, height: height))
    }
}

extension Rle {
    /// An opened photo in `bands` horizontal bands, each with its own 16 colours (Quantize.refined): `P n`, then
    /// per band `I` (its row as y0) / `D`… / `E` (cmf-watch-sdk photos proto.rs). Many more colours on the watch
    /// than one palette for the whole picture, for about a third more bytes.
    public static func bandedPicture(rgb: [UInt8], width: Int, height: Int, scale: UInt8 = 1, x0: Int16 = 0,
                                     y0: Int16 = 0, bands: Int = 8) -> [Data] {
        var out = [Data([UInt8(ascii: "P"), UInt8(bands)])]
        for k in 0..<bands {
            let r0 = height * k / bands, r1 = height * (k + 1) / bands
            let part = Array(rgb[(3 * width * r0)..<(3 * width * r1)])
            let (palette, idx) = Quantize.refined(rgb: part, colours: 16)
            let pal = palette.map { rgb565($0.0, $0.1, $0.2) }
            let hdr = header(width: width, height: r1 - r0, scale: scale, x0: x0,
                             y0: y0 + Int16(r0) * Int16(scale), palette: pal)
            out += messages(header: hdr, tokens: tokens(idx, width: width, height: r1 - r0))
        }
        return out
    }
}

extension Rle {
    /// A whole page for the watch to keep and scroll (cmf-watch-sdk browser long.rs): `J h:u16` (panel px), then bands
    /// of `band` rows top down, each with its own 16 colours (`I` with its page place as y0 / `D`… / `E`), as many as
    /// fit `cap` bytes on the watch, then `j`. → the messages and the height that went, panel px.
    public static func longPicture(rgb: [UInt8], width: Int, height: Int, scale: UInt8 = 2, band: Int = 32,
                                   cap: Int = 49 * 1024, colours: Int = 16) -> (messages: [Data], height: Int) {
        var parts: [Data] = []
        var used = 0, rows = 0
        while rows < height, rows / band < 96 {
            let r1 = min(rows + band, height)
            let part = Array(rgb[(3 * width * rows)..<(3 * width * r1)])
            let (palette, idx) = Quantize.refined(rgb: part, colours: colours)
            let pal = (palette + Array(repeating: (0, 0, 0), count: max(0, 16 - palette.count))).prefix(16).map { rgb565($0.0, $0.1, $0.2) }
            let t = tokens(idx, width: width, height: r1 - rows)
            let hdr = header(width: width, height: r1 - rows, scale: scale, x0: 0, y0: Int16(clamping: rows * Int(scale)),
                             palette: pal)
            guard used + hdr.count + t.count <= cap else { break }
            used += hdr.count + t.count
            parts += messages(header: hdr, tokens: t)
            rows = r1
        }
        let h = rows * Int(scale)
        var j = Data([UInt8(ascii: "J")])
        j.le(UInt16(clamping: h))
        return ([j] + parts + [Data([UInt8(ascii: "j")])], h)
    }
}

extension Rle {
    /// 256-colour runs: a byte < 255 is one pixel of that colour; 255, c, n is n (3…255) pixels of colour c; no run
    /// crosses a row (cmf-watch-sdk photos proto.rs, the sharp version).
    public static func tokens8(_ idx: [UInt8], width: Int, height: Int) -> Data {
        var out = Data()
        for y in 0..<height {
            var x = 0
            while x < width {
                let c = idx[y * width + x]
                var k = 1
                while x + k < width, idx[y * width + x + k] == c, k < 255 { k += 1 }
                if k >= 3 { out.append(contentsOf: [255, c, UInt8(k)]) } else { out.append(contentsOf: [UInt8](repeating: c, count: k)) }
                x += k
            }
        }
        return out
    }

    /// The sharp version of an opened photo: up to 255 colours, fewer when it would not fit the watch's `cap`;
    /// `S total:u16 w:u16 h:u16 scale x0:i16 y0:i16`, `K first count rgb565…`, `Y seq tokens…`, `Z`; `anyOrder`
    /// (a watch that said `R 1`): `y seq:u16 tokens…` chunks of 124 at seq × 124 and no `Z`.
    public static func sharpPicture(rgb: [UInt8], width: Int, height: Int, scale: UInt8, x0: Int16, y0: Int16,
                                    cap: Int = 40 * 1024, anyOrder: Bool = false) -> [Data] {
        var palette: [(UInt8, UInt8, UInt8)] = [], data = Data()
        for colours in [255, 192, 128, 96, 64] {
            let (p, idx) = Quantize.medianCut(rgb: rgb, colours: colours)
            palette = p
            data = tokens8(idx, width: width, height: height)
            if data.count <= cap { break }
        }
        var s = Data([UInt8(ascii: "S")])
        s.le(UInt16(data.count)); s.le(UInt16(width)); s.le(UInt16(height)); s.append(scale); s.le(x0); s.le(y0)
        var out = [s]
        var first = 0
        while first < palette.count {
            let n = min(60, palette.count - first)
            var k = Data([UInt8(ascii: "K"), UInt8(first), UInt8(n)])
            for c in palette[first..<(first + n)] { k.le(rgb565(c.0, c.1, c.2)) }
            out.append(k)
            first += n
        }
        if anyOrder {
            // `y seq:u16` at seq × 124: they may land in any order (the sliding window), the watch ends it itself
            var seq: UInt16 = 0
            var i = data.startIndex
            while i < data.endIndex {
                let j = min(i + 124, data.endIndex)
                var y = Data([UInt8(ascii: "y")])
                y.le(seq)
                out.append(y + data[i..<j])
                seq += 1
                i = j
            }
            return out
        }
        var seq: UInt8 = 0
        var i = data.startIndex
        while i < data.endIndex {
            let j = min(i + msgMax - 2, data.endIndex)
            out.append(Data([UInt8(ascii: "Y"), seq]) + data[i..<j])
            seq &+= 1
            i = j
        }
        out.append(Data([UInt8(ascii: "Z")]))
        return out
    }
}

extension Data {
    mutating func le(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le(_ v: UInt32) { for k in 0..<4 { append(UInt8(v >> (8 * k) & 0xFF)) } }
    mutating func le(_ v: Int16) { le(UInt16(bitPattern: v)) }
    mutating func le(_ v: Int32) { le(UInt32(bitPattern: v)) }
}
