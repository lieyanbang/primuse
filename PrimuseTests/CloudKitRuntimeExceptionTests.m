#import <XCTest/XCTest.h>
#import "../Primuse/Services/Cloud/CloudKitContainerExceptionCatcher.h"

@interface CloudKitRuntimeExceptionTests : XCTestCase
@end

@implementation CloudKitRuntimeExceptionTests

- (void)testObjectiveCExceptionIsReturnedAsFailureInsteadOfEscaping {
    NSString *failureReason = nil;
    id result = PRPerformObjCBlockCatchingException(^id {
        @throw [NSException exceptionWithName:@"CloudKitEntitlementException"
                                       reason:@"container is not authorized"
                                     userInfo:nil];
    }, &failureReason);

    XCTAssertNil(result);
    XCTAssertTrue([failureReason containsString:@"CloudKitEntitlementException"]);
    XCTAssertTrue([failureReason containsString:@"container is not authorized"]);
}

- (void)testSuccessfulObjectiveCBlockReturnsItsValue {
    NSString *failureReason = nil;
    id result = PRPerformObjCBlockCatchingException(^id {
        return @"container created";
    }, &failureReason);

    XCTAssertEqualObjects(result, @"container created");
    XCTAssertNil(failureReason);
}

@end
