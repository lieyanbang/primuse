#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT id _Nullable PRPerformObjCBlockCatchingException(
    id _Nullable (^block)(void),
    NSString * _Nullable * _Nullable failureReason
);

NS_ASSUME_NONNULL_END
