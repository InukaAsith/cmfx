import Foundation

/// A video to the watch's player in few bytes a frame (about 500, so about 14 frames a second on the watch's 7 KB/s
/// link): a small picture (`scale` panel px a pixel, centred), few colours, and after the first frame only the
/// rectangle that changed, drawn over what the watch shows (each picture carries its place: pixview rle.rs `I`). A
/// whole frame now and then puts right what the small ones missed. The watch app is unchanged: plain `I`/`D`/`E`.
public final class VideoCoder {
    public let scale: Int
    public let width: Int, height: Int
    /// what the watch shows, as RGB at the grid's size (what was sent, in its colours)
    var shown: [UInt8]
    var frames = 0
    public var colours = 8
    /// bytes a frame aimed at: a change bigger than this goes in fewer colours
    public var budget = 650
    /// a whole frame every this many
    public var keyEvery = 600

    /// `width` × `height` grid (the video's shape), `scale` panel px a pixel (4: 116 wide, 5: 93 wide).
    public init(width: Int, height: Int, scale: Int) {
        (self.width, self.height, self.scale) = (width, height, scale)
        shown = [UInt8](repeating: 0, count: width * height * 3)
    }

    /// The grid for a video of `vw` × `vh` at `scale` (its whole width on the panel, at most the panel's height).
    public static func grid(videoWidth vw: Int, videoHeight vh: Int, scale: Int) -> (Int, Int) {
        let side = 465 / scale
        guard vw > 0, vh > 0 else { return (side, side * 9 / 16) }
        if vw >= vh { return (side, max(2, min(side, side * vh / vw))) }
        return (max(2, side * vw / vh), side)
    }

    /// Where the grid sits on the panel (centred).
    var origin: (Int, Int) { ((466 - width * scale) / 2, (466 - height * scale) / 2) }

    /// The messages for frame `rgb` (`width` × `height` RGB): none when nothing changed. A whole frame each time
    /// (one picture, so it stays whole on the watch): the pixels that changed in 15 colours of their own, the rest
    /// colour 15 with the header's KEEP bit (pixview rle.rs: not drawn, the last frame shows there). Over `budget`
    /// bytes, only bigger changes count (so a busy scene is coarser, never cut in bands); the rest comes later.
    public func encode(_ rgb: [UInt8]) -> [Data] {
        guard rgb.count == width * height * 3 else { return [] }
        frames += 1
        let n = width * height
        if frames == 1 || frames % keyEvery == 0 {
            return put(rgb, x0: 0, y0: 0, x1: width, y1: height).0
        }
        var diff = [Int](repeating: 0, count: n)
        for p in 0..<n {
            let i = 3 * p
            diff[p] = abs(Int(rgb[i]) - Int(shown[i])) + abs(Int(rgb[i + 1]) - Int(shown[i + 1]))
                + abs(Int(rgb[i + 2]) - Int(shown[i + 2]))
        }
        var t = threshold
        for round in 0..<5 {
            let changed = (0..<n).filter { diff[$0] > t }
            if changed.isEmpty { return [] }
            var sub = [UInt8](); sub.reserveCapacity(changed.count * 3)
            for p in changed { sub += rgb[(3 * p)..<(3 * p + 3)] }
            let (palette, subIdx) = Quantize.refined(rgb: sub, colours: 15, rounds: 2)
            let pal = palette.isEmpty ? [(UInt8(0), UInt8(0), UInt8(0))] : palette
            var idx = [UInt8](repeating: 15, count: n)
            for (k, p) in changed.enumerated() { idx[p] = subIdx[k] }
            let p565 = (pal.prefix(15).map { Rle.rgb565($0.0, $0.1, $0.2) } + Array(repeating: 0, count: 16)).prefix(16)
            let (ox, oy) = origin
            let hdr = Rle.header(width: width, height: height, scale: UInt8(scale) | 0x80, x0: Int16(ox), y0: Int16(oy),
                                 palette: Array(p565))
            let msgs = Rle.messages(header: hdr, tokens: Rle.tokens(idx, width: width, height: height))
            if msgs.reduce(0, { $0 + $1.count }) > budget && round < 4 {
                t = t * 8 / 5
                continue
            }
            for (k, p) in changed.enumerated() {
                let c = pal[Int(subIdx[k])]
                (shown[3 * p], shown[3 * p + 1], shown[3 * p + 2]) = c
            }
            return msgs
        }
        return []
    }

    /// a pixel's difference (three channels summed) above this: changed
    public var threshold = 36

    /// The rectangle as a picture (all 16 colours, drawn whole), and what the watch shows there now; its bytes.
    func put(_ rgb: [UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> ([Data], Int) {
        let (w, h) = (x1 - x0, y1 - y0)
        var part = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let s = 3 * ((y0 + y) * width + x0)
            part.replaceSubrange((3 * y * w)..<(3 * (y + 1) * w), with: rgb[s..<(s + 3 * w)])
        }
        let (msgs, pal, idx) = picture(part, w: w, h: h, x: x0, y: y0, colours: 16)
        for y in 0..<h {
            for x in 0..<w {
                let c = pal[Int(idx[y * w + x])], i = 3 * ((y0 + y) * width + x0 + x)
                (shown[i], shown[i + 1], shown[i + 2]) = c
            }
        }
        return (msgs, msgs.reduce(0) { $0 + $1.count })
    }

    func picture(_ part: [UInt8], w: Int, h: Int, x: Int, y: Int, colours: Int)
        -> ([Data], [(UInt8, UInt8, UInt8)], [UInt8]) {
        let (palette, idx) = Quantize.refined(rgb: part, colours: colours, rounds: 2)
        let pal = palette.isEmpty ? [(0, 0, 0)] : palette
        let p565 = (pal.map { Rle.rgb565($0.0, $0.1, $0.2) } + Array(repeating: 0, count: 16)).prefix(16)
        let (ox, oy) = origin
        let hdr = Rle.header(width: w, height: h, scale: UInt8(scale), x0: Int16(ox + x * scale),
                             y0: Int16(oy + y * scale), palette: Array(p565))
        return (Rle.messages(header: hdr, tokens: Rle.tokens(idx, width: w, height: h)), pal, idx)
    }

    /// A video frame (the page's video, drawn into a canvas `width` px wide) as JPEG data: JS for the page.
    public static func grabScript(width: Int, height: Int) -> String {
        """
        (() => { const v = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState > 2);
          if (!v || !v.videoWidth) return null;
          const c = window.__wv || (window.__wv = document.createElement('canvas'));
          c.width = \(width); c.height = \(height);
          try { c.getContext('2d').drawImage(v, 0, 0, c.width, c.height); return c.toDataURL('image/jpeg', 0.8); }
          catch (e) { return null; } })()
        """
    }

    /// The page's video's shape: JS, "w,h" (nothing playing: "").
    public static let sizeScript = """
    (() => { const v = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState > 2);
      return v && v.videoWidth ? v.videoWidth + ',' + v.videoHeight : ''; })()
    """
}
