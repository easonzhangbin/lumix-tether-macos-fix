#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface S1HCaptureConsole : NSView
@property(nonatomic, strong, readonly) NSButton *captureButton;
- (void)updateWithValues:(NSDictionary<NSString *, NSString *> *)values cameraReady:(BOOL)cameraReady busy:(BOOL)busy;
@end

NS_ASSUME_NONNULL_END
