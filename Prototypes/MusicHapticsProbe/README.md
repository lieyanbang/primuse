# Primuse Music Haptics Probe

This is a standalone iOS app target for checking Apple's native Music Haptics path. It does not load the Primuse app target or its services, packages, extensions, entitlements, or startup code.

## Build

From this directory, generate the Xcode project with XcodeGen 2.44.1 and build the `MusicHapticsProbe` scheme for a generic iOS device. The dedicated GitHub Actions workflow performs the unsigned device build, archive validation, and unsigned IPA packaging.

The installed app uses the stable bundle identifier `com.welape.primuse.musichapticsprobe` and the home screen name `Primuse`. Its first screen is clearly labeled **MUSIC HAPTICS PROTOTYPE**. The build has no signing identity or entitlements. The IPA is a signing handoff and cannot be installed as downloaded.

## iPhone check

1. Sign the IPA using the existing signing workflow, confirm its final app `Info.plist` still contains Boolean `MusicHapticsSupported=true`, then install it. If a signing tool changes the bundle identifier, record the final identifier shown in Diagnostics.
2. Open **Settings → Accessibility → Music Haptics** and check whether Primuse appears in the supported apps list. The app list check does not require audio playback.
3. Enable Music Haptics, open the prototype, and confirm the system setting status follows changes made in Settings.
4. Import a local recording, enter its real ISRC only after verifying it, and check availability. The prototype sends a valid ISRC to `MPNowPlayingInfoCenter` and Apple’s Music Haptics manager; it never invents one.
5. Play that recording and observe the separate track availability and native haptic playback status. A `true` availability result alone does not prove physical haptics; confirm on the iPhone with a recording known to have a native haptic track.

## Included frameworks

The target links AVFoundation, MediaAccessibility, MediaPlayer, Observation, and UniformTypeIdentifiers, plus SwiftUI and Foundation. It has no third-party packages, background modes, CloudKit, Siri/Intents, app extensions, Watch app, or Widget.

## Migration after validation

After device acceptance, carry only the validated Music Haptics declaration, setting observer, Now Playing ISRC publishing, availability query, and playback status observer into the formal Primuse playback path. Keep the isolated probe available for repeatable system integration checks.
