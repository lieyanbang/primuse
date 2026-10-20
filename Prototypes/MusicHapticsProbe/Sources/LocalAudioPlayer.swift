import AVFoundation
import Foundation
import MediaPlayer
import Observation

enum AudioSessionStatus: String, Equatable {
    case notActivated = "Not activated"
    case activating = "Activating"
    case active = "Active"
    case interrupted = "Interrupted"
    case inactive = "Inactive"
    case failed = "Failed"
}

@MainActor
@Observable
final class LocalAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var titleSource: MetadataFieldSource = .missing
    private(set) var artistSource: MetadataFieldSource = .missing
    private(set) var albumSource: MetadataFieldSource = .missing
    private(set) var durationSource: MetadataFieldSource = .missing
    private(set) var isrc = ""
    private(set) var isrcSource: MetadataFieldSource = .missing
    private(set) var isrcConfirmedByUser = false
    private(set) var importedFileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var playbackState: PlaybackState = .stopped
    private(set) var audioSessionStatus: AudioSessionStatus = .notActivated
    private(set) var nowPlayingFields: [String] = []
    private(set) var errorMessage: String?

    var hasAudio: Bool { audioPlayer != nil }
    var validatedISRC: String? { ISRC.normalized(isrc) }
    var canPublishISRC: Bool { validatedISRC != nil && isrcConfirmedByUser }

    @ObservationIgnored private let logger = DiagnosticsLogStore.shared
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var wasPlayingBeforeInterruption = false

    override init() {
        super.init()
        activate()
    }

    func activate() {
        observeAudioSession()
        if hasAudio {
            registerRemoteCommands()
        }
    }

    func importAudio(from sourceURL: URL) async throws {
        stop()
        errorMessage = nil

        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileMetadata: ImportedAudioMetadata
        do {
            fileMetadata = try await AudioMetadataReader.read(from: sourceURL)
            Task {
                await logger.record(
                    category: "audio_metadata",
                    result: "read",
                    parameters: [
                        "title_present": String(fileMetadata.title.value != nil),
                        "artist_present": String(fileMetadata.artist.value != nil),
                        "album_present": String(fileMetadata.album.value != nil),
                        "isrc_present": String(fileMetadata.isrc.value != nil),
                        "duration_present": String(fileMetadata.duration != nil)
                    ]
                )
            }
        } catch {
            fileMetadata = ImportedAudioMetadata()
            Task { await logger.record(category: "audio_metadata", result: "read_failed", parameters: ["fallback": "filename_and_player_duration"]) }
        }

        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let importDirectory = cacheDirectory.appendingPathComponent("ImportedAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension
        let destinationName = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = importDirectory.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        do {
            let player = try AVAudioPlayer(contentsOf: destinationURL)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            registerRemoteCommands()
            importedFileName = sourceURL.lastPathComponent

            if let embeddedTitle = fileMetadata.title.value {
                title = embeddedTitle
                titleSource = .embedded
            } else {
                title = sourceURL.deletingPathExtension().lastPathComponent
                titleSource = .fileName
            }
            artist = fileMetadata.artist.value ?? ""
            artistSource = fileMetadata.artist.value == nil ? .missing : .embedded
            album = fileMetadata.album.value ?? ""
            albumSource = fileMetadata.album.value == nil ? .missing : .embedded
            duration = player.duration.isFinite && player.duration > 0 ? player.duration : (fileMetadata.duration ?? 0)
            durationSource = duration > 0 ? .audioFile : .missing
            currentTime = 0

            if let extractedISRC = fileMetadata.isrc.value, let normalized = ISRC.normalized(extractedISRC) {
                isrc = normalized
                isrcSource = .embedded
                isrcConfirmedByUser = false
            } else {
                isrc = ""
                isrcSource = .missing
                isrcConfirmedByUser = false
            }

            playbackState = .stopped
            publishNowPlayingInfo(reason: "audio_imported")
            Task {
                await logger.record(
                    category: "playback",
                    result: "audio_imported",
                    parameters: ["duration_seconds": String(Int(duration.rounded())), "metadata_fields_present": String([title, artist, album].filter { !$0.isEmpty }.count)]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            playbackState = playbackState.applying(.failure)
            errorMessage = "The selected file could not be opened for playback."
            Task { await logger.record(category: "playback", result: "audio_import_failed", parameters: ["error_type": String(describing: type(of: error))]) }
            throw error
        }
    }

    func editTitle(_ value: String) {
        title = value
        titleSource = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .manual
        publishNowPlayingInfo(reason: "title_edited")
    }

    func editArtist(_ value: String) {
        artist = value
        artistSource = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .manual
        publishNowPlayingInfo(reason: "artist_edited")
    }

    func editAlbum(_ value: String) {
        album = value
        albumSource = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .manual
        publishNowPlayingInfo(reason: "album_edited")
    }

    func editISRC(_ value: String) {
        isrc = value.uppercased()
        isrcSource = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .manual
        isrcConfirmedByUser = false
        publishNowPlayingInfo(reason: "isrc_edited_unconfirmed")
    }

    @discardableResult
    func confirmCurrentISRC() -> Bool {
        guard let code = validatedISRC else { return false }
        isrc = code
        isrcConfirmedByUser = true
        publishNowPlayingInfo(reason: "isrc_user_confirmed")
        Task {
            await logger.record(
                category: "isrc",
                result: "user_confirmed",
                parameters: ["source": isrcSource.rawValue, "isrc_redacted": ISRC.redacted(code)]
            )
        }
        return true
    }

    func applyMusicBrainzISRC(_ code: String) {
        guard let normalized = ISRC.normalized(code) else { return }
        isrc = normalized
        isrcSource = .musicBrainz
        isrcConfirmedByUser = true
        publishNowPlayingInfo(reason: "musicbrainz_isrc_user_confirmed")
        Task {
            await logger.record(
                category: "isrc",
                result: "musicbrainz_candidate_user_confirmed",
                parameters: ["source": isrcSource.rawValue, "isrc_redacted": ISRC.redacted(normalized)]
            )
        }
    }

    func play() {
        guard let audioPlayer else { return }
        do {
            audioSessionStatus = .activating
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            audioSessionStatus = .active
            logAudioSession(result: "activated", session: session)

            if audioPlayer.currentTime >= audioPlayer.duration {
                audioPlayer.currentTime = 0
                currentTime = 0
            }
            guard audioPlayer.play() else {
                playbackState = playbackState.applying(.failure)
                errorMessage = "The audio player could not start this file."
                logPlayback("play_failed")
                return
            }
            playbackState = playbackState.applying(.playSucceeded)
            errorMessage = nil
            publishNowPlayingInfo(reason: "play_started")
            startProgressUpdates()
            logPlayback("playing")
        } catch {
            audioSessionStatus = .failed
            playbackState = playbackState.applying(.failure)
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
            Task { await logger.record(category: "audio_session", result: "activation_failed", parameters: ["error_type": String(describing: type(of: error))]) }
        }
    }

    func pause() {
        guard let audioPlayer else { return }
        audioPlayer.pause()
        currentTime = audioPlayer.currentTime
        playbackState = playbackState.applying(.pause)
        stopProgressUpdates()
        deactivateAudioSession()
        publishNowPlayingInfo(reason: "paused")
        logPlayback("paused")
    }

    func stop() {
        stopProgressUpdates()
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        currentTime = 0
        playbackState = playbackState.applying(.stop)
        deactivateAudioSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlayingFields = []
        logPlayback("stopped")
        Task {
            await logger.record(category: "now_playing_snapshot", result: "cleared", parameters: ["fields": "none"])
        }
    }

    func seek(to requestedTime: TimeInterval, publish: Bool = false) {
        guard let audioPlayer, requestedTime.isFinite else { return }
        let target = min(max(0, requestedTime), max(duration, 0))
        audioPlayer.currentTime = target
        currentTime = target
        if publish {
            publishNowPlayingInfo(reason: "seek")
            logPlayback("seek", parameters: ["position_seconds": String(Int(target.rounded()))])
        }
    }

    func seekBy(_ offset: TimeInterval) {
        seek(to: currentTime + offset, publish: true)
    }

    func republishNowPlayingInfo() {
        publishNowPlayingInfo(reason: "manual_republish")
    }

    func formattedTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    func shutdown() {
        stop()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        interruptionObserver = nil
        routeChangeObserver = nil
        for (command, token) in remoteCommandTargets {
            command.removeTarget(token)
        }
        remoteCommandTargets.removeAll()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentTime = player.duration
        duration = player.duration
        playbackState = playbackState.applying(.playbackEnded)
        stopProgressUpdates()
        deactivateAudioSession()
        publishNowPlayingInfo(reason: "playback_finished")
        logPlayback(flag ? "finished" : "finished_with_decode_failure")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        playbackState = playbackState.applying(.failure)
        errorMessage = "The audio file encountered a decoding error."
        stopProgressUpdates()
        deactivateAudioSession()
        publishNowPlayingInfo(reason: "decode_error")
        logPlayback("decode_error", parameters: ["error_present": String(error != nil)])
    }

    private func publishNowPlayingInfo(reason: String) {
        guard let audioPlayer else { return }
        let payload = NowPlayingPayload.make(
            title: title,
            artist: artist,
            album: album,
            duration: duration > 0 ? duration : audioPlayer.duration,
            elapsed: currentTime,
            playbackRate: playbackState == .playing ? 1 : 0,
            confirmedISRC: canPublishISRC ? validatedISRC : nil
        )
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = payload
        let actualInformation = center.nowPlayingInfo
        nowPlayingFields = NowPlayingPayload.fieldNames(in: actualInformation)
        let hasISRC = actualInformation?[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] != nil
        Task {
            await logger.record(
                category: "now_playing_snapshot",
                result: "published",
                parameters: [
                    "reason": reason,
                    "fields": nowPlayingFields.joined(separator: ","),
                    "isrc_in_snapshot": String(hasISRC),
                    "isrc_confirmed": String(isrcConfirmedByUser),
                    "isrc_redacted": ISRC.redacted(validatedISRC),
                    "playback_state": playbackState.rawValue,
                    "elapsed_seconds": String(Int(currentTime.rounded()))
                ]
            )
        }
    }

    private func startProgressUpdates() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying, player.currentTime >= player.duration {
                    self.audioPlayerDidFinishPlaying(player, successfully: true)
                    return
                }
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func observeAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(rawType: rawType, rawOptions: rawOptions, reasonCode: rawReason)
            }
            }
        }
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleRouteChange(reasonCode: rawReason) }
            }
        }
        Task {
            await logger.record(
                category: "audio_session",
                result: "observers_registered",
                parameters: ["interruption": String(interruptionObserver != nil), "route_change": String(routeChangeObserver != nil)]
            )
        }
    }

    private func handleAudioInterruption(rawType: UInt, rawOptions: UInt, reasonCode: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        if type == .began {
            wasPlayingBeforeInterruption = playbackState == .playing || audioPlayer?.isPlaying == true
            audioPlayer?.pause()
            currentTime = audioPlayer?.currentTime ?? currentTime
            playbackState = playbackState.applying(.interruptionBegan)
            audioSessionStatus = .interrupted
            stopProgressUpdates()
            publishNowPlayingInfo(reason: "audio_interruption_began")
            logPlayback("interruption_began", parameters: [
                "was_playing": String(wasPlayingBeforeInterruption),
                "reason_code": String(reasonCode)
            ])
        } else if type == .ended {
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            let resume = wasPlayingBeforeInterruption && shouldResume
            playbackState = playbackState.applying(.interruptionEnded(shouldResume: resume))
            wasPlayingBeforeInterruption = false
            Task {
                await logger.record(
                    category: "audio_session",
                    result: "interruption_ended",
                    parameters: ["system_recommends_resume": String(shouldResume), "resumed": String(resume)]
                )
            }
            if resume {
                play()
            } else {
                audioSessionStatus = .inactive
                deactivateAudioSession()
                publishNowPlayingInfo(reason: "audio_interruption_ended_paused")
            }
        }
    }

    private func handleRouteChange(reasonCode rawReason: UInt) {
        let session = AVAudioSession.sharedInstance()
        let outputTypes = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        Task {
            await logger.record(
                category: "audio_session",
                result: "route_changed",
                parameters: ["reason_code": String(rawReason), "output_port_types": outputTypes]
            )
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionStatus = .inactive
            Task { await logger.record(category: "audio_session", result: "deactivated") }
        } catch {
            audioSessionStatus = .failed
            Task { await logger.record(category: "audio_session", result: "deactivation_failed", parameters: ["error_type": String(describing: type(of: error))]) }
        }
    }

    private func logAudioSession(result: String, session: AVAudioSession) {
        let outputTypes = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        Task {
            await logger.record(
                category: "audio_session",
                result: result,
                parameters: [
                    "category": session.category.rawValue,
                    "mode": session.mode.rawValue,
                    "other_audio_playing": String(session.isOtherAudioPlaying),
                    "output_port_types": outputTypes
                ]
            )
        }
    }

    private func logPlayback(_ result: String, parameters: [String: String] = [:]) {
        var details = parameters
        details["state"] = playbackState.rawValue
        details["audio_session"] = audioSessionStatus.rawValue
        details["elapsed_seconds"] = String(Int(currentTime.rounded()))
        Task { await logger.record(category: "playback", result: result, parameters: details) }
    }

    private func registerRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.preferredIntervals = [10]

        register(commandCenter.playCommand) { $0.play() }
        register(commandCenter.pauseCommand) { $0.pause() }
        register(commandCenter.stopCommand) { $0.stop() }
        register(commandCenter.togglePlayPauseCommand) { player in
            player.playbackState == .playing ? player.pause() : player.play()
        }
        register(commandCenter.skipForwardCommand) { player in
            player.seekBy(10)
        }
        register(commandCenter.skipBackwardCommand) { player in
            player.seekBy(-10)
        }
        let positionToken = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: position, publish: true)
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.changePlaybackPositionCommand, positionToken))
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor @Sendable (LocalAudioPlayer) -> Void
    ) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, token))
    }

}
