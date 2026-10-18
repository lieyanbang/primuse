#import "CloudKitContainerExceptionCatcher.h"

id _Nullable PRPerformObjCBlockCatchingException(
    id _Nullable (^block)(void),
    NSString * _Nullable * _Nullable failureReason
) {
    @try {
        return block();
    } @catch (NSException *exception) {
        if (failureReason != NULL) {
            NSString *reason = exception.reason ?: @"No exception reason was provided.";
            *failureReason = [NSString stringWithFormat:@"%@ raised: %@", exception.name, reason];
        }
        return nil;
    }
}
