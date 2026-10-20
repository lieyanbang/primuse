import AVFoundation
import Foundation

enum MetadataFieldSource: String, Codable, Equatable, Sendable {
    case embedded = "Embedded file metadata"
    case audioFile = "Audio file (AVFoundation)"
    case fileName = "File name"
    case manual = "Manually edited"
    case musicBrainz = "MusicBrainz, user confirmed"
    case missing = "Missing"
}

struct MetadataField: Equatable, Sendable {
    var value: String?
    var source: MetadataFieldSource

    static let missing = MetadataField(value: nil, source: .missing)
}

struct ImportedAudioMetadata: Equatable, Sendable {
    var title: MetadataField = .missing
    var artist: MetadataField = .missing
    var album: MetadataField = .missing
    var isrc: MetadataField = .missing
    var duration: TimeInterval?
}

enum AudioMetadataReader {
    static func read(from url: URL) async throws -> ImportedAudioMetadata {
        let asset = AVURLAsset(url: url)
        let (commonItems, allItems, duration) = try await asset.load(.commonMetadata, .metadata, .duration)

        let title = await stringValue(in: commonItems, identifier: .commonIdentifierTitle)
        let artist = await stringValue(in: commonItems, identifier: .commonIdentifierArtist)
        let album = await stringValue(in: commonItems, identifier: .commonIdentifierAlbumName)
        let isrc = await stringValue(in: allItems, identifier: .id3MetadataInternationalStandardRecordingCode)
            ?? stringValue(in: allItems, containingIdentifier: "isrc")

        let seconds = CMTimeGetSeconds(duration)
        return ImportedAudioMetadata(
            title: title.map { MetadataField(value: $0, source: .embedded) } ?? .missing,
            artist: artist.map { MetadataField(value: $0, source: .embedded) } ?? .missing,
            album: album.map { MetadataField(value: $0, source: .embedded) } ?? .missing,
            isrc: isrc.map { MetadataField(value: $0, source: .embedded) } ?? .missing,
            duration: seconds.isFinite && seconds > 0 ? seconds : nil
        )
    }

    private static func stringValue(
        in items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        for item in items where item.identifier == identifier {
            if let value = try? await item.load(.stringValue), let cleaned = clean(value) {
                return cleaned
            }
        }
        return nil
    }

    private static func stringValue(
        in items: [AVMetadataItem],
        containingIdentifier fragment: String
    ) async -> String? {
        for item in items {
            guard item.identifier?.rawValue.localizedCaseInsensitiveContains(fragment) == true else { continue }
            if let value = try? await item.load(.stringValue), let cleaned = clean(value) {
                return cleaned
            }
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
