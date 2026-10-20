import SwiftUI

struct MusicBrainzLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var candidates: [RecordingCandidate] = []
    @State private var selectedCandidateID: String?
    @State private var codesByRecordingID: [String: [String]] = [:]
    @State private var isSearching = false
    @State private var isLoadingISRCs = false
    @State private var hasCompletedSearch = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isrcTask: Task<Void, Never>?
    @State private var searchRequestID = UUID()
    @State private var isrcRequestID = UUID()

    private let expectedDuration: TimeInterval?
    let onConfirm: (String) -> Void

    init(title: String, artist: String, expectedDuration: TimeInterval, onConfirm: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        _artist = State(initialValue: artist)
        self.expectedDuration = expectedDuration > 0 ? expectedDuration : nil
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Recording title", text: $title)
                        .textFieldStyle(.roundedBorder)
                    TextField("Artist", text: $artist)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            search()
                        } label: {
                            Label(isSearching ? "Searching…" : "Search recordings", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSearching || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isSearching {
                            Button("Cancel") { cancelSearch() }
                                .buttonStyle(.bordered)
                        }
                    }

                    Text("Tapping Search sends the title and artist to MusicBrainz over HTTPS. Candidates are for manual comparison; relevance scores do not verify the recording or master.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                    if hasCompletedSearch, !isSearching, candidates.isEmpty, errorMessage == nil {
                        Text("No recording candidates were found.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
                .padding()
            }
            .navigationTitle("MusicBrainz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear {
                searchRequestID = UUID()
                isrcRequestID = UUID()
                searchTask?.cancel()
                isrcTask?.cancel()
                isSearching = false
                isLoadingISRCs = false
            }
        }
    }

    private func candidateCard(_ candidate: RecordingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title).font(.headline)
            Text(candidate.artistCredit).font(.subheadline)
            Text("MusicBrainz score: \(candidate.serverRelevanceScore.map(String.init) ?? "not supplied") · relevance only")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(candidate.matchEvidence, id: \.self) { evidence in
                Label(evidence, systemImage: evidence.hasPrefix("Title matches") || evidence.hasPrefix("Artist credit matches") || evidence.hasPrefix("Duration within") ? "checkmark.circle" : "info.circle")
                    .font(.caption)
            }

            Button {
                loadISRCs(for: candidate)
            } label: {
                Label(selectedCandidateID == candidate.id && isLoadingISRCs ? "Loading ISRCs…" : "Load ISRCs for this recording", systemImage: "barcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingISRCs)

            if selectedCandidateID == candidate.id, let codes = codesByRecordingID[candidate.id] {
                if codes.isEmpty {
                    Text("This MusicBrainz recording has no ISRC listed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(codes, id: \.self) { code in
                    Button {
                        onConfirm(code)
                        dismiss()
                    } label: {
                        Label("Confirm and use \(code)", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func search() {
        searchTask?.cancel()
        isrcTask?.cancel()
        isrcRequestID = UUID()
        isLoadingISRCs = false
        searchRequestID = UUID()
        let requestID = searchRequestID
        candidates = []
        codesByRecordingID = [:]
        selectedCandidateID = nil
        errorMessage = nil
        hasCompletedSearch = false
        isSearching = true
        let queryTitle = title
        let queryArtist = artist
        Task {
            await DiagnosticsLogStore.shared.record(
                category: "musicbrainz",
                result: "search_requested",
                parameters: [
                    "title_present": String(!queryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    "artist_present": String(!queryArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    "duration_present": String(expectedDuration != nil)
                ]
            )
        }
        searchTask = Task {
            do {
                let results = try await MusicBrainzClient.shared.searchRecordings(title: queryTitle, artist: queryArtist, expectedDuration: expectedDuration)
                try Task.checkCancellation()
                guard searchRequestID == requestID else { return }
                candidates = results
                hasCompletedSearch = true
                isSearching = false
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "search_succeeded", parameters: ["candidate_count": String(results.count)])
            } catch is CancellationError {
                guard searchRequestID == requestID else { return }
                isSearching = false
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "search_cancelled")
            } catch let error as MusicBrainzClientError {
                guard searchRequestID == requestID else { return }
                isSearching = false
                errorMessage = error.userMessage
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "search_failed", parameters: ["error_kind": String(describing: error)])
            } catch {
                guard searchRequestID == requestID else { return }
                isSearching = false
                errorMessage = "MusicBrainz could not be reached. Check the network and try again."
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "search_network_error", parameters: ["error_type": String(describing: type(of: error))])
            }
        }
    }

    private func loadISRCs(for candidate: RecordingCandidate) {
        isrcTask?.cancel()
        isrcRequestID = UUID()
        let requestID = isrcRequestID
        isrcTask = nil
        selectedCandidateID = candidate.id
        isLoadingISRCs = true
        errorMessage = nil
        Task { await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "recording_isrc_lookup_requested", parameters: ["recording_id_present": "true"]) }
        isrcTask = Task {
            do {
                let codes = try await MusicBrainzClient.shared.isrcs(forRecordingID: candidate.id)
                try Task.checkCancellation()
                guard isrcRequestID == requestID else { return }
                codesByRecordingID[candidate.id] = codes
                isLoadingISRCs = false
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "recording_isrc_lookup_succeeded", parameters: ["isrc_count": String(codes.count)])
            } catch is CancellationError {
                guard isrcRequestID == requestID else { return }
                isLoadingISRCs = false
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "recording_isrc_lookup_cancelled")
            } catch let error as MusicBrainzClientError {
                guard isrcRequestID == requestID else { return }
                isLoadingISRCs = false
                errorMessage = error.userMessage
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "recording_isrc_lookup_failed", parameters: ["error_kind": String(describing: error)])
            } catch {
                guard isrcRequestID == requestID else { return }
                isLoadingISRCs = false
                errorMessage = "MusicBrainz could not be reached. Check the network and try again."
                await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "recording_isrc_network_error", parameters: ["error_type": String(describing: type(of: error))])
            }
        }
    }

    private func cancelSearch() {
        searchRequestID = UUID()
        searchTask?.cancel()
        isSearching = false
        Task { await DiagnosticsLogStore.shared.record(category: "musicbrainz", result: "search_cancelled_by_user") }
    }
}
