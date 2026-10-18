import CloudKit
import Foundation

#if os(macOS)
import Security
#endif

/// Runtime policy for constructing the CloudKit container.
///
/// iOS does not expose a supported API for reading the running process's
/// effective entitlements. iOS therefore keeps CloudKit enabled and attempts
/// the initializer behind an Objective-C exception boundary. Simulator builds
/// remain disabled, while macOS checks the effective signing entitlements.
enum CloudKitRuntime {
    static let containerID = "iCloud.com.welape.yuanyin"

    private static let resolution = CloudKitContainerResolution<CKContainer>()
    private static let diagnostics = CloudKitRuntimeDiagnostics()

    static var canCreateContainer: Bool {
        if resolution.failureReason != nil { return false }
        return currentPreflightFailureReason == nil
    }

    static func makeContainer() -> CKContainer? {
        if let failureReason = resolution.failureReason {
            diagnostics.logOnce(failureReason)
            return nil
        }

        if let failureReason = currentPreflightFailureReason {
            _ = resolution.resolve(preflightFailureReason: failureReason) { (nil, nil) }
            diagnostics.logOnce(failureReason)
            return nil
        }

        #if os(iOS)
        diagnostics.logOnce(
            "iOS has no supported runtime entitlement query; attempting guarded " +
                "CloudKit container initialization for \(containerID)."
        )
        #endif

        let container = resolution.resolve {
            var failureReason: NSString?
            let result = PRPerformObjCBlockCatchingException({
                CKContainer(identifier: containerID)
            }, &failureReason)
            let container = result as? CKContainer
            if let container {
                return (container, nil)
            }
            return (
                nil,
                (failureReason as String?) ?? "CloudKit container initialization returned nil."
            )
        }
        if container == nil, let failureReason = resolution.failureReason {
            diagnostics.logOnce(failureReason)
        }
        return container
    }

    private static var currentPreflightFailureReason: String? {
        #if targetEnvironment(simulator)
        CloudKitEntitlementPolicy.failureReason(
            platform: .simulator,
            containerID: containerID,
            entitlements: nil
        )
        #elseif os(macOS)
        let readResult = readEffectiveMacOSEntitlements()
        guard let entitlements = readResult.entitlements else {
            return "Unable to read effective macOS CloudKit entitlements: " +
                (readResult.failureReason ?? "unknown entitlement read failure")
        }
        return CloudKitEntitlementPolicy.failureReason(
            platform: .macOS,
            containerID: containerID,
            entitlements: entitlements
        )
        #elseif os(tvOS)
        nil
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func readEffectiveMacOSEntitlements() -> (
        entitlements: [String: [String]]?,
        failureReason: String?
    ) {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return (nil, "SecTaskCreateFromSelf returned nil.")
        }

        let entitlementKeys = [
            CloudKitEntitlementPolicy.containerIdentifiersEntitlement,
            CloudKitEntitlementPolicy.servicesEntitlement
        ]
        var entitlements: [String: [String]] = [:]

        for key in entitlementKeys {
            var error: Unmanaged<CFError>?
            guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error) else {
                if let error {
                    return (nil, error.takeRetainedValue().localizedDescription)
                }
                entitlements[key] = []
                continue
            }
            guard let values = value as? [String] else {
                return (nil, "The effective \(key) entitlement is not a string array.")
            }
            entitlements[key] = values
        }

        return (entitlements, nil)
    }
    #endif
}

/// Pure authorization policy so signing and platform branches can be tested
/// without creating a real CloudKit container.
enum CloudKitEntitlementPolicy {
    static let containerIdentifiersEntitlement = "com.apple.developer.icloud-container-identifiers"
    static let servicesEntitlement = "com.apple.developer.icloud-services"

    enum Platform: Equatable {
        case simulator
        case iOS
        case macOS
    }

    static func failureReason(
        platform: Platform,
        containerID: String,
        entitlements: [String: [String]]?
    ) -> String? {
        switch platform {
        case .simulator:
            return "CloudKit container initialization is disabled in Simulator builds."
        case .iOS:
            // No supported public API exposes effective iOS process entitlements.
            // Preserve CloudKit behavior and let the guarded initializer decide.
            return nil
        case .macOS:
            guard let entitlements else {
                return "Effective macOS CloudKit entitlements could not be read."
            }
            guard let containers = entitlements[containerIdentifiersEntitlement] else {
                return "The effective CloudKit container identifier entitlement is missing."
            }
            guard containers.contains(containerID) else {
                return "The effective CloudKit container entitlement does not include \(containerID)."
            }
            guard let services = entitlements[servicesEntitlement] else {
                return "The effective iCloud services entitlement is missing."
            }
            guard services.contains("CloudKit") else {
                return "The effective iCloud services entitlement does not include CloudKit."
            }
            return nil
        }
    }
}

/// Caches both successful and failed initialization so all CloudKit call sites
/// share one container and a denied build cannot retry on every launch hook.
final class CloudKitContainerResolution<Value>: @unchecked Sendable {
    private enum State {
        case notAttempted
        case created(Value)
        case failed(String)
    }

    private let lock = NSLock()
    private var state: State = .notAttempted

    var failureReason: String? {
        lock.withLock {
            if case .failed(let reason) = state { return reason }
            return nil
        }
    }

    func resolve(
        preflightFailureReason: String? = nil,
        create: () -> (Value?, String?)
    ) -> Value? {
        lock.withLock {
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
                let reason = failureReason ?? "CloudKit container initialization failed without a diagnostic."
                state = .failed(reason)
                return nil
            case .created(let value):
                return value
            case .failed:
                return nil
            }
        }
    }

}

private final class CloudKitRuntimeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var loggedReasons = Set<String>()

    func logOnce(_ reason: String) {
        let shouldLog = lock.withLock { loggedReasons.insert(reason).inserted }
        if shouldLog { plog("⚠️ CloudKitRuntime: \(reason)") }
    }
}
