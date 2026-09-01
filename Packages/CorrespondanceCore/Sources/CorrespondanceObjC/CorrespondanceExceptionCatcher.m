#import "include/CorrespondanceExceptionCatcher.h"

@implementation CorrespondanceExceptionCatcher

+ (NSException *_Nullable)catchException:(void (^)(void))block {
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}

@end
