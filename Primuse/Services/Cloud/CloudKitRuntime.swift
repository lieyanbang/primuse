import CloudKit
import Foundation

#if os(macOS)
import Security
#endif

/// Owns the only CloudKit container-construction path in the app.
enum CloudKitRuntime {
    static let containerID = "iCloud.com.welape.yuanyin"

    private static let resolution = CloudKitContainerResolution<CKContainer>()
    private static let diagnostics = CloudKitRuntimeDiagnostics()

    /// The unsigned iOS prototype intentionally omits CloudKit because its
    /// eventual signing identity is not known at build time.
    static var isCloudKitDisabledForUnsignedPrototype: Bool {
        #if os(iOS) && PRIMUSE_CLOUDKIT_DISABLED_FOR_UNSIGNED_PROTOTYPE
        true
        #else
        false
        #endif
    }

    static var canCreateContainer: Bool {
        if let failureReason = resolution.failureReason {
            diagnostics.logOnce(failureReason)
            return false
        }
        guard let failureReason = preflightFailureReason else { return true }
        diagnostics.logOnce(failureReason)
        return false
    }

    static func makeContainer() -> CKContainer? {
        let container = resolution.resolve(preflightFailureReason: preflightFailureReason) {
            (CKContainer(identifier: containerID), nil)
        }
        if container == nil, let failureReason = resolution.failureReason {
            diagnostics.logOnce(failureReason)
        }
        return container
    }

    private static var preflightFailureReason: String? {
        if isCloudKitDisabledForUnsignedPrototype {
            return "CloudKit is disabled by the unsigned iOS prototype build configuration."
        }

        #if targetEnvironment(simulator)
        return "CloudKit container initialization is disabled in Simulator builds."
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else {
            return "SecTaskCreateFromSelf could not read effective macOS entitlements."
        }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) else {
            return "The effective macOS CloudKit container entitlement is missing or unreadable."
        }
        guard let identifiers = value as? [String] else {
            return "The effective macOS CloudKit container entitlement is not a string array."
        }
        guard identifiers.contains(containerID) else {
            return "The effective macOS CloudKit container entitlement does not include \(containerID)."
        }
        return nil
        #else
        // iOS does not provide a supported runtime API to inspect its effective
        // entitlements. Signed production builds retain the existing CloudKit
        // path; unsigned prototypes set the compile-time gate above.
        return nil
        #endif
    }
}

/// Caches an allowed container or a denial so concurrent startup and later
/// CloudKit entry points cannot repeatedly construct or retry it.
final class CloudKitContainerResolution<Value>: @unchecked Sendable {
    private enum State {
        case notAttempted
        case created(Value)
        case failed(String)
    }

    private let lock = NSLock()
    private var state: State = .notAttempted

    var failureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        if case .failed(let reason) = state { return reason }
        return nil
    }

    func resolve(
        preflightFailureReason: String? = nil,
        create: () -> (Value?, String?)
    ) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .notAttempted:
            if let preflightFailureReason {
                state = .failed(preflightFailureReason)
                return nil
            }
            let (value, failureReason) = create()
            if let value {
                state = .created(value)
                return value
            }
            state = .failed(
                failureReason ?? "CloudKit container creation failed without a diagnostic."
            )
            return nil
        case .created(let value):
            return value
        case .failed:
            return nil
        }
    }
}

private final class CloudKitRuntimeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var loggedReasons = Set<String>()

    func logOnce(_ reason: String) {
        lock.lock()
        let shouldLog = loggedReasons.insert(reason).inserted
        lock.unlock()
        if shouldLog { plog("⚠️ CloudKitRuntime: \(reason)") }
    }
}
