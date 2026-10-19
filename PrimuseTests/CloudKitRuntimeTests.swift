import XCTest
@testable import Primuse

final class CloudKitRuntimeTests: XCTestCase {
    func testUnsignedPrototypeBuildDisablesCloudKitBeforeContainerCreation() throws {
        guard CloudKitRuntime.isCloudKitDisabledForUnsignedPrototype else {
            throw XCTSkip("This test requires the unsigned iOS prototype compilation condition.")
        }

        XCTAssertFalse(CloudKitRuntime.canCreateContainer)
        XCTAssertNil(CloudKitRuntime.makeContainer())
        XCTAssertNil(CloudKitRuntime.makeContainer())
    }

    func testPreflightDenialDoesNotCallFactoryOrRetry() {
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0
        let reason = "CloudKit is disabled by the unsigned iOS prototype build configuration."

        let first = resolution.resolve(preflightFailureReason: reason) {
            constructionCount += 1
            return ("unexpected container", nil)
        }
        let second = resolution.resolve {
            constructionCount += 1
            return ("unexpected retry", nil)
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(constructionCount, 0)
        XCTAssertEqual(resolution.failureReason, reason)
    }

    func testAllowedResolutionCachesOneContainerForRepeatedStartupRequests() {
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let first = resolution.resolve {
            constructionCount += 1
            return ("authorized container", nil)
        }
        let second = resolution.resolve {
            constructionCount += 1
            return ("unexpected second container", nil)
        }

        XCTAssertEqual(first, "authorized container")
        XCTAssertEqual(second, "authorized container")
        XCTAssertEqual(constructionCount, 1)
    }

    func testSimulatorProtectionRemainsEnabled() throws {
        #if targetEnvironment(simulator)
        XCTAssertFalse(CloudKitRuntime.canCreateContainer)
        XCTAssertNil(CloudKitRuntime.makeContainer())
        #else
        throw XCTSkip("Simulator-only protection check.")
        #endif
    }

    func testNormalBuildDoesNotEnablePrototypeDisableFlag() {
        #if os(macOS)
        XCTAssertFalse(CloudKitRuntime.isCloudKitDisabledForUnsignedPrototype)
        #endif
    }
}
