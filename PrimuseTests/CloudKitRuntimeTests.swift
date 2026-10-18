import XCTest
@testable import Primuse

final class CloudKitRuntimeTests: XCTestCase {
    private let containerID = "iCloud.com.welape.yuanyin"

    func testValidMacOSEntitlementsAllowOneSuccessfulContainerCreation() {
        let entitlements = [
            CloudKitEntitlementPolicy.containerIdentifiersEntitlement: [containerID],
            CloudKitEntitlementPolicy.servicesEntitlement: ["CloudKit"]
        ]
        let failure = CloudKitEntitlementPolicy.failureReason(
            platform: .macOS,
            containerID: containerID,
            entitlements: entitlements
        )
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let first = resolution.resolve(preflightFailureReason: failure) {
            constructionCount += 1
            return ("container", nil)
        }
        let second = resolution.resolve(preflightFailureReason: failure) {
            constructionCount += 1
            return ("unexpected second container", nil)
        }

        XCTAssertNil(failure)
        XCTAssertEqual(first, "container")
        XCTAssertEqual(second, "container")
        XCTAssertEqual(constructionCount, 1)
    }

    func testMissingContainerEntitlementBlocksConstruction() {
        assertMacOSEntitlementsBlock(
            [CloudKitEntitlementPolicy.servicesEntitlement: ["CloudKit"]],
            reasonContains: "container identifier entitlement is missing"
        )
    }

    func testMismatchedContainerIdentifierBlocksConstruction() {
        assertMacOSEntitlementsBlock(
            [
                CloudKitEntitlementPolicy.containerIdentifiersEntitlement: ["iCloud.com.other.app"],
                CloudKitEntitlementPolicy.servicesEntitlement: ["CloudKit"]
            ],
            reasonContains: "does not include \(containerID)"
        )
    }

    func testMissingCloudKitServiceEntitlementBlocksConstruction() {
        assertMacOSEntitlementsBlock(
            [CloudKitEntitlementPolicy.containerIdentifiersEntitlement: [containerID]],
            reasonContains: "iCloud services entitlement is missing"
        )
    }

    func testCloudKitServiceMismatchBlocksConstruction() {
        assertMacOSEntitlementsBlock(
            [
                CloudKitEntitlementPolicy.containerIdentifiersEntitlement: [containerID],
                CloudKitEntitlementPolicy.servicesEntitlement: ["CloudDocuments"]
            ],
            reasonContains: "does not include CloudKit"
        )
    }

    func testEntitlementReadFailureBlocksMacOSConstruction() {
        let reason = CloudKitEntitlementPolicy.failureReason(
            platform: .macOS,
            containerID: containerID,
            entitlements: nil
        )
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let result = resolution.resolve(preflightFailureReason: reason) {
            constructionCount += 1
            return ("must not construct", nil)
        }

        XCTAssertNil(result)
        XCTAssertEqual(constructionCount, 0)
        XCTAssertEqual(resolution.failureReason, "Effective macOS CloudKit entitlements could not be read.")
    }

    func testSimulatorPolicyBlocksConstruction() {
        let reason = CloudKitEntitlementPolicy.failureReason(
            platform: .simulator,
            containerID: containerID,
            entitlements: nil
        )
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let result = resolution.resolve(preflightFailureReason: reason) {
            constructionCount += 1
            return ("must not construct", nil)
        }

        XCTAssertNil(result)
        XCTAssertEqual(constructionCount, 0)
        XCTAssertTrue(resolution.failureReason?.contains("Simulator") == true)
    }

    func testIOSWithoutEntitlementQueryKeepsCloudKitAttemptAvailable() {
        let failure = CloudKitEntitlementPolicy.failureReason(
            platform: .iOS,
            containerID: containerID,
            entitlements: nil
        )
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let result = resolution.resolve(preflightFailureReason: failure) {
            constructionCount += 1
            return ("guarded iOS container", nil)
        }

        XCTAssertNil(failure)
        XCTAssertEqual(result, "guarded iOS container")
        XCTAssertEqual(constructionCount, 1)
    }

    func testFailedContainerCreationIsCachedAndDoesNotRetry() {
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let first = resolution.resolve {
            constructionCount += 1
            return (nil, "Objective-C exception: entitlement mismatch")
        }
        let second = resolution.resolve {
            constructionCount += 1
            return ("must not retry", nil)
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(constructionCount, 1)
        XCTAssertEqual(resolution.failureReason, "Objective-C exception: entitlement mismatch")
    }

    private func assertMacOSEntitlementsBlock(
        _ entitlements: [String: [String]],
        reasonContains expectedReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reason = CloudKitEntitlementPolicy.failureReason(
            platform: .macOS,
            containerID: containerID,
            entitlements: entitlements
        )
        let resolution = CloudKitContainerResolution<String>()
        var constructionCount = 0

        let result = resolution.resolve(preflightFailureReason: reason) {
            constructionCount += 1
            return ("must not construct", nil)
        }

        XCTAssertNil(result, file: file, line: line)
        XCTAssertEqual(constructionCount, 0, file: file, line: line)
        XCTAssertTrue(reason?.contains(expectedReason) == true, file: file, line: line)
    }
}
