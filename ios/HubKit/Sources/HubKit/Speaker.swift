import Foundation

// The phone side of the watch's speaker stream (cmf-watch-sdk: src/wp2apps/adpcm.py, tune.py, play.py are the
// reference, tested byte-for-byte in Checks): IMA ADPCM blocks of 10.67 kHz mono, which the watch app upsamples
// 2 → 3 to 16 kHz, and the speaker tuning measured on a real watch (2026-11-21, see tune.py for the recordings).

/// IMA ADPCM (IMA/DVI, 4 bits a sample). Blocks carry their own start state (predictor i16 LE, index u8), then
/// codes, low nibble first; the state runs on across blocks, so they join without a click.
public struct ADPCMEncoder: Sendable {
    static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    static let indexStep = [-1, -1, -1, -1, 2, 4, 6, 8]

    var predictor = 0
    var index = 0
    /// > 0: a trellis search over each block (wp2apps adpcm.Encoder(paths), byte for byte): every kept path tries
    /// the standard code and its magnitude ±1 (and the other sign when the standard one is 0); paths reaching the
    /// same (predictor, index) keep the lower squared error; the `paths` best go on. ~1 dB less noise, same decoder.
    let paths: Int

    public init(paths: Int = 0) { self.paths = paths }

    static func step(_ predictor: Int, _ index: Int, _ code: Int) -> (Int, Int) {
        let step = steps[index]
        var diff = step >> 3
        if code & 4 != 0 { diff += step }
        if code & 2 != 0 { diff += step >> 1 }
        if code & 1 != 0 { diff += step >> 2 }
        let p = predictor + (code & 8 != 0 ? -diff : diff)
        return (max(-32768, min(32767, p)), max(0, min(88, index + indexStep[code & 7])))
    }

    mutating func code(_ sample: Int) -> Int {
        let step = Self.steps[index]
        var diff = sample - predictor
        var code = diff < 0 ? 8 : 0
        diff = abs(diff)
        if diff >= step { code |= 4; diff -= step }
        if diff >= step >> 1 { code |= 2; diff -= step >> 1 }
        if diff >= step >> 2 { code |= 1 }
        (predictor, index) = Self.step(predictor, index, code)
        return code
    }

    /// An even number of samples → one block.
    public mutating func block(_ samples: ArraySlice<Int16>) -> Data {
        precondition(samples.count % 2 == 0, "a block holds an even number of samples")
        var out = Data()
        out.reserveCapacity(3 + samples.count / 2)
        let p = UInt16(bitPattern: Int16(predictor))
        out.append(UInt8(p & 0xFF)); out.append(UInt8(p >> 8)); out.append(UInt8(index))
        if paths > 0 {
            let codes = trellis(samples)
            for k in stride(from: 0, to: codes.count, by: 2) { out.append(codes[k] | codes[k + 1] << 4) }
            return out
        }
        var i = samples.startIndex
        while i < samples.endIndex {
            let lo = code(Int(samples[i])), hi = code(Int(samples[i + 1]))
            out.append(UInt8(lo | hi << 4))
            i += 2
        }
        return out
    }

    private struct Path { var e: Int; var p: Int; var i: Int; var node: Int }

    /// The block's codes by the trellis; the state moves to the best path's end. The order of the candidates and of
    /// equal errors (the order the states were first reached in) is Python's, so the bytes are the same.
    private mutating func trellis(_ samples: ArraySlice<Int16>) -> [UInt8] {
        var codes: [UInt8] = [], parent: [Int] = []  // the paths' codes, as linked lists into these
        codes.reserveCapacity(samples.count * paths * 2); parent.reserveCapacity(samples.count * paths * 2)
        var kept = [Path(e: 0, p: predictor, i: index, node: -1)]
        var next: [Path] = []
        next.reserveCapacity(paths * 4)
        for s in samples {
            let x = Int(s)
            next.removeAll(keepingCapacity: true)
            for path in kept {
                let step = Self.steps[path.i]
                var d = x - path.p
                let sign = d < 0 ? 8 : 0
                d = abs(d)
                var m = 0
                if d >= step { m |= 4; d -= step }
                if d >= step >> 1 { m |= 2; d -= step >> 1 }
                if d >= step >> 2 { m |= 1 }
                var cands: [Int] = []
                for k in [m - 1, m, m + 1] where k >= 0 && k <= 7 { cands.append(sign | k) }
                if m == 0 { cands.append(8 - sign) }
                for c in cands {
                    let (p1, i1) = Self.step(path.p, path.i, c)
                    let e1 = path.e + (x - p1) * (x - p1)
                    if let k = next.firstIndex(where: { $0.p == p1 && $0.i == i1 }) {
                        if e1 < next[k].e {
                            codes.append(UInt8(c)); parent.append(path.node)
                            next[k] = Path(e: e1, p: p1, i: i1, node: codes.count - 1)
                        }
                    } else {
                        codes.append(UInt8(c)); parent.append(path.node)
                        next.append(Path(e: e1, p: p1, i: i1, node: codes.count - 1))
                    }
                }
            }
            // stable by error (Python's sorted)
            kept = next.enumerated().sorted { ($0.element.e, $0.offset) < ($1.element.e, $1.offset) }
                .prefix(paths).map(\.element)
        }
        let best = kept[0]
        predictor = best.p
        index = best.i
        var out = [UInt8](repeating: 0, count: samples.count)
        var node = best.node, k = samples.count - 1
        while node >= 0 { out[k] = codes[node]; node = parent[node]; k -= 1 }
        return out
    }
}

/// The speaker tuning (tune.py `for_speaker`), on a whole song at once (the make-up gain looks at all of it).
public enum SpeakerTune {
    static func biquad(_ x: [Double], _ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double,
                       _ a2: Double) -> [Double] {
        let (b0, b1, b2, a1, a2) = (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        var y = [Double](repeating: 0, count: x.count)
        var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
        for (i, v) in x.enumerated() {
            let o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, v, y1, o)
            y[i] = o
        }
        return y
    }

    static func highpass(_ x: [Double], _ rate: Double, _ hz: Double, q: Double = 0.7071) -> [Double] {
        let w = 2 * Double.pi * hz / rate, c = cos(w), a = sin(w) / (2 * q)
        return biquad(x, (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a)
    }

    static func lowpass(_ x: [Double], _ rate: Double, _ hz: Double, q: Double = 0.7071) -> [Double] {
        let w = 2 * Double.pi * hz / rate, c = cos(w), a = sin(w) / (2 * q)
        return biquad(x, (1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a)
    }

    static func peak(_ x: [Double], _ rate: Double, _ hz: Double, _ db: Double, q: Double) -> [Double] {
        let A = pow(10, db / 40), w = 2 * Double.pi * hz / rate, c = cos(w), a = sin(w) / (2 * q)
        return biquad(x, 1 + a * A, -2 * c, 1 - a * A, 1 + a / A, -2 * c, 1 - a / A)
    }

    static func highShelf(_ x: [Double], _ rate: Double, _ hz: Double, _ db: Double, s: Double = 0.9) -> [Double] {
        let A = pow(10, db / 40), w = 2 * Double.pi * hz / rate, c = cos(w), sn = sin(w)
        let al = sn / 2 * ((A + 1 / A) * (1 / s - 1) + 2).squareRoot()
        let r = 2 * A.squareRoot() * al
        return biquad(x, A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r),
                      (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r)
    }

    /// The bass the driver can't play, as harmonics it can (380-900 Hz, out of its 200-450 Hz buzz).
    static func virtualBass(_ x: [Double], _ rate: Double, below: Double, amount: Double) -> [Double] {
        let b = lowpass(lowpass(x, rate, below), rate, below)
        var peak = b.reduce(0) { max($0, abs($1)) }
        if peak == 0 { peak = 1 }
        var h = b.map { $0 * abs($0) / peak + 0.6 * abs($0) }
        h = highpass(highpass(h, rate, 380), rate, 380)
        h = lowpass(lowpass(h, rate, 900), rate, 900)
        return h.map { amount * $0 }
    }

    /// Dynamic EQ on 900-1800 Hz: the driver's resonance rings when that band runs hot.
    static func tame(_ x: [Double], _ rate: Double) -> [Double] {
        let (lo, hi, overDb, ratio, attackMs, releaseMs) = (900.0, 1800.0, -18.0, 4.0, 5.0, 150.0)
        var band = lowpass(highpass(highpass(x, rate, lo), rate, lo), rate, hi)
        band = lowpass(band, rate, hi)
        let at = exp(-1 / (rate * attackMs / 1000)), rl = exp(-1 / (rate * releaseMs / 1000))
        var eb = 1.0, ea = 1.0
        let k = pow(10, overDb / 20)
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let v = x[i], b = band[i]
            var s = abs(b), c = s > eb ? at : rl
            eb = c * eb + (1 - c) * s
            s = abs(v); c = s > ea ? at : rl
            ea = c * ea + (1 - c) * s
            let lim = k * ea
            let g = eb > lim && lim > 0 ? (lim * pow(eb / lim, 1 / ratio)) / eb : 1.0
            out[i] = v - (1 - g) * b
        }
        return out
    }

    /// `ratio` 1: no gain riding (volume smoothing off), only the make-up to the ceiling and its limiter.
    static func compress(_ x: [Double], _ rate: Double, ceiling: Double, ratio: Double = 2.5) -> [Double] {
        let (thresholdDb, attackMs, releaseMs) = (-24.0, 10.0, 200.0)
        let at = exp(-1 / (rate * attackMs / 1000)), rl = exp(-1 / (rate * releaseMs / 1000))
        let thr = pow(10, thresholdDb / 20) * 32768
        var env = 0.0
        var out = [Double](repeating: 0, count: x.count)
        for (i, v) in x.enumerated() {
            let a = abs(v)
            env = a > env ? at * env + (1 - at) * a : rl * env + (1 - rl) * a
            let g = env > thr ? (thr * pow(env / thr, 1 / ratio)) / env : 1.0
            out[i] = v * g
        }
        var top = out.reduce(0) { max($0, abs($1)) }
        if top == 0 { top = 1 }
        // make-up: the 99.9th percentile peak to the ceiling, the rest is limited
        let stride = max(1, out.count / 20000)
        let srt = Swift.stride(from: 0, to: out.count, by: stride).map { abs(out[$0]) }.sorted()
        let p = srt.isEmpty ? top : srt[Int(Double(srt.count) * 0.999)]
        let k = ceiling * 32767 / max(p, 1.0), lim = ceiling * 32767
        return out.map { max(-lim, min(lim, $0 * k)) }
    }

    /// tune.py TUNING, the one the owner approved by ear (recording 23).
    /// Loudness levelling (wp2apps tune.level): the gain to -14 dBFS gated RMS (0.4 s windows; under -50 dBFS
    /// and 10 dB under the mean left out), within -6..+12 dB. Quiet songs come up, very loud ones down.
    public static func level(_ samples: [Int16], rate: Int) -> Double {
        let n = Int(Double(rate) * 0.4)
        var powers: [Double] = []
        var k = 0
        while k + n <= samples.count {
            var acc = 0.0
            for v in samples[k..<k + n] { acc += Double(v) * Double(v) }
            powers.append(acc / Double(n))
            k += n
        }
        let floor = pow(32767.0 * pow(10, -50.0 / 20), 2)
        powers = powers.filter { $0 > floor }
        guard !powers.isEmpty else { return 1 }
        let mean = powers.reduce(0, +) / Double(powers.count)
        let kept = powers.filter { $0 >= mean / 10 }
        let rmsDb = 10 * log10(kept.reduce(0, +) / Double(kept.count) / (32767.0 * 32767.0))
        return pow(10, max(-6, min(12, -14 - rmsDb)) / 20)
    }

    /// `level`: loudness levelling (off unless asked: the "enhance" option); `smooth`: volume smoothing (the
    /// compressor; on, as tuned).
    public static func forSpeaker(_ samples: [Int16], rate: Int, level levelling: Bool = false, smooth: Bool = true) -> [Int16] {
        let r = Double(rate)
        let (cut, vbass, bodyHz, bodyDb, resoHz, resoDb, resoQ, topDb, topHz) =
            (160.0, 0.9, 420.0, 6.0, 900.0, -5.0, 0.8, -4.0, 2800.0)
        let (split, lowCeiling, ceiling) = (500.0, 0.125, 0.5)
        let g = levelling ? level(samples, rate: rate) : 1
        var x = samples.map { Double($0) * g }
        let vb = virtualBass(x, r, below: cut, amount: vbass)
        x = highpass(x, r, cut)
        for i in 0..<x.count { x[i] += vb[i] }
        x = peak(x, r, bodyHz, bodyDb, q: 0.9)
        x = peak(x, r, resoHz, resoDb, q: resoQ)
        x = highShelf(x, r, topHz, topDb)
        x = tame(x, r)
        x = compress(x, r, ceiling: ceiling, ratio: smooth ? 2.5 : 1)
        // the band under 500 Hz has its own, lower, soft limit (the driver runs out of travel there first)
        let lo = lowpass(lowpass(x, r, split), r, split)
        var lim = lowCeiling * 32767
        for i in 0..<x.count { x[i] = x[i] - lo[i] + lim * tanh(lo[i] / lim) }
        lim = ceiling * 32767
        return x.map { Int16(Int(max(-lim, min(lim, $0)))) }
    }
}

/// Phone → watch messages of the Music app's audio (play.py): `o khz mode`, `t title`, `x shimmer`, `v percent`,
/// `a seq:u16 block`, `c`. Watch → phone `F next:u16 room:u8` is credit: send no block past next + room.
public enum SpeakerProto {
    public static let rate = 10667  // 2/3 of 16 kHz: what the BLE link carries (0.78x of a 16 kHz stream)
    public static let outKhz: UInt8 = 16
    public static let samplesPerBlock = 244  // 122 code bytes: `a` seq predictor index codes = 128 B
    public static let shimmer: UInt8 = 40
    /// the trellis encoder's paths when enhanced (wp2apps play.PATHS)
    public static let paths = 4

    public static func open() -> Data { Data([UInt8(ascii: "o"), outKhz, 1]) }
    public static func title(_ s: String) -> Data { Data("t".utf8) + Data(s.utf8.prefix(40)) }
    public static func excite(_ amount: UInt8 = shimmer) -> Data { Data([UInt8(ascii: "x"), amount]) }
    public static func stop() -> Data { Data("c".utf8) }

    /// The `a` messages of a whole (tuned) song, one encoder across them; `pad`: 0.4 s of silence at the end so
    /// the last music passes the watch's prebuffer (the Speaker app; YouTube Music's `z` does that).
    /// `paths` > 0: the trellis encoder (the "enhance" option).
    public static func blocks(_ samples: [Int16], pad: Bool = true, paths: Int = 0) -> [Data] {
        var s = samples + [Int16](repeating: 0, count: pad ? rate * 2 / 5 : 0)
        let n = samplesPerBlock
        if s.count % n != 0 { s += [Int16](repeating: 0, count: n - s.count % n) }
        var enc = ADPCMEncoder(paths: paths)
        var out: [Data] = []
        out.reserveCapacity(s.count / n)
        for (seq, i) in stride(from: 0, to: s.count, by: n).enumerated() {
            var m = Data([UInt8(ascii: "a"), UInt8(seq & 0xFF), UInt8(seq >> 8 & 0xFF)])
            m += enc.block(s[i..<i + n])
            out.append(m)
        }
        return out
    }

    /// `F next room` → (next, room).
    public static func credit(_ m: Data) -> (next: Int, room: Int)? {
        guard m.count == 4, m.first == UInt8(ascii: "F") else { return nil }
        let b = [UInt8](m)
        return (Int(b[1]) | Int(b[2]) << 8, Int(b[3]))
    }
}
