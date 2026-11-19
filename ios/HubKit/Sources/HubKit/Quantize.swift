/// Median cut to a few colours, for album art and photos (the watch takes 16 a picture).
public enum Quantize {
    /// → palette (r, g, b) and an index per pixel.
    public static func medianCut(rgb: [UInt8], colours: Int) -> ([(UInt8, UInt8, UInt8)], [UInt8]) {
        let n = rgb.count / 3
        guard n > 0 else { return ([(0, 0, 0)], []) }
        var boxes: [[Int]] = [Array(0..<n)]
        func range(_ box: [Int], _ ch: Int) -> Int {
            var lo = 255, hi = 0
            for p in box { let v = Int(rgb[3 * p + ch]); lo = min(lo, v); hi = max(hi, v) }
            return hi - lo
        }
        while boxes.count < colours {
            // the box with the widest channel splits at that channel's median
            var best = -1, bestCh = 0, bestRange = 0
            for (i, b) in boxes.enumerated() where b.count > 1 {
                for ch in 0..<3 {
                    let r = range(b, ch)
                    if r > bestRange { (best, bestCh, bestRange) = (i, ch, r) }
                }
            }
            if best < 0 { break }
            let sorted = boxes[best].sorted { rgb[3 * $0 + bestCh] < rgb[3 * $1 + bestCh] }
            let mid = sorted.count / 2
            boxes[best] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
        }
        let palette: [(UInt8, UInt8, UInt8)] = boxes.map { b in
            var s = (0, 0, 0)
            for p in b { s.0 += Int(rgb[3 * p]); s.1 += Int(rgb[3 * p + 1]); s.2 += Int(rgb[3 * p + 2]) }
            let c = max(b.count, 1)
            return (UInt8(s.0 / c), UInt8(s.1 / c), UInt8(s.2 / c))
        }
        return (palette, nearest(rgb: rgb, palette: palette))
    }

    /// Median cut, then `rounds` of k-means (each colour moves to the mean of its pixels): colours that fit the
    /// picture better than the median boxes' averages, at the same 16. Weighted towards green, as the eye is.
    public static func refined(rgb: [UInt8], colours: Int, rounds: Int = 4) -> ([(UInt8, UInt8, UInt8)], [UInt8]) {
        var (palette, idx) = medianCut(rgb: rgb, colours: colours)
        let n = rgb.count / 3
        for _ in 0..<rounds {
            var sum = [(Int, Int, Int, Int)](repeating: (0, 0, 0, 0), count: palette.count)
            for p in 0..<n {
                let k = Int(idx[p])
                sum[k].0 += Int(rgb[3 * p]); sum[k].1 += Int(rgb[3 * p + 1]); sum[k].2 += Int(rgb[3 * p + 2]); sum[k].3 += 1
            }
            for k in palette.indices where sum[k].3 > 0 {
                let c = sum[k].3
                palette[k] = (UInt8(sum[k].0 / c), UInt8(sum[k].1 / c), UInt8(sum[k].2 / c))
            }
            idx = nearest(rgb: rgb, palette: palette, weighted: true)
        }
        return (palette, idx)
    }

    /// Each pixel's nearest palette entry (squared RGB distance).
    public static func nearest(rgb: [UInt8], palette: [(UInt8, UInt8, UInt8)], weighted: Bool = false) -> [UInt8] {
        let (wr, wg, wb) = weighted ? (3, 6, 1) : (1, 1, 1)
        let n = rgb.count / 3
        var out = [UInt8](repeating: 0, count: n)
        var memo: [UInt32: UInt8] = [:]
        for p in 0..<n {
            let (r, g, b) = (Int(rgb[3 * p]), Int(rgb[3 * p + 1]), Int(rgb[3 * p + 2]))
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            if let hit = memo[key] { out[p] = hit; continue }
            var best = 0, bestD = Int.max
            for (i, c) in palette.enumerated() {
                let d = wr * (r - Int(c.0)) * (r - Int(c.0)) + wg * (g - Int(c.1)) * (g - Int(c.1)) + wb * (b - Int(c.2)) * (b - Int(c.2))
                if d < bestD { (best, bestD) = (i, d) }
            }
            memo[key] = UInt8(best)
            out[p] = UInt8(best)
        }
        return out
    }
}
