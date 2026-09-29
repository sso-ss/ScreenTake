#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryBlock:(void(NS_NOESCAPE ^)(void))tryBlock error:(NSError *_Nullable *_Nullable)error {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name code:0 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown ObjC exception"
            }];
        }
        return NO;
    }
}

@end
