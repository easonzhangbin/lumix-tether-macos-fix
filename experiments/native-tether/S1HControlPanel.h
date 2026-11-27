#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Reusable UI only. All methods and callbacks run on the AppKit main thread.
// controls[key] = { current: NSNumber/NSNull,
//                   options: [{ value: NSNumber, label: NSString }],
//                   available: BOOL, writable: BOOL, reason: NSString }.
@interface S1HControlPanel : NSView

@property(nonatomic, copy, nullable) void (^onCapture)(NSString *target);
@property(nonatomic, copy, nullable) void (^onSetBodyCaptureTarget)(NSString *target);
@property(nonatomic, copy, nullable) void (^onChooseDirectory)(void);
@property(nonatomic, copy, nullable) void (^onChoosePhotoNaming)(void);
@property(nonatomic, copy, nullable) void (^onSetProperty)(NSString *key, NSNumber *raw);
@property(nonatomic, copy, nullable) void (^onRefresh)(void);
@property(nonatomic, copy, nullable) void (^onRevealSavedPhoto)(void);
// "a" and "b" are opposite single-step focus commands.
@property(nonatomic, copy, nullable) void (^onFocusStep)(NSString *direction);

- (void)updateCapabilities:(NSDictionary *)controls busy:(BOOL)busy;
- (void)setBusy:(BOOL)busy;
- (void)setCameraReady:(BOOL)ready;
// The owner explicitly enables capture after its native session is ready.
- (void)setCaptureAvailable:(BOOL)available;
- (void)setCameraStorage:(nullable NSDictionary *)storage;
- (void)setRemoteFocusAvailable:(BOOL)available;
// The owner chooses and validates the directory; this view does no file I/O.
- (void)setSaveDirectory:(nullable NSString *)directory;
- (void)setLastSavedPath:(nullable NSString *)path;
// An empty message hides the strip. A negative fraction shows indeterminate progress.
- (void)setTransferProgressMessage:(nullable NSString *)message fraction:(double)fraction;
// Diagnostic details are displayed verbatim and wrap across lines.
- (void)setResultMessage:(nullable NSString *)message;
- (void)setWarningMessage:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
