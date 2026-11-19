#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VisibilityBridge : NSObject
+ (BOOL)isAvailable;
+ (nullable NSObject *)restrictToBundles:(NSArray<NSString *> *)bundles
    completion:(void (^)(NSError * _Nullable error))completion;
+ (void)restore:(NSObject *)token;
@end

NS_ASSUME_NONNULL_END
