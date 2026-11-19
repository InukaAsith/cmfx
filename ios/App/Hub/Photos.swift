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
    /// One job at a time: a file's F/f/c must not interleave with another's.
    private var chain: Task<Void, Never>?

    var allowed: Bool { access == .authorized || access == .limited }

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        load()
    }

    func receive(_ m: Data) {
        let b = [UInt8](m)
        switch (b.first, b.count) {
        case (UInt8(ascii: "R"), _): enqueue { await self.sendGallery() }
        case (UInt8(ascii: "q"), 2): let i = Int(b[1]); enqueue { await self.sendThumb(i) }
        case (UInt8(ascii: "o"), 2): let i = Int(b[1]); enqueue { await self.sendPicture(i) }
        default: break
        }
    }

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { await prev?.value; await job() }
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

    private func sendPicture(_ i: Int) async {
        guard let img = await image(i, side: Self.panel) else { return }
        let scale = 2, n = Self.panel / scale
        let rgb = Pixels.rgb(img, side: n, round: true)
        let off = Int16((Self.panel - n * scale) / 2)
        do {
            try await Hub.shared.send(Self.app, Rle.picture(rgb: rgb, width: n, height: n, scale: UInt8(scale), x0: off, y0: off))
        } catch { status = error.localizedDescription }
    }
}
