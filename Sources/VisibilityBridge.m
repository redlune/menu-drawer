#import "VisibilityBridge.h"
#import <dlfcn.h>

// Typed declarations for messages sent to classes resolved at runtime.
@protocol MenuBarConfiguration
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                   allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end

@protocol MenuBarAssertion
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError * _Nullable))completion;
- (void)invalidate;
@end

@implementation VisibilityBridge

static Class configurationClass;
static Class assertionClass;

+ (BOOL)isAvailable {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/Versions/A/MenuBarClientCore";
        if (!dlopen(path, RTLD_LOCAL | RTLD_NOW)) {
            return;
        }
        configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    });
    return [configurationClass instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertionClass instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertionClass instancesRespondToSelector:@selector(invalidate)];
}

+ (NSObject *)restrictToBundles:(NSArray<NSString *> *)bundles
    completion:(void (^)(NSError * _Nullable))completion {
    if (![self isAvailable]) {
        return nil;
    }

    NSMutableArray<NSNumber *> *systemItems = [NSMutableArray arrayWithCapacity:256];
    for (NSInteger item = 0; item < 256; item++) {
        [systemItems addObject:@(item)];
    }

    NSObject<MenuBarAssertion> *assertion = nil;
    @try {
        id<MenuBarConfiguration> configuration = (id)[configurationClass alloc];
        configuration = [configuration initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:bundles];
        assertion = (id)[[assertionClass alloc] init];
        if (!configuration || !assertion) {
            return nil;
        }

        [assertion activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }];
        return assertion;
    } @catch (NSException *exception) {
        if (assertion) {
            [self restore:assertion];
        }
        NSLog(@"Menu bar visibility activation failed: %@", exception.name);
        return nil;
    }
}

+ (void)restore:(NSObject *)token {
    @try {
        [(id<MenuBarAssertion>)token invalidate];
    } @catch (NSException *exception) {
        NSLog(@"Menu bar visibility restoration failed: %@", exception.name);
    }
}

@end
