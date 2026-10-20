# Primuse Music Haptics Probe v0.2

This remains a standalone iOS app target. It does not load the full Primuse app, app services, packages, entitlements, extensions, or startup path.

## Build and package

Generate `MusicHapticsProbe.xcodeproj` with XcodeGen 2.44.1. The dedicated GitHub Actions workflow runs the unit tests on an iOS Simulator, builds and archives for iOS Device without signing, validates the built app, and packages an unsigned IPA named `primuse-music-haptics-probe-<HHMM>.ipa`. `HHMM` is the actual package step time in Australia/Brisbane. The IPA requires manual signing and cannot be installed as downloaded.

The app uses bundle identifier `com.welape.primuse.musichapticsprobe` and home screen name `Primuse`; its screen is labeled **MUSIC HAPTICS PROTOTYPE**. The committed and built `Info.plist` declares Boolean `MusicHapticsSupported=true`, enables Files access for `Documents`, and adds no entitlements. It enables only the `audio` background mode so local playback and lock-screen remote commands can continue across device lock, as Apple requires for background audio playback.

## Investigation behavior

The probe keeps the existing `AVAudioPlayer` path. It logs, but does not infer the cause of inactive native haptics from track availability alone. The UI and JSONL events report audio-session activation and route type, play/pause/seek/interruption/end transitions, the field names present in the `MPNowPlayingInfoCenter` snapshot, ISRC confirmation state, track availability, and the `MAMusicHapticsManager` observer callback.

Track availability and actual haptic playback are separate system signals. The user must confirm the ISRC before the probe includes it in Now Playing. A confirmed MusicBrainz result is still a candidate selected by the user; a relevance score is not proof that the recording or master is correct.

## Metadata and MusicBrainz

AVFoundation reads title, artist, album, duration, and an ID3 ISRC when present. The screen reports each field’s source or that it is missing. A missing or invalid ISRC can be corrected manually. MusicBrainz search uses its public HTTPS JSON API with a descriptive User-Agent, at most one request per second, request cancellation, timeout handling, and an in-memory result cache. It needs no API key. Searches and MBID lookups are read-only.

## Logs and privacy

JSON Lines logs are stored in `Documents/Diagnostics`, with a 256 KiB current file and three rotated files. The in-app log view can inspect, copy, export, or clear them. `UIFileSharingEnabled` and `LSSupportsOpeningInPlace` expose Documents in Files. Events include ISO 8601 timestamps, category, result, and bounded parameters. They do not store recording title, artist, imported filename, full ISRC, MusicBrainz search text, or raw error messages. ISRC values in logs are redacted.

## iPhone check

1. Sign the IPA using the existing signing workflow and install it. Record the final Bundle ID if the signing tool changes it.
2. Check **Settings → Accessibility → Music Haptics** and confirm the probe appears in the supported-app list.
3. Turn Music Haptics on, import a local file, inspect metadata sources, and verify the recording’s ISRC independently.
4. Confirm the ISRC in the probe, play the recording, then inspect the audio-session state, Now Playing fields, track-availability result, callback contents, and callback time.
5. Test lock-screen play/pause/seek, interruption/resumption, and logs in Files. Only claim native playback after the system observer and physical device confirm it for a known recording.

## Frameworks and migration

The prototype directly uses SwiftUI, Foundation, UIKit (clipboard UI), AVFoundation, MediaAccessibility, MediaPlayer, and UniformTypeIdentifiers. It has no third-party packages, background modes, CloudKit, Siri/Intents, AppIntents, Watch app, Widget, or extra entitlements. After device validation, migrate only the proven Music Haptics declaration/observation, metadata ISRC handling, and Now Playing publication into the formal Primuse playback path.

## Apple and MusicBrainz references

- [Apple Music Haptics](https://developer.apple.com/documentation/mediaaccessibility/music-haptics)
- [MAMusicHapticsManager](https://developer.apple.com/documentation/mediaaccessibility/mamusichapticsmanager)
- [MPNowPlayingInfoPropertyInternationalStandardRecordingCode](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyinternationalstandardrecordingcode)
- [Apple AVAsset metadata loading](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [MusicBrainz rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)
