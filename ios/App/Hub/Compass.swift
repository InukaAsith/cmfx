import CoreLocation
import Foundation
import HubKit
import UIKit

// The watch's Compass app (cmf-watch-sdk sdk/examples/compass): the watch has no magnetometer, so it shows the
// iPhone's heading. The heading runs only while Compass is open on the watch: from its `R` till its `Z`, another app
// talking, or its `R`s stopping (it sends one every 4 s while open; it can be closed without a `Z`).

@MainActor @Observable final class CompassService: NSObject, WatchService, CLLocationManagerDelegate {
    nonisolated static let app = "Compass"
    /// No `R` from the watch for this long: Compass was closed without saying so.
    static let quietLimit: Duration = .seconds(15)
    /// At most this often to the watch, and only on a change of this many degrees (else every `beat`).
    static let minGap: TimeInterval = 0.1
    static let minChange = 1.0
    static let beat: TimeInterval = 2

    private(set) var running = false
    private(set) var heading: Double?
    var status: String?

    private let manager = CLLocationManager()
    private var lastR: ContinuousClock.Instant = .now
    private var watchdog: Task<Void, Never>?
    private var sentAt: Date = .distantPast
    private var sent: Double?
    private var sending = false

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 0.5
        manager.headingOrientation = .portrait
        // a fix lets iOS give true north; a coarse one is enough
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500
    }

    func receive(_ m: Data) {
        switch CompassProto.parse(m) {
        case .ready:
            lastR = .now
            if !running { start() } else if let h = heading, let last = lastSample {
                // a resumed watch app: the heading at once
                send(h, last)
            }
        case .closed: stop()
        case nil: break
        }
    }

    /// Another watch app talked: Compass is not open any more.
    func otherApp() { if running { stop() } }

    func start() {
        guard CLLocationManager.headingAvailable() else {
            status = "This iPhone has no compass."
            Task { try? await Hub.shared.send(Self.app, CompassProto.note("No compass on iPhone")) }
            return
        }
        running = true
        status = nil
        sent = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "Location is off for CMFX: the heading is magnetic north."
        default: break
        }
        // the phone may be locked in a pocket while the watch shows it
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.running else { return }
                if ContinuousClock.now - self.lastR > Self.quietLimit { self.stop(); return }
                // nothing new from the compass: the same heading again, so the watch doesn't call it stale
                if let h = self.heading, let s = self.lastSample, Date().timeIntervalSince(self.sentAt) >= Self.beat {
                    self.send(h, s)
                }
            }
        }
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        manager.stopUpdatingHeading()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private struct Sample { var accuracy: Double; var trueNorth: Bool; var calibrate: Bool }
    private var lastSample: Sample?

    private func send(_ h: Double, _ s: Sample) {
        guard !sending else { return }
        sending = true
        sentAt = Date()
        sent = h
        Task {
            defer { sending = false }
            try? await Hub.shared.send(Self.app, CompassProto.heading(h, accuracy: s.accuracy, trueNorth: s.trueNorth, calibrate: s.calibrate))
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        let mag = h.magneticHeading, tru = h.trueHeading, acc = h.headingAccuracy
        Task { @MainActor in
            guard self.running, acc >= 0 else { return }
            let useTrue = tru >= 0
            let deg = useTrue ? tru : mag
            self.heading = deg
            let s = Sample(accuracy: acc, trueNorth: useTrue, calibrate: acc > 45)
            self.lastSample = s
            let changed = self.sent.map { abs((deg - $0 + 540).truncatingRemainder(dividingBy: 360) - 180) >= Self.minChange } ?? true
            let gap = Date().timeIntervalSince(self.sentAt)
            if changed && gap >= Self.minGap || gap >= Self.beat { self.send(deg, s) }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {}

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ m: CLLocationManager) -> Bool { false }
}
