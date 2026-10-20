import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MusicHapticsProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var haptics = MusicHapticsStatus()
    @State private var player = LocalAudioPlayer()
    @State private var isImporterPresented = false
    @State private var importError: String?

    private var appVersion: String {
        let values = Bundle.main.infoDictionary
        let version = values?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = values?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                systemStatus
                audioPlayer
                hapticTrack
                diagnostics
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .onAppear { haptics.startObserving() }
        .onDisappear { haptics.stopObserving() }
        .onChange(of: player.title) { _, _ in player.publishNowPlayingInfo() }
        .onChange(of: player.artist) { _, _ in player.publishNowPlayingInfo() }
        .onChange(of: player.isrc) { _, _ in
            player.publishNowPlayingInfo()
            haptics.clearTrackAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                haptics.refreshSystemStatus()
            }
        }
        .alert("Could not import audio", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown import error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Primuse")
                .font(.largeTitle.bold())
            Text("MUSIC HAPTICS PROTOTYPE")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
            Text("Isolated native Music Haptics probe")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemStatus: some View {
        GroupBox("System Music Haptics") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    title: "System setting",
                    value: haptics.systemIsActive ? "On" : "Off",
                    symbol: haptics.systemIsActive ? "checkmark.circle.fill" : "minus.circle"
                )
                statusRow(
                    title: "Current native haptic playback",
                    value: haptics.hapticPlaybackIsActive ? "Active" : "Inactive",
                    symbol: haptics.hapticPlaybackIsActive ? "waveform" : "waveform.slash"
                )
                if let observedISRC = haptics.observedISRC, !observedISRC.isEmpty {
                    Text("Observed track ISRC: \(observedISRC)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("The system switch, per-track availability, and active haptic playback are separate states.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var audioPlayer: some View {
        GroupBox("Local audio") {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import one audio file", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if let fileName = player.importedFileName {
                    Text("File: \(fileName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                TextField("Song title", text: $player.title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!player.hasAudio)
                TextField("Artist", text: $player.artist)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!player.hasAudio)

                ProgressView(value: player.duration > 0 ? player.currentTime / player.duration : 0)
                HStack {
                    Text(player.formattedTime(player.currentTime))
                    Spacer()
                    Text(player.formattedTime(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        player.isPlaying ? player.pause() : player.play()
                    } label: {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!player.hasAudio)

                    Button {
                        player.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!player.hasAudio)
                }

                if let errorMessage = player.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hapticTrack: some View {
        GroupBox("Known song haptic track") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter a real ISRC you have verified for this recording. The prototype never generates one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("12-character ISRC", text: $player.isrc)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(!player.hasAudio)

                HStack {
                    Text("Haptic track availability")
                    Spacer()
                    Text(haptics.trackAvailability.label)
                        .fontWeight(.semibold)
                }
                .font(.subheadline)

                if player.hasAudio, player.validatedISRC == nil, !player.isrc.isEmpty {
                    Text("ISRC format should be two letters, three letters or digits, then seven digits.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button {
                    guard let isrc = player.validatedISRC else { return }
                    haptics.checkTrackAvailability(for: isrc)
                    player.publishNowPlayingInfo()
                } label: {
                    Label("Check track availability", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(!player.hasAudio || player.validatedISRC == nil || haptics.trackAvailability == .checking)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnostics: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                diagnosticRow("App version", appVersion)
                diagnosticRow("iOS", systemVersion)
                diagnosticRow("Bundle ID", Bundle.main.bundleIdentifier ?? "unknown")
                diagnosticRow("Last event", haptics.lastDiagnostic)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.subheadline)
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try player.importAudio(from: url)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
