import Foundation
import MediaAccessibility
import Observation

enum HapticTrackAvailability: Equatable {
    case notChecked
    case checking
    case available
    case unavailable

    var label: String {
        switch self {
        case .notChecked: return "Not checked"
        case .checking: return "Checking…"
        case .available: return "Track available"
        case .unavailable: return "No track found"
        }
    }
}

@MainActor
@Observable
final class MusicHapticsStatus {
    private(set) var systemIsActive = false
    private(set) var trackAvailability: HapticTrackAvailability = .notChecked
    private(set) var hapticPlaybackIsActive = false
    private(set) var observedISRC: String?
    private(set) var lastDiagnostic = "Waiting for observer registration"

    @ObservationIgnored private let manager = MAMusicHapticsManager.shared
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var playbackObserver: (any NSCopying)?
    @ObservationIgnored private var availabilityRequestID = UUID()

    func startObserving() {
        guard settingsObserver == nil else { return }

        systemIsActive = manager.isActive
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MAMusicHapticsManager.activeStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemIsActive = self.manager.isActive
                self.lastDiagnostic = "Music Haptics setting changed at \(Date.now.formatted(date: .omitted, time: .standard))"
                print("[MusicHapticsProbe] system setting changed: \(self.systemIsActive)")
            }
        }

        playbackObserver = manager.addStatusObserver { [weak self] isrc, isActive in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observedISRC = isrc.isEmpty ? nil : isrc
                self.hapticPlaybackIsActive = isActive
                self.lastDiagnostic = "Native haptic playback status updated"
                print("[MusicHapticsProbe] haptic playback status: active=\(isActive), ISRC=\(isrc)")
            }
        }

        lastDiagnostic = "Observers registered; system active=\(systemIsActive)"
        print("[MusicHapticsProbe] started; iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func stopObserving() {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }

        if let playbackObserver {
            manager.removeStatusObserver(playbackObserver)
            self.playbackObserver = nil
        }

        lastDiagnostic = "Observers released"
        print("[MusicHapticsProbe] observers released")
    }

    func clearTrackAvailability() {
        availabilityRequestID = UUID()
        trackAvailability = .notChecked
    }

    func refreshSystemStatus() {
        systemIsActive = manager.isActive
        lastDiagnostic = "System setting refreshed at \(Date.now.formatted(date: .omitted, time: .standard))"
    }

    func checkTrackAvailability(for rawISRC: String) {
        guard let code = ISRC.normalized(rawISRC) else {
            clearTrackAvailability()
            lastDiagnostic = "Track query skipped: the entered ISRC is not valid"
            return
        }

        let requestID = UUID()
        availabilityRequestID = requestID
        trackAvailability = .checking
        lastDiagnostic = "Checking haptic track for verified ISRC \(code)"
        print("[MusicHapticsProbe] checking haptic track for ISRC \(code)")

        manager.checkHapticTrackAvailabilityForMedia(matchingCode: code) { [weak self] isAvailable in
            Task { @MainActor [weak self] in
                guard let self, self.availabilityRequestID == requestID else { return }
                self.trackAvailability = isAvailable ? .available : .unavailable
                self.lastDiagnostic = "Track availability result for \(code): \(isAvailable)"
                print("[MusicHapticsProbe] haptic track availability: \(isAvailable) for \(code)")
            }
        }
    }
}
