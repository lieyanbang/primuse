import Foundation
import MediaPlayer

enum NowPlayingPayload {
    static func make(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        playbackRate: Double,
        confirmedISRC: String?
    ) -> [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Local audio" : title,
            MPMediaItemPropertyArtist: artist.isEmpty ? "Unknown artist" : artist,
            MPMediaItemPropertyPlaybackDuration: max(0, duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        if !album.isEmpty {
            result[MPMediaItemPropertyAlbumTitle] = album
        }
        if let confirmedISRC, ISRC.normalized(confirmedISRC) != nil {
            result[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = ISRC.normalized(confirmedISRC)
        }
        return result
    }

    static func fieldNames(in information: [String: Any]?) -> [String] {
        guard let information else { return [] }
        let known: [(String, String)] = [
            (MPMediaItemPropertyTitle, "Title"),
            (MPMediaItemPropertyArtist, "Artist"),
            (MPMediaItemPropertyAlbumTitle, "Album"),
            (MPMediaItemPropertyPlaybackDuration, "Duration"),
            (MPNowPlayingInfoPropertyElapsedPlaybackTime, "Elapsed time"),
            (MPNowPlayingInfoPropertyPlaybackRate, "Playback rate"),
            (MPNowPlayingInfoPropertyInternationalStandardRecordingCode, "ISRC")
        ]
        return known.compactMap { information[$0.0] == nil ? nil : $0.1 }
    }
}
