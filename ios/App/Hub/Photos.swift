import Foundation
import HubKit
import Photos
import UIKit

// The watch's Photos app (cmf-watch-sdk sdk/examples/photos, proto.rs; hosts/photohost.py is the reference): the
// newest pictures of the photo library as a gallery on the watch. The watch asks for each thumbnail once, only
// when it scrolls into view, and keeps it; a picture opened there is sent at the panel's size. Full library access
// (or the pictures the user allowed with limited access); nothing runs unless Photos is open on the watch.

@MainActor @Observable final class PhotosService: WatchService {
    static let app = "Photos"
    static let panel = 466
    static let thumb = 104
    static let thumbCap = 12 * 1024
    static let max = 64

    private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var count = 0
    var status: String?
    private var assets: [PHAsset] = []
    // What the watch wants, worked through one transfer at a time (a file's F/f/c, a picture's bands, never
    // interleaved): the gallery first, then the picture it stopped on (only the latest: an older one still being
    // sent is cut off), then thumbnails, paused while a picture is open on the watch (`o` … `g`).
    private var galleryDue = false
    private var picture: Int?
    private var shown: Int?
    /// round: the picture fills the panel's circle; else the whole picture, a rounded rectangle (the watch's
    /// double tap)
    private var round = false
    /// the sharp version (256 colours) of what is shown, asked for by a tap
    private var sharpDue = false
    private var sharpSent = false
    private var gen = 0
    private var gaps = 0
    private var viewing = false
    private var thumbs: [Int] = []
    private var working = false

    var allowed: Bool { access == .authorized || access == .limited }

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        load()
    }

    func receive(_ m: Data) {
        let b = [UInt8](m)
        switch (b.first, b.count) {
        case (UInt8(ascii: "R"), _): galleryDue = true; thumbs = []; viewing = false; anyOrder = b.count >= 2 && b[1] >= 1
        case (UInt8(ascii: "q"), 2): if !thumbs.contains(Int(b[1])) { thumbs.append(Int(b[1])) }
        case (UInt8(ascii: "o"), 2): round = true; open(Int(b[1]))
        case (UInt8(ascii: "o"), 3): round = b[2] == 1; open(Int(b[1]))
        case (UInt8(ascii: "h"), _): if shown != nil { sharpDue = true; gen += 1 }
        case (UInt8(ascii: "g"), _): viewing = false; picture = nil; gen += 1
        // a band's chunk was lost on the way: the picture again, whole (twice at most)
        case (UInt8(ascii: "G"), _):
            if let i = shown, gaps < 2 {
                gaps += 1
                if sharpSent { sharpDue = true; gen += 1 } else { open(i, again: true) }
            }
        default: return
        }
        pump()
    }

    private func open(_ i: Int, again: Bool = false) {
        if !again { gaps = 0 }
        viewing = true
        picture = i
        sharpDue = false
        sharpSent = false
        gen += 1
    }

    private func pump() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            while true {
                if galleryDue {
                    galleryDue = false
                    await sendGallery()
                } else if let i = picture {
                    picture = nil
                    await sendPicture(i, gen: gen)
                } else if sharpDue, let i = shown {
                    sharpDue = false
                    await sendSharp(i, gen: gen)
                } else if !viewing, !thumbs.isEmpty {
                    await sendThumb(thumbs.removeFirst())
                } else {
                    return
                }
            }
        }
    }

    private func load() {
        guard allowed else { assets = []; count = 0; return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.fetchLimit = Self.max
        let r = PHAsset.fetchAssets(with: .image, options: o)
        assets = (0..<r.count).map { r.object(at: $0) }
        count = assets.count
    }

    private func name(_ a: PHAsset) -> String {
        if let n = PHAssetResource.assetResources(for: a).first?.originalFilename {
            return (n as NSString).deletingPathExtension
        }
        return a.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Photo"
    }

    private func sendGallery() async {
        load()
        let names = assets.map(name)
        var key = UInt32(2166136261)
        for b in assets.map(\.localIdentifier).joined(separator: "\n").utf8 { key = (key ^ UInt32(b)) &* 16777619 }
        var l = Data([UInt8(ascii: "L"), UInt8(names.count)])
        for k in 0..<4 { l.append(UInt8(key >> (8 * k) & 0xFF)) }
        var msgs = [l]
        for (i, n) in names.enumerated() { msgs.append(Data([UInt8(ascii: "l"), UInt8(i)]) + Data(n.utf8.prefix(40))) }
        do { try await Hub.shared.send(Self.app, msgs) } catch { status = error.localizedDescription }
    }

    private func image(_ i: Int, side: Int) async -> UIImage? {
        guard i < assets.count else { return nil }
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .exact
        o.isNetworkAccessAllowed = true
        o.isSynchronous = false
        return await withCheckedContinuation { k in
            PHImageManager.default().requestImage(for: assets[i], targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: o) { img, _ in k.resume(returning: img) }
        }
    }

    private func sendThumb(_ i: Int) async {
        guard let img = await image(i, side: Self.thumb * 2) else { return }
        var file = Data()
        for (side, scale) in [(Self.thumb, 1), (Self.thumb / 2, 2)] {
            let rgb = Pixels.rgb(img, side: side, corner: CGFloat(14 / scale))
            let (palette, idx) = Quantize.medianCut(rgb: rgb, colours: 16)
            let pal = palette.map { Rle.rgb565($0.0, $0.1, $0.2) }
            file = Rle.header(width: side, height: side, scale: UInt8(scale), palette: pal)
                + Rle.tokens(idx, width: side, height: side)
            if file.count <= Self.thumbCap { break }
        }
        do { try await Hub.shared.send(Self.app, MapPack.fileMessages(name: "th\(i)", data: file)) }
        catch { status = error.localizedDescription }
    }

    /// The picture in 8 bands of their own 16 colours; given up as soon as the watch asks for another one.
    private func sendPicture(_ i: Int, gen: Int) async {
        guard let f = await framed(i), gen == self.gen else { return }
        shown = i
        await out(Rle.bandedPicture(rgb: f.rgb, width: f.w, height: f.h, scale: UInt8(Self.scale), x0: f.x0, y0: f.y0), gen: gen)
    }

    /// The same picture in up to 256 colours (the watch shows a progress ring while it comes). To a watch app that
    /// takes chunks in any order (`R 1`), its header and palette go first, then the chunks over the sliding window,
    /// several in flight.
    private func sendSharp(_ i: Int, gen: Int) async {
        guard let f = await framed(i), gen == self.gen else { return }
        sharpSent = true
        let msgs = Rle.sharpPicture(rgb: f.rgb, width: f.w, height: f.h, scale: UInt8(Self.scale), x0: f.x0, y0: f.y0,
                                    anyOrder: anyOrder)
        guard anyOrder else { return await out(msgs, gen: gen) }
        let head = msgs.prefix { $0.first != UInt8(ascii: "y") }
        await out(Array(head), gen: gen)
        await window(Array(msgs.dropFirst(head.count)), gen: gen)
    }

    /// The watch takes the sharp version's `y` chunks in any order.
    @ObservationIgnored private var anyOrder = false
    @ObservationIgnored private var queue: [Data] = []

    /// Over the sliding window (4 in flight); refused or lost ones go again. Ends when the watch asks for another
    /// picture (`gen`), or after 30 s.
    private func window(_ msgs: [Data], gen g: Int) async {
        queue = msgs
        let start = ContinuousClock.now
        while g == gen, !queue.isEmpty, ContinuousClock.now - start < .seconds(30) {
            do {
                let again = try await Hub.shared.stream(Self.app) { @MainActor [weak self] in
                    guard let self, self.gen == g, !self.queue.isEmpty else { return nil }
                    return self.queue.removeFirst()
                }
                guard g == gen else { return }
                if !again.isEmpty {
                    queue.insert(contentsOf: again, at: 0)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            } catch {
                status = error.localizedDescription
                return
            }
        }
    }

    private func out(_ msgs: [Data], gen: Int) async {
        do {
            for m in msgs {
                guard gen == self.gen else { return }
                try await Hub.shared.send(Self.app, m)
            }
        } catch { status = error.localizedDescription }
    }

    static let scale = 2

    /// Picture i as the watch shows it, in its pixels (scale 2): round, a square filling the panel masked to the
    /// circle; else the whole picture as big as fits inside the circle, corners rounded. → RGB, size, origin.
    private func framed(_ i: Int) async -> (rgb: [UInt8], w: Int, h: Int, x0: Int16, y0: Int16)? {
        guard i < assets.count else { return nil }
        let a = assets[i]
        let (w, h): (Int, Int)
        if round {
            (w, h) = (Self.panel / Self.scale, Self.panel / Self.scale)
        } else {
            let k = Double(Swift.max(a.pixelWidth, 1)) / Double(Swift.max(a.pixelHeight, 1)), r = 226.0
            (w, h) = (Int(2 * r * k / (1 + k * k).squareRoot()) / Self.scale, Int(2 * r / (1 + k * k).squareRoot()) / Self.scale)
        }
        guard let img = await image(i, side: Swift.max(w, h) * 2) else { return nil }
        let rgb = Self.draw(img, width: w, height: h, round: round)
        return (rgb, w, h, Int16((Self.panel - w * Self.scale) / 2), Int16((Self.panel - h * Self.scale) / 2))
    }

    /// `img` filling width × height (centred), black outside the circle (round) or the rounded corners.
    private static func draw(_ img: UIImage, width: Int, height: Int, round: Bool) -> [UInt8] {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        fmt.preferredRange = .standard
        let r = CGRect(x: 0, y: 0, width: width, height: height)
        let pic = UIGraphicsImageRenderer(size: r.size, format: fmt).image { _ in
            UIColor.black.setFill()
            UIRectFill(r)
            (round ? UIBezierPath(ovalIn: r) : UIBezierPath(roundedRect: r, cornerRadius: 12)).addClip()
            let s = img.size
            let k = Swift.max(r.width / Swift.max(s.width, 1), r.height / Swift.max(s.height, 1))
            img.draw(in: CGRect(x: (r.width - s.width * k) / 2, y: (r.height - s.height * k) / 2,
                                width: s.width * k, height: s.height * k))
        }
        guard let cg = pic.cgImage else { return [UInt8](repeating: 0, count: width * height * 3) }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: r)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) {
            rgb[3 * p] = rgba[4 * p]; rgb[3 * p + 1] = rgba[4 * p + 1]; rgb[3 * p + 2] = rgba[4 * p + 2]
        }
        return rgb
    }
}
