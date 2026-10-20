import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum ProbeSheet: String, Identifiable {
    case diagnostics
    case musicBrainz

    var id: String { rawValue }
}

struct MusicHapticsProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var haptics = MusicHapticsStatus()
    @State private var player = LocalAudioPlayer()
    @State private var isImporterPresented = false
    @State private var activeSheet: ProbeSheet?
    @State private var importError: String?
    @State private var hasLoggedInitialLaunch = false

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
            VStack(alignment: .leading, spacing: 18) {
                header
                systemStatus
                recordingDetails
                playbackControls
                isrcControls
                nowPlayingStatus
                diagnosticsEntry
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .diagnostics:
                DiagnosticsLogView()
            case .musicBrainz:
                MusicBrainzLookupView(title: player.title, artist: player.artist, expectedDuration: player.duration) { code in
                    player.applyMusicBrainzISRC(code)
                    haptics.clearTrackAvailability()
                    haptics.checkTrackAvailability(for: code)
                }
            }
        }
        .onAppear {
            haptics.startObserving()
            player.activate()
            if !hasLoggedInitialLaunch {
                hasLoggedInitialLaunch = true
                let launchDetails = [
                    "app_version": appVersion,
                    "system_version": systemVersion,
                    "bundle_id": Bundle.main.bundleIdentifier ?? "unknown"
                ]
                Task { await DiagnosticsLogStore.shared.record(category: "app_launch", result: "started", parameters: launchDetails) }
            }
        }
        .onDisappear {
            // A sheet and the file importer cover this view without ending its observer lifetime.
            if scenePhase == .active, activeSheet == nil, !isImporterPresented {
                haptics.stopObserving()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                haptics.startObserving()
                haptics.refreshSystemStatus()
                Task { await DiagnosticsLogStore.shared.record(category: "app_lifecycle", result: "active") }
            } else if phase == .background {
                Task { await DiagnosticsLogStore.shared.record(category: "app_lifecycle", result: "background") }
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
            Text("MUSIC HAPTICS PROTOTYPE · v0.2")
                .font(.caption.weight(.bold))
                .tracking(1.2)
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
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    title: "System setting",
                    value: haptics.systemIsActive ? "On" : "Off",
                    symbol: haptics.systemIsActive ? "checkmark.circle.fill" : "minus.circle"
                )
                statusRow(
                    title: "Track availability",
                    value: haptics.trackAvailability.label,
                    symbol: haptics.trackAvailability == .available ? "waveform" : "waveform.slash"
                )
                statusRow(
                    title: "Native haptic playback",
                    value: haptics.hapticPlaybackIsActive.map { $0 ? "Active" : "Inactive" } ?? "Awaiting callback",
                    symbol: haptics.hapticPlaybackIsActive == true ? "waveform" : "waveform.slash"
                )
                detailRow("Last callback", haptics.lastCallbackDescription)
                detailRow("Callback time", haptics.lastCallbackAt?.formatted(date: .numeric, time: .standard) ?? "No callback received")
                if let observedISRC = haptics.observedISRC, !observedISRC.isEmpty {
                    detailRow("Callback ISRC", observedISRC)
                }
                HStack {
                    Button {
                        haptics.refreshSystemStatus()
                    } label: {
                        Label("Refresh system state", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 4)
                }
                Text("The system setting, matching haptic track, and active haptic playback are separate signals.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordingDetails: some View {
        GroupBox("Current recording") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import one local audio file", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                metadataField("Title", value: player.title, source: player.titleSource) {
                    TextField("Title", text: Binding(get: { player.title }, set: player.editTitle))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!player.hasAudio)
                }
                metadataField("Artist", value: player.artist, source: player.artistSource) {
                    TextField("Artist", text: Binding(get: { player.artist }, set: player.editArtist))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!player.hasAudio)
                }
                metadataField("Album", value: player.album, source: player.albumSource) {
                    TextField("Album", text: Binding(get: { player.album }, set: player.editAlbum))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!player.hasAudio)
                }
                detailRow("Duration", player.duration > 0 ? player.formattedTime(player.duration) : "Missing")
                detailRow("Duration source", player.durationSource.rawValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playbackControls: some View {
        GroupBox("Audio playback") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow(title: "Audio session", value: player.audioSessionStatus.rawValue, symbol: "speaker.wave.2")
                statusRow(title: "Playback", value: player.playbackState.label, symbol: player.playbackState == .playing ? "play.fill" : "pause.fill")

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing { player.republishNowPlayingInfo() }
                    }
                )
                .disabled(!player.hasAudio || player.duration <= 0)
                HStack {
                    Text(player.formattedTime(player.currentTime))
                    Spacer()
                    Text(player.formattedTime(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { player.seekBy(-10) } label: { Label("−10 sec", systemImage: "gobackward.10") }
                    Button {
                        player.playbackState == .playing ? player.pause() : player.play()
                    } label: {
                        Label(player.playbackState == .playing ? "Pause" : "Play", systemImage: player.playbackState == .playing ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.seekBy(10) } label: { Label("+10 sec", systemImage: "goforward.10") }
                    Button { player.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                }
                .buttonStyle(.bordered)
                .disabled(!player.hasAudio)

                if let errorMessage = player.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isrcControls: some View {
        GroupBox("ISRC and haptic-track lookup") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("12-character ISRC", text: Binding(
                    get: { player.isrc },
                    set: { value in
                        player.editISRC(value)
                        haptics.clearTrackAvailability()
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(!player.hasAudio)

                detailRow("ISRC source", player.isrcSource.rawValue)
                detailRow("User confirmed", player.isrcConfirmedByUser ? "Yes" : "No")
                if let code = player.validatedISRC {
                    detailRow("Current ISRC", code)
                } else {
                    detailRow("Current ISRC", player.isrc.isEmpty ? "Missing" : "Invalid format")
                }

                HStack {
                    Button("Confirm / override ISRC") {
                        _ = player.confirmCurrentISRC()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!player.hasAudio || player.validatedISRC == nil)

                    Button {
                        activeSheet = .musicBrainz
                    } label: {
                        Label("Search MusicBrainz", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!player.hasAudio || player.title.isEmpty || player.artist.isEmpty)
                }

                Button {
                    guard player.canPublishISRC, let code = player.validatedISRC else { return }
                    player.republishNowPlayingInfo()
                    haptics.checkTrackAvailability(for: code)
                } label: {
                    Label("Republish Now Playing and query track", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!player.hasAudio || !player.canPublishISRC || haptics.trackAvailability == .checking)

                Text("An ISRC from file tags or MusicBrainz is a candidate until you confirm that it identifies this exact recording. A match score is not proof of authenticity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nowPlayingStatus: some View {
        GroupBox("Now Playing snapshot") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("Published fields", player.nowPlayingFields.isEmpty ? "None" : player.nowPlayingFields.joined(separator: ", "))
                detailRow("Published ISRC", player.nowPlayingFields.contains("ISRC") ? "Present (user confirmed)" : "Not published")
                Button {
                    player.republishNowPlayingInfo()
                } label: {
                    Label("Manually republish Now Playing", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!player.hasAudio)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticsEntry: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("App version", appVersion)
                detailRow("iOS", systemVersion)
                detailRow("Bundle ID", Bundle.main.bundleIdentifier ?? "unknown")
                detailRow("Last status event", haptics.lastDiagnostic)
                Button {
                    activeSheet = .diagnostics
                } label: {
                    Label("View, copy, export, or clear logs", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                Text("Logs are saved under Documents/Diagnostics and omit track titles, artist names, file names, and full ISRC values.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataField<Content: View>(
        _ name: String,
        value: String,
        source: MetadataFieldSource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.caption.weight(.semibold))
                Spacer()
                Text(source.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            content()
            if value.isEmpty {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.footnote)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await player.importAudio(from: url)
                    haptics.clearTrackAvailability()
                } catch {
                    importError = "The selected file could not be imported for local playback."
                    await DiagnosticsLogStore.shared.record(category: "playback", result: "import_error_shown")
                }
            }
        case .failure(let error):
            importError = "The file picker could not provide an audio file."
            Task {
                await DiagnosticsLogStore.shared.record(category: "playback", result: "file_picker_failed", parameters: ["error_type": String(describing: type(of: error))])
            }
        }
    }
}
