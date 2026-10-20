import Foundation
import MediaAccessibility
import Observation

enum HapticTrackAvailability: Equatable {
    case notChecked
    case checking
    case available
    case unavailable
    case failed

    var label: String {
        switch self {
        case .notChecked: return "Not checked"
        case .checking: return "Checking…"
        case .available: return "Track available"
        case .unavailable: return "No track found"
        case .failed: return "Query failed"
        }
    }
}

@MainActor
@Observable
final class MusicHapticsStatus {
    private(set) var systemIsActive = false
    private(set) var trackAvailability: HapticTrackAvailability = .notChecked
    private(set) var hapticPlaybackIsActive: Bool?
    private(set) var observedISRC: String?
    private(set) var lastCallbackAt: Date?
    private(set) var lastCallbackDescription = "Waiting for the system playback observer"
    private(set) var lastDiagnostic = "Waiting for observer registration"

    @ObservationIgnored private let manager = MAMusicHapticsManager.shared
    @ObservationIgnored private let logger = DiagnosticsLogStore.shared
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var playbackObserver: (any NSCopying)?
    @ObservationIgnored private var availabilityRequestID = UUID()
    @ObservationIgnored private var isObserving = false

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        systemIsActive = manager.isActive
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MAMusicHapticsManager.activeStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemIsActive = self.manager.isActive
                self.lastDiagnostic = "System Music Haptics setting changed"
                Task {
                    await self.logger.record(
                        category: "system_haptics_setting",
                        result: "changed",
                        parameters: ["active": String(self.systemIsActive)]
                    )
                }
            }
        }

        playbackObserver = manager.addStatusObserver { [weak self] isrc, isActive in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let receivedAt = Date.now
                self.observedISRC = isrc.isEmpty ? nil : isrc
                self.hapticPlaybackIsActive = isActive
                self.lastCallbackAt = receivedAt
                self.lastCallbackDescription = "active=\(isActive), ISRC=\(isrc.isEmpty ? "none" : isrc)"
                self.lastDiagnostic = "Native haptic playback observer called"
                Task {
                    await self.logger.record(
                        category: "haptics_observer",
                        result: isActive ? "active" : "inactive",
                        parameters: [
                            "isrc_present": String(!isrc.isEmpty),
                            "isrc_redacted": ISRC.redacted(isrc)
                        ],
                        at: receivedAt
                    )
                }
            }
        }

        lastDiagnostic = "Observers registered; system active=\(systemIsActive)"
        Task {
            await logger.record(
                category: "system_haptics_setting",
                result: playbackObserver == nil ? "playback_observer_unavailable" : "observers_registered",
                parameters: [
                    "active": String(systemIsActive),
                    "playback_observer_registered": String(playbackObserver != nil)
                ]
            )
        }
    }

    func stopObserving() {
        guard isObserving else { return }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let playbackObserver {
            manager.removeStatusObserver(playbackObserver)
            self.playbackObserver = nil
        }
        isObserving = false
        lastDiagnostic = "Observers released"
        Task { await logger.record(category: "system_haptics_setting", result: "observers_released") }
    }

    func clearTrackAvailability() {
        availabilityRequestID = UUID()
        trackAvailability = .notChecked
    }

    func refreshSystemStatus() {
        let previousValue = systemIsActive
        systemIsActive = manager.isActive
        lastDiagnostic = "System Music Haptics state refreshed"
        Task {
            await logger.record(
                category: "system_haptics_setting",
                result: "refreshed",
                parameters: ["active": String(systemIsActive), "changed": String(previousValue != systemIsActive)]
            )
        }
    }

    func checkTrackAvailability(for rawISRC: String) {
        guard let code = ISRC.normalized(rawISRC) else {
            clearTrackAvailability()
            lastDiagnostic = "Track query skipped because the ISRC format is invalid"
            Task {
                await logger.record(
                    category: "isrc_track_query",
                    result: "rejected_invalid_format",
                    parameters: ["isrc_present": String(!rawISRC.isEmpty)]
                )
            }
            return
        }

        let requestID = UUID()
        availabilityRequestID = requestID
        trackAvailability = .checking
        lastDiagnostic = "Checking system haptic track availability"
        Task {
            await logger.record(
                category: "isrc_track_query",
                result: "requested",
                parameters: ["isrc_redacted": ISRC.redacted(code)]
            )
        }

        manager.checkHapticTrackAvailabilityForMedia(matchingCode: code) { [weak self] isAvailable in
            Task { @MainActor [weak self] in
                guard let self, self.availabilityRequestID == requestID else { return }
                self.trackAvailability = isAvailable ? .available : .unavailable
                self.lastDiagnostic = "System haptic track availability returned \(isAvailable)"
                Task {
                    await self.logger.record(
                        category: "isrc_track_query",
                        result: isAvailable ? "available" : "unavailable",
                        parameters: ["isrc_redacted": ISRC.redacted(code)]
                    )
                }
            }
        }
    }
}
