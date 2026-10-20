import Foundation

struct MusicBrainzHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol MusicBrainzTransport: Sendable {
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse
}

struct URLSessionMusicBrainzTransport: MusicBrainzTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicBrainzClientError.invalidResponse
        }
        return MusicBrainzHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

enum MusicBrainzClientError: Error, Equatable {
    case emptyQuery
    case queryTooLong
    case invalidRecordingID
    case invalidResponse
    case httpStatus(Int)

    var userMessage: String {
        switch self {
        case .emptyQuery: return "Enter both a recording title and artist."
        case .queryTooLong: return "The title or artist text is too long to search."
        case .invalidRecordingID: return "This MusicBrainz recording identifier is invalid."
        case .invalidResponse: return "MusicBrainz returned data this prototype could not read."
        case .httpStatus(503): return "MusicBrainz is temporarily busy. Wait before trying again."
        case .httpStatus(let code): return "MusicBrainz request failed (HTTP \(code))."
        }
    }
}

struct RecordingCandidate: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let artistCredit: String
    let serverRelevanceScore: Int?
    let lengthMilliseconds: Int?
    let matchEvidence: [String]
}

actor MusicBrainzClient {
    static let shared = MusicBrainzClient()

    private let transport: any MusicBrainzTransport
    private let baseURL: URL
    private let minimumRequestInterval: Duration
    private let cacheLifetime: TimeInterval
    private let clock = ContinuousClock()
    private var nextRequestStart: ContinuousClock.Instant?
    private var searchCache: [String: (expiresAt: Date, candidates: [RecordingCandidate])] = [:]
    private var isrcCache: [String: (expiresAt: Date, codes: [String])] = [:]

    init(
        transport: any MusicBrainzTransport = URLSessionMusicBrainzTransport(),
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!,
        minimumRequestInterval: Duration = .seconds(1),
        cacheLifetime: TimeInterval = 6 * 60 * 60
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.minimumRequestInterval = minimumRequestInterval
        self.cacheLifetime = cacheLifetime
    }

    func searchRecordings(
        title: String,
        artist: String,
        expectedDuration: TimeInterval? = nil
    ) async throws -> [RecordingCandidate] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty else { throw MusicBrainzClientError.emptyQuery }
        guard cleanTitle.count <= 200, cleanArtist.count <= 200 else { throw MusicBrainzClientError.queryTooLong }

        let cacheKey = "\(Self.normalizedForMatching(cleanTitle))|\(Self.normalizedForMatching(cleanArtist))"
        if let cached = searchCache[cacheKey], cached.expiresAt > .now {
            return Self.addDurationEvidence(cached.candidates, expectedDuration: expectedDuration)
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("recording"), resolvingAgainstBaseURL: false)!
        let query = "recording:\"\(Self.escapeLucene(cleanTitle))\" AND artist:\"\(Self.escapeLucene(cleanArtist))\""
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { throw MusicBrainzClientError.invalidResponse }

        let response = try await request(url: url)
        let payload: RecordingSearchPayload
        do {
            payload = try JSONDecoder().decode(RecordingSearchPayload.self, from: response.data)
        } catch {
            throw MusicBrainzClientError.invalidResponse
        }

        let candidates = payload.recordings.map { recording in
            let creditedArtist = (recording.artistCredit ?? []).map { entry in
                (entry.name ?? entry.artist?.name ?? "") + (entry.joinphrase ?? "")
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return RecordingCandidate(
                id: recording.id,
                title: recording.title,
                artistCredit: creditedArtist.isEmpty ? "Unknown artist" : creditedArtist,
                serverRelevanceScore: recording.score,
                lengthMilliseconds: recording.length,
                matchEvidence: Self.matchEvidence(
                    candidateTitle: recording.title,
                    candidateArtist: creditedArtist,
                    requestedTitle: cleanTitle,
                    requestedArtist: cleanArtist
                )
            )
        }
        searchCache[cacheKey] = (.now.addingTimeInterval(cacheLifetime), candidates)
        return Self.addDurationEvidence(candidates, expectedDuration: expectedDuration)
    }

    func isrcs(forRecordingID recordingID: String) async throws -> [String] {
        let id = recordingID.lowercased()
        guard UUID(uuidString: id) != nil else { throw MusicBrainzClientError.invalidRecordingID }
        if let cached = isrcCache[id], cached.expiresAt > .now {
            return cached.codes
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("recording").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "inc", value: "isrcs"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { throw MusicBrainzClientError.invalidResponse }
        let response = try await request(url: url)
        let payload: RecordingLookupPayload
        do {
            payload = try JSONDecoder().decode(RecordingLookupPayload.self, from: response.data)
        } catch {
            throw MusicBrainzClientError.invalidResponse
        }
        let codes = Array(Set((payload.isrcs ?? []).compactMap(ISRC.normalized))).sorted()
        isrcCache[id] = (.now.addingTimeInterval(cacheLifetime), codes)
        return codes
    }

    private func request(url: URL) async throws -> MusicBrainzHTTPResponse {
        let now = clock.now
        let scheduledStart = max(now, nextRequestStart ?? now)
        nextRequestStart = scheduledStart.advanced(by: minimumRequestInterval)
        if scheduledStart > now {
            try await clock.sleep(until: scheduledStart)
        }
        try Task.checkCancellation()

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PrimuseMusicHapticsProbe/0.2.0 (https://github.com/lieyanbang/primuse)", forHTTPHeaderField: "User-Agent")

        let response = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw MusicBrainzClientError.httpStatus(response.statusCode)
        }
        return response
    }

    private static func matchEvidence(
        candidateTitle: String,
        candidateArtist: String,
        requestedTitle: String,
        requestedArtist: String
    ) -> [String] {
        let titleMatch = normalizedForMatching(candidateTitle) == normalizedForMatching(requestedTitle)
        let artistMatch = normalizedForMatching(candidateArtist) == normalizedForMatching(requestedArtist)
        var evidence: [String] = []
        evidence.append(titleMatch ? "Title matches exactly after case/diacritic folding" : "Title differs from the entered title")
        evidence.append(artistMatch ? "Artist credit matches exactly after case/diacritic folding" : "Artist credit differs from the entered artist")
        return evidence
    }

    private static func addDurationEvidence(
        _ candidates: [RecordingCandidate],
        expectedDuration: TimeInterval?
    ) -> [RecordingCandidate] {
        guard let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 else { return candidates }
        return candidates.map { candidate in
            guard let milliseconds = candidate.lengthMilliseconds else { return candidate }
            let difference = abs(Double(milliseconds) / 1_000 - expectedDuration)
            let evidence = difference <= 2
                ? "Duration within 2 seconds"
                : "Duration differs by \(Int(difference.rounded())) seconds"
            return RecordingCandidate(
                id: candidate.id,
                title: candidate.title,
                artistCredit: candidate.artistCredit,
                serverRelevanceScore: candidate.serverRelevanceScore,
                lengthMilliseconds: candidate.lengthMilliseconds,
                matchEvidence: candidate.matchEvidence + [evidence]
            )
        }
    }

    private static func normalizedForMatching(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func escapeLucene(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct RecordingSearchPayload: Decodable {
    let recordings: [RecordingPayload]
}

private struct RecordingLookupPayload: Decodable {
    let isrcs: [String]?
}

private struct RecordingPayload: Decodable {
    let id: String
    let title: String
    let score: Int?
    let length: Int?
    let artistCredit: [ArtistCreditPayload]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case score
        case length
        case artistCredit = "artist-credit"
    }
}

private struct ArtistCreditPayload: Decodable {
    let name: String?
    let joinphrase: String?
    let artist: ArtistPayload?
}

private struct ArtistPayload: Decodable {
    let name: String?
}
