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
        case (UInt8(ascii: "R"), _): galleryDue = true; thumbs = []; viewing = false
        case (UInt8(ascii: "q"), 2): if !thumbs.contains(Int(b[1])) { thumbs.append(Int(b[1])) }
        case (UInt8(ascii: "o"), 2): open(Int(b[1]))
        case (UInt8(ascii: "g"), _): viewing = false; picture = nil; gen += 1
        // a band's chunk was lost on the way: the picture again, whole (twice at most)
        case (UInt8(ascii: "G"), _): if let i = shown, gaps < 2 { gaps += 1; open(i, again: true) }
        default: return
        }
        pump()
    }

    private func open(_ i: Int, again: Bool = false) {
        if !again { gaps = 0 }
        viewing = true
        picture = i
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
        guard let img = await image(i, side: Self.panel), gen == self.gen else { return }
        shown = i
        let scale = 2, n = Self.panel / scale
        let rgb = Pixels.rgb(img, side: n, round: true)
        let off = Int16((Self.panel - n * scale) / 2)
        let msgs = Rle.bandedPicture(rgb: rgb, width: n, height: n, scale: UInt8(scale), x0: off, y0: off)
        do {
            for m in msgs {
                guard gen == self.gen else { return }
                try await Hub.shared.send(Self.app, m)
            }
        } catch { status = error.localizedDescription }
    }
}
