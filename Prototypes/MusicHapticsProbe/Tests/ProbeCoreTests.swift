import Foundation
import MediaPlayer
import XCTest
@testable import MusicHapticsProbe

final class ProbeCoreTests: XCTestCase {
    func testISRCValidationAndNormalization() {
        XCTAssertEqual(ISRC.normalized(" usqe92100257\n"), "USQE92100257")
        XCTAssertEqual(ISRC.normalized("USQE92100257"), "USQE92100257")
        XCTAssertNil(ISRC.normalized("USQE9210025"))
        XCTAssertNil(ISRC.normalized("1SQE92100257"))
        XCTAssertNil(ISRC.normalized("USQE92A00257"))
    }

    func testPlaybackStateTransitionsIncludeInterruptionAndCompletion() {
        var state = PlaybackState.stopped.applying(.playSucceeded)
        XCTAssertEqual(state, .playing)
        state = state.applying(.interruptionBegan)
        XCTAssertEqual(state, .interrupted)
        state = state.applying(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(state, .paused)
        state = state.applying(.playSucceeded)
        state = state.applying(.interruptionBegan)
        state = state.applying(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(state, .playing)
        state = state.applying(.playbackEnded)
        XCTAssertEqual(state, .finished)
        XCTAssertEqual(state.applying(.stop), .stopped)
    }

    func testNowPlayingPayloadPublishesExpectedFieldsAndOnlyConfirmedISRC() {
        let payload = NowPlayingPayload.make(
            title: "Example title",
            artist: "Example artist",
            album: "Example album",
            duration: 201.5,
            elapsed: 12.25,
            playbackRate: 1,
            confirmedISRC: "USQE92100257"
        )
        XCTAssertEqual(payload[MPMediaItemPropertyTitle] as? String, "Example title")
        XCTAssertEqual(payload[MPMediaItemPropertyArtist] as? String, "Example artist")
        XCTAssertEqual(payload[MPMediaItemPropertyAlbumTitle] as? String, "Example album")
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] as? String, "USQE92100257")
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(NowPlayingPayload.fieldNames(in: payload), ["Title", "Artist", "Album", "Duration", "Elapsed time", "Playback rate", "ISRC"])

        let unconfirmed = NowPlayingPayload.make(
            title: "Example title",
            artist: "Example artist",
            album: "",
            duration: 10,
            elapsed: 0,
            playbackRate: 0,
            confirmedISRC: nil
        )
        XCTAssertNil(unconfirmed[MPNowPlayingInfoPropertyInternationalStandardRecordingCode])
        XCTAssertFalse(NowPlayingPayload.fieldNames(in: unconfirmed).contains("ISRC"))
    }

    func testMusicBrainzReturnsMultipleCandidatesAndLookupISRCsByMBID() async throws {
        let recordingID1 = "b9991644-7275-44db-bc43-fff6c6b4ce69"
        let recordingID2 = "75c961c9-6e00-4861-9c9d-e6ca90d57342"
        let searchJSON = """
        {
          "recordings": [
            {"id":"\(recordingID1)","title":"Night Drive","score":100,"length":201000,"artist-credit":[{"name":"Example Artist","artist":{"name":"Example Artist"},"joinphrase":""}]},
            {"id":"\(recordingID2)","title":"Night Drive (Live)","score":82,"length":225000,"artist-credit":[{"name":"Example Artist","artist":{"name":"Example Artist"},"joinphrase":""}]}
          ]
        }
        """
        let lookupJSON = #"{"id":"b9991644-7275-44db-bc43-fff6c6b4ce69","isrcs":["USQE92100257","bad-code"]}"#
        let transport = StubMusicBrainzTransport(responses: [
            "/recording": MusicBrainzHTTPResponse(data: Data(searchJSON.utf8), statusCode: 200),
            "/recording/\(recordingID1)": MusicBrainzHTTPResponse(data: Data(lookupJSON.utf8), statusCode: 200)
        ])
        let client = MusicBrainzClient(transport: transport, minimumRequestInterval: .zero)

        let candidates = try await client.searchRecordings(title: "Night Drive", artist: "Example Artist", expectedDuration: 202)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].title, "Night Drive")
        XCTAssertTrue(candidates[0].matchEvidence.contains { $0.hasPrefix("Title matches") })
        XCTAssertTrue(candidates[0].matchEvidence.contains { $0.hasPrefix("Artist credit matches") })
        XCTAssertTrue(candidates[0].matchEvidence.contains("Duration within 2 seconds"))
        XCTAssertEqual(candidates[1].serverRelevanceScore, 82)

        let codes = try await client.isrcs(forRecordingID: recordingID1)
        XCTAssertEqual(codes, ["USQE92100257"])
        let requests = await transport.requestURLs
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].path.contains(recordingID1))
        XCTAssertEqual(requests[0].scheme, "https")
        let userAgents = await transport.userAgents
        XCTAssertTrue(userAgents.allSatisfy { $0?.hasPrefix("PrimuseMusicHapticsProbe/0.2.0") == true })
    }

    func testMusicBrainzSearchCacheAvoidsDuplicateRequests() async throws {
        let json = #"{"recordings":[{"id":"b9991644-7275-44db-bc43-fff6c6b4ce69","title":"A","score":99,"artist-credit":[{"name":"B"}]}]}"#
        let transport = StubMusicBrainzTransport(responses: [
            "/recording": MusicBrainzHTTPResponse(data: Data(json.utf8), statusCode: 200)
        ])
        let client = MusicBrainzClient(transport: transport, minimumRequestInterval: .zero)
        _ = try await client.searchRecordings(title: "A", artist: "B")
        _ = try await client.searchRecordings(title: "A", artist: "B")
        let requestCount = await transport.requestURLs.count
        XCTAssertEqual(requestCount, 1)
    }

    func testMusicBrainzRequestsAreRateLimited() async throws {
        let recordingID = "b9991644-7275-44db-bc43-fff6c6b4ce69"
        let searchJSON = #"{"recordings":[{"id":"b9991644-7275-44db-bc43-fff6c6b4ce69","title":"A","score":99,"artist-credit":[{"name":"B"}]}]}"#
        let lookupJSON = #"{"id":"b9991644-7275-44db-bc43-fff6c6b4ce69","isrcs":["USQE92100257"]}"#
        let transport = StubMusicBrainzTransport(responses: [
            "/recording": MusicBrainzHTTPResponse(data: Data(searchJSON.utf8), statusCode: 200),
            "/recording/\(recordingID)": MusicBrainzHTTPResponse(data: Data(lookupJSON.utf8), statusCode: 200)
        ])
        let client = MusicBrainzClient(transport: transport, minimumRequestInterval: .milliseconds(120))
        _ = try await client.searchRecordings(title: "A", artist: "B")
        _ = try await client.isrcs(forRecordingID: recordingID)
        let requestTimes = await transport.requestTimes
        XCTAssertEqual(requestTimes.count, 2)
        XCTAssertGreaterThanOrEqual(requestTimes[1].timeIntervalSince(requestTimes[0]), 0.1)
    }

    func testMusicBrainzSearchCancellationStopsPendingTransport() async throws {
        let transport = CancellationAwareTransport()
        let client = MusicBrainzClient(transport: transport, minimumRequestInterval: .zero)
        let task = Task {
            try await client.searchRecordings(title: "A", artist: "B")
        }

        for _ in 0..<100 {
            if await transport.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await transport.didStart
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
        let cancelled = await transport.wasCancelled
        XCTAssertTrue(cancelled)
    }

    func testDiagnosticLogLinesAreValidBoundedAndClearable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticsLogStore(directoryURL: directory, maximumFileBytes: 1_024, rotatedFileCount: 2)

        for index in 0..<24 {
            await store.record(
                category: "test_event",
                result: "success_\(index)",
                parameters: ["sequence": String(index), "sensitive_values_omitted": "true"]
            )
        }
        await store.record(
            category: "haptics_observer",
            result: "inactive",
            parameters: ["isrc_redacted": ISRC.redacted("USQE92100257")]
        )

        let text = await store.readAllText()
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertGreaterThan(lines.count, 0)
        XCTAssertFalse(text.contains("USQE92100257"))
        XCTAssertFalse(text.contains("Night Drive"))
        for line in lines {
            let event = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(line.utf8))
            XCTAssertNotNil(ISO8601DateFormatter().date(from: event.timestamp))
            XCTAssertFalse(event.category.isEmpty)
            XCTAssertFalse(event.result.isEmpty)
            if event.category == "test_event" {
                XCTAssertEqual(event.parameters["sensitive_values_omitted"], "true")
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("diagnostics") && $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(files.count, 3)
        let totalBytes = try files.reduce(0) { sum, url in
            sum + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(totalBytes, 3 * 1_024)
        let currentLog = directory.appendingPathComponent("diagnostics.jsonl")
        let currentSize = try currentLog.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThanOrEqual(currentSize, 1_024)

        let exportURL = try await store.exportURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        try await store.clear()
        let clearedText = await store.readAllText()
        XCTAssertEqual(clearedText, "")
    }
}

private actor StubMusicBrainzTransport: MusicBrainzTransport {
    private let responses: [String: MusicBrainzHTTPResponse]
    private(set) var requestURLs: [URL] = []
    private(set) var requestTimes: [Date] = []
    private(set) var userAgents: [String?] = []

    init(responses: [String: MusicBrainzHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        guard let url = request.url else { throw MusicBrainzClientError.invalidResponse }
        requestURLs.append(url)
        requestTimes.append(.now)
        userAgents.append(request.value(forHTTPHeaderField: "User-Agent"))
        guard let response = responses.first(where: { url.path.hasSuffix($0.key) })?.value else {
            throw MusicBrainzClientError.invalidResponse
        }
        return response
    }
}

private actor CancellationAwareTransport: MusicBrainzTransport {
    private(set) var didStart = false
    private(set) var wasCancelled = false

    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        didStart = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return MusicBrainzHTTPResponse(data: Data(#"{"recordings":[]}"#.utf8), statusCode: 200)
    }
}
