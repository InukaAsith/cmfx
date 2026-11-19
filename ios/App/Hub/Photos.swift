import Foundation
import HubKit
import UIKit

// The watch's Photos app (cmf-watch-sdk sdk/examples/pixview; hosts/pixhost.py): a picture picked here, drawn on
// the round panel at half resolution (233², doubled), 16 colours. The watch asks with `R` when it opens.

@MainActor @Observable final class PhotosService: WatchService {
    static let app = "Photos"
    static let panel = 466
    private(set) var picked: UIImage?
    var status: String?
    private(set) var sending = false

    func receive(_ m: Data) {
        if m == Data("R".utf8), let picked { Task { await send(picked) } }
    }

    func pick(_ img: UIImage) async {
        picked = img
        await send(img)
    }

    private func send(_ img: UIImage) async {
        sending = true
        defer { sending = false }
        let scale = 2, n = Self.panel / scale
        let rgb = Pixels.rgb(img, side: n, round: true)
        let off = Int16((Self.panel - n * scale) / 2)
        do {
            try await Hub.shared.send(Self.app, Rle.picture(rgb: rgb, width: n, height: n, scale: UInt8(scale), x0: off, y0: off))
            status = "Sent to the watch"
        } catch {
            status = error.localizedDescription
        }
    }
}
