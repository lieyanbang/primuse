import Foundation

enum PlaybackState: String, Equatable, Sendable {
    case stopped
    case playing
    case paused
    case interrupted
    case finished
    case failed

    var label: String { rawValue.capitalized }
}

enum PlaybackEvent: Equatable, Sendable {
    case playSucceeded
    case pause
    case stop
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case playbackEnded
    case failure
}

extension PlaybackState {
    func applying(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .playSucceeded:
            return .playing
        case .pause:
            return self == .playing || self == .interrupted ? .paused : self
        case .stop:
            return .stopped
        case .interruptionBegan:
            return self == .playing ? .interrupted : self
        case .interruptionEnded(let shouldResume):
            guard self == .interrupted else { return self }
            return shouldResume ? .playing : .paused
        case .playbackEnded:
            return .finished
        case .failure:
            return .failed
        }
    }
}
