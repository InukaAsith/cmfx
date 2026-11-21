import AVFoundation
import MediaPlayer
import UIKit

/// The iPhone's system volume, as the hardware buttons set it. iOS has no API to set it: the slider of an
/// MPVolumeView (kept in the key window, invisible) is the way apps do. Reading is AVAudioSession's outputVolume.
@MainActor enum SystemVolume {
    private static var view: MPVolumeView?

    static var percent: Int { Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded()) }

    static func set(_ percent: Int) {
        guard let slider = slider() else { return }
        slider.value = Float(max(0, min(100, percent))) / 100
        slider.sendActions(for: .valueChanged)
    }

    private static func slider() -> UISlider? {
        if view?.window == nil {
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
            guard let window else { return nil }
            let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            v.alpha = 0.01  // hidden views don't take the value; off screen and nearly clear also hides the HUD
            window.addSubview(v)
            view = v
        }
        return view?.subviews.compactMap { $0 as? UISlider }.first
    }
}
