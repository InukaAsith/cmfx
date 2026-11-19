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

extension Data {
    mutating func le(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le(_ v: UInt32) { for k in 0..<4 { append(UInt8(v >> (8 * k) & 0xFF)) } }
    mutating func le(_ v: Int16) { le(UInt16(bitPattern: v)) }
    mutating func le(_ v: Int32) { le(UInt32(bitPattern: v)) }
}
