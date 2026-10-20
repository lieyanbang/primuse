import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class LocalAudioPlayer {
    var title = ""
    var artist = ""
    var isrc = ""
    private(set) var importedFileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    var hasAudio: Bool { audioPlayer != nil }
    var validatedISRC: String? { ISRC.normalized(isrc) }

    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    func importAudio(from sourceURL: URL) throws {
        stop()
        errorMessage = nil

        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
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
        let destinationName = fileExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = importDirectory.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        do {
            let player = try AVAudioPlayer(contentsOf: destinationURL)
            player.prepareToPlay()
            audioPlayer = player
            importedFileName = sourceURL.lastPathComponent
            title = sourceURL.deletingPathExtension().lastPathComponent
            artist = ""
            isrc = ""
            duration = player.duration
            currentTime = 0
            isPlaying = false
            publishNowPlayingInfo()
            print("[MusicHapticsProbe] imported audio file: \(sourceURL.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func play() {
        guard let audioPlayer else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if audioPlayer.currentTime >= audioPlayer.duration {
                audioPlayer.currentTime = 0
            }
            guard audioPlayer.play() else {
                errorMessage = "The audio player could not start this file."
                return
            }
            isPlaying = true
            errorMessage = nil
            publishNowPlayingInfo()
            startProgressUpdates()
            print("[MusicHapticsProbe] playback started")
        } catch {
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
            print("[MusicHapticsProbe] playback error: \(error)")
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        currentTime = audioPlayer?.currentTime ?? currentTime
        publishNowPlayingInfo()
        print("[MusicHapticsProbe] playback paused")
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        currentTime = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func publishNowPlayingInfo() {
        guard let audioPlayer else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? (importedFileName ?? "Local audio") : title,
            MPMediaItemPropertyArtist: artist.isEmpty ? "Unknown artist" : artist,
            MPMediaItemPropertyPlaybackDuration: audioPlayer.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPlayer.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let validatedISRC {
            info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = validatedISRC
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func formattedTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func startProgressUpdates() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }

                guard let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                self.isPlaying = player.isPlaying
                self.publishNowPlayingInfo()

                if !player.isPlaying, player.currentTime >= player.duration {
                    self.currentTime = player.duration
                    self.progressTask = nil
                    return
                }
            }
        }
    }
}
