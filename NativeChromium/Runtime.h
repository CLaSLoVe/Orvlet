#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@interface ORNativeBrowser : NSObject
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) BOOL closed;
- (void)park;
- (void)close;
- (void)focusRenderer;
@end
@interface ORNativeChromium : NSObject
+ (void)prepareApplication;
+ (void)setTermination:(void (^)(void))termination;
+ (BOOL)isRunning;
+ (BOOL)startWithProfile:(NSString *)profile extensions:(NSString *)extensionRoot guest:(BOOL)guest port:(int)port error:(NSError **)error;
+ (nullable ORNativeBrowser *)createBrowser:(NSString *)identifier;
+ (void)closeBrowsers;
+ (NSUInteger)browserCount;
+ (void)flushCookies:(void (^)(void))completion;
+ (void)shutdown;
@end
NS_ASSUME_NONNULL_END
