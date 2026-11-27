// Independent AppKit tether UI. No Panasonic application code is used.
// USB runs in an owned child process, never on the AppKit thread. Application
// shutdown requests cancellation and has a bounded child-process fallback.
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import "S1HBorderBeam.h"
#import "S1HControlPanel.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    ino_t inode;
    struct timespec modified;
} PreviewFrameIdentity;

static CGImageRef copyLatestPreviewFrame(NSURL *url, PreviewFrameIdentity previous, PreviewFrameIdentity *identity) {
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 16 * 1024 * 1024 ||
        (info.st_ino == previous.inode && info.st_mtimespec.tv_sec == previous.modified.tv_sec &&
         info.st_mtimespec.tv_nsec == previous.modified.tv_nsec)) {
        close(fd);
        return NULL;
    }

    // The worker atomically replaces this file. Read and identify the same
    // inode so a replacement between a metadata query and the read is harmless.
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *bytes = [file readDataUpToLength:(NSUInteger)info.st_size error:NULL];
    [file closeAndReturnError:NULL];
    if (bytes.length != (NSUInteger)info.st_size) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL);
    if (!source) return NULL;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    CFStringRef type = CGImageSourceGetType(source);
    BOOL valid = type && CFEqual(type, CFSTR("public.jpeg")) && width > 0 && height > 0 &&
        width <= 8192 && height <= 8192 && width * height <= 32000000 &&
        CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
    CGImageRef frame = valid ? CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceShouldCache: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
    }) : NULL;
    CFRelease(source);
    if (frame) *identity = (PreviewFrameIdentity){info.st_ino, info.st_mtimespec};
    return frame;
}

@interface PreviewApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSView *previewView;
@property(nonatomic,strong) NSTextField *stateLabel;
@property(nonatomic,strong) NSTextField *metricsLabel;
@property(nonatomic,strong) NSButton *startButton;
@property(nonatomic,strong) S1HBorderBeam *startButtonBeam;
@property(nonatomic,strong) NSButton *stopButton;
@property(nonatomic,strong) NSButton *reconnectBox;
@property(nonatomic,strong) NSPopUpButton *qualityPopup;
@property(nonatomic,strong) S1HControlPanel *controlPanel;
@property(nonatomic,strong) NSPipe *commandPipe;
@property(nonatomic,strong) NSURL *saveDirectory;
@property(nonatomic,copy) NSDictionary *pendingAction;
@property(nonatomic,copy) NSString *cameraSaveDirectory;
@property(nonatomic,copy) NSString *cameraTransferID;
@property(nonatomic,copy) NSString *cameraTransferStatus;
@property(nonatomic,strong) NSURL *lastSavedPhotoURL;
@property(nonatomic,strong) NSDictionary *currentControls;
@property(nonatomic) BOOL cameraReady;
@property(nonatomic) BOOL captureAvailable;
@property(nonatomic) BOOL requiresReview;
@property(nonatomic) BOOL staleSessionRecoveryRequired;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSTimer *previewTimer;
@property(nonatomic,strong) dispatch_queue_t previewQueue;
@property(nonatomic) BOOL framePending;
@property(nonatomic) PreviewFrameIdentity lastFrameIdentity;
@property(nonatomic) NSUInteger viewWidth;
@property(nonatomic) NSUInteger viewHeight;
@property(nonatomic) NSUInteger updatesSinceSample;
@property(nonatomic) NSTimeInterval frameSampleTime;
@property(nonatomic) double updatesPerSecond;
@property(nonatomic,strong) NSTask *worker;
@property(nonatomic,strong) NSPipe *workerPipe;
@property(nonatomic,strong) NSFileHandle *logFile;
@property(nonatomic,strong) NSURL *baseOutputURL;
@property(nonatomic,strong) NSURL *outputURL;
@property(nonatomic) BOOL desiredRunning;
@property(nonatomic) BOOL terminating;
@property(nonatomic) BOOL chinese;
@property(nonatomic) NSUInteger generation;
@end

@implementation PreviewApp
- (NSString *)text:(NSString *)zh english:(NSString *)en { return self.chinese ? zh : en; }
- (void)setConnectButtonEnabled:(BOOL)enabled {
    self.startButton.enabled = enabled;
    self.startButtonBeam.active = enabled && !self.terminating;
}
- (NSTextField *)label:(NSString *)string font:(NSFont *)font {
    NSTextField *label = [NSTextField labelWithString:string];
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return label;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    self.baseOutputURL = [cache URLByAppendingPathComponent:@"S1H Native Preview/experimental" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:self.baseOutputURL withIntermediateDirectories:YES attributes:nil error:NULL];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1160, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"S1H Native Tether";
    self.window.minSize = NSMakeSize(850, 550);
    self.window.delegate = self;
    NSView *view = self.window.contentView;
    self.previewView = [[NSView alloc] initWithFrame:NSMakeRect(16, 72, 780, 618)];
    self.previewView.layer = [CALayer layer];
    self.previewView.wantsLayer = YES;
    self.previewView.layer.backgroundColor = NSColor.blackColor.CGColor;
    self.previewView.layer.contentsGravity = kCAGravityResizeAspect;
    self.previewView.layer.actions = @{@"contents": NSNull.null};
    self.previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.previewView setAccessibilityLabel:[self text:@"相机实时取景" english:@"Camera live view"]];
    [view addSubview:self.previewView];
    self.startButton = [NSButton buttonWithTitle:[self text:@"连接" english:@"Connect"] target:self action:@selector(start:)];
    self.startButton.frame = NSMakeRect(16, 712, 94, 30);
    self.startButton.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.startButton];
    self.startButtonBeam = [[S1HBorderBeam alloc] initWithFrame:self.startButton.frame];
    self.startButtonBeam.autoresizingMask = self.startButton.autoresizingMask;
    [view addSubview:self.startButtonBeam positioned:NSWindowAbove relativeTo:self.startButton];
    [self setConnectButtonEnabled:YES];
    self.stopButton = [NSButton buttonWithTitle:[self text:@"停止" english:@"Stop"] target:self action:@selector(stop:)];
    self.stopButton.frame = NSMakeRect(118, 712, 94, 30);
    self.stopButton.enabled = NO;
    self.stopButton.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.stopButton];
    self.reconnectBox = [NSButton checkboxWithTitle:[self text:@"断线后重试" english:@"Retry after disconnect"] target:self action:@selector(reconnectChanged:)];
    self.reconnectBox.frame = NSMakeRect(232, 712, 230, 30);
    self.reconnectBox.state = NSControlStateValueOn;
    self.reconnectBox.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.reconnectBox];
    self.qualityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(468, 712, 214, 30) pullsDown:NO];
    [self.qualityPopup addItemsWithTitles:@[[self text:@"保持相机当前分辨率" english:@"Keep camera setting"], [self text:@"标准预览分辨率" english:@"Standard resolution"], [self text:@"最高预览分辨率" english:@"Highest resolution"]]];
    NSString *savedFormat = [NSUserDefaults.standardUserDefaults stringForKey:@"previewFormat"];
    if ([savedFormat isEqualToString:@"max"]) [self.qualityPopup selectItemAtIndex:2];
    else if ([savedFormat isEqualToString:@"0"]) [self.qualityPopup selectItemAtIndex:1];
    self.qualityPopup.target = self;
    self.qualityPopup.action = @selector(qualityChanged:);
    self.qualityPopup.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.qualityPopup];
    self.controlPanel = [[S1HControlPanel alloc] initWithFrame:NSMakeRect(812, 72, 332, 618)];
    self.controlPanel.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    __weak PreviewApp *panelSelf = self;
    self.controlPanel.onCapture = ^(NSString *target) { [panelSelf capturePhotoWithTarget:target]; };
    self.controlPanel.onChooseDirectory = ^{ [panelSelf chooseSaveDirectory]; };
    self.controlPanel.onSetProperty = ^(NSString *key, NSNumber *raw) { [panelSelf setCameraProperty:key value:raw]; };
    self.controlPanel.onRefresh = ^{ [panelSelf refreshCameraControls]; };
    self.controlPanel.onRevealSavedPhoto = ^{ [panelSelf revealSavedPhoto]; };
    NSString *savedDirectory = [NSUserDefaults.standardUserDefaults stringForKey:@"photoSaveDirectory"];
    NSURL *pictures = [NSFileManager.defaultManager URLsForDirectory:NSPicturesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *rememberedDirectory = savedDirectory.isAbsolutePath ? [NSURL fileURLWithPath:savedDirectory isDirectory:YES] : nil;
    self.saveDirectory = [self photoDirectory:rememberedDirectory] ?: [pictures URLByAppendingPathComponent:@"S1H Tether" isDirectory:YES];
    [self.controlPanel setSaveDirectory:self.saveDirectory.path];
    [self.controlPanel updateCapabilities:@{} busy:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [view addSubview:self.controlPanel];
    self.stateLabel = [self label:[self text:@"请退出其他相机软件，并在 S1H 选择 PC(Tether)。" english:@"Quit other camera apps and select PC(Tether) on the S1H."] font:[NSFont systemFontOfSize:14]];
    self.stateLabel.frame = NSMakeRect(20, 40, 1120, 22);
    self.stateLabel.autoresizingMask = NSViewWidthSizable;
    [view addSubview:self.stateLabel];
    self.metricsLabel = [self label:@"—" font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]];
    self.metricsLabel.textColor = NSColor.secondaryLabelColor;
    self.metricsLabel.frame = NSMakeRect(20, 14, 1120, 20);
    self.metricsLabel.autoresizingMask = NSViewWidthSizable;
    [view addSubview:self.metricsLabel];
    NSMenu *menuBar = [NSMenu new];
    NSMenuItem *applicationItem = [NSMenuItem new];
    [menuBar addItem:applicationItem];
    NSMenu *applicationMenu = [NSMenu new];
    [applicationMenu addItemWithTitle:[self text:@"退出 S1H Native Tether" english:@"Quit S1H Native Tether"] action:@selector(terminate:) keyEquivalent:@"q"];
    applicationItem.submenu = applicationMenu;
    NSApp.mainMenu = menuBar;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
    self.previewQueue = dispatch_queue_create("s1h.preview.decode", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    self.timer = [NSTimer timerWithTimeInterval:0.125 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    self.previewTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(refreshPreview:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
}
- (void)start:(id)sender {
    (void)sender;
    if (self.worker || self.pendingAction || self.terminating || self.window.attachedSheet) return;
    if (self.staleSessionRecoveryRequired) {
        NSAlert *confirmation = [NSAlert new];
        confirmation.alertStyle = NSAlertStyleWarning;
        confirmation.messageText = [self text:@"清理相机的旧会话？" english:@"Close the camera’s previous session?"];
        confirmation.informativeText = [self text:@"请先确认机身已回到正常取景、写卡灯已熄灭，并且没有照片正在传输。若上一张的结果未确认，也请检查照片保存目录。"
            english:@"First confirm the camera has returned to live view, the card access light is off, and no photo is transferring. If the last shot was unconfirmed, also check your save folder."];
        [confirmation addButtonWithTitle:[self text:@"取消" english:@"Cancel"]];
        [confirmation addButtonWithTitle:[self text:@"关闭旧会话并连接" english:@"Close Session and Connect"]];
        [confirmation beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertSecondButtonReturn && self.staleSessionRecoveryRequired)
                [self startConnectionClosingStaleSession:YES];
        }];
        return;
    }
    [self startConnectionClosingStaleSession:NO];
}
- (void)startConnectionClosingStaleSession:(BOOL)closeStaleSession {
    if (self.worker || self.pendingAction || self.terminating) return;
    if (self.requiresReview) [self.controlPanel setResultMessage:nil];
    self.requiresReview = NO;
    self.stateLabel.textColor = NSColor.labelColor;
    self.desiredRunning = YES;
    self.generation += 1;
    [self launchWorkerClosingStaleSession:closeStaleSession];
}
- (void)pruneOldRuns {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.baseOutputURL
        includingPropertiesForKeys:@[NSURLCreationDateKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSMutableArray<NSDictionary *> *runs = [NSMutableArray array];
    for (NSURL *url in entries) {
        if (![[NSUUID alloc] initWithUUIDString:url.lastPathComponent]) continue;
        NSDictionary *values = [url resourceValuesForKeys:@[NSURLCreationDateKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] error:NULL];
        if (![values[NSURLIsDirectoryKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]) continue;
        [runs addObject:@{@"url": url, @"created": values[NSURLCreationDateKey] ?: NSDate.distantPast}];
    }
    [runs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"created"] compare:b[@"created"]];
    }];
    while (runs.count > 8) {
        NSURL *old = runs.firstObject[@"url"];
        // Only this app's generated UUID directories inside its own cache.
        if (![old isEqual:self.outputURL]) [NSFileManager.defaultManager removeItemAtURL:old error:NULL];
        [runs removeObjectAtIndex:0];
    }
}
- (void)launchWorkerClosingStaleSession:(BOOL)closeStaleSession {
    if (!self.desiredRunning || self.worker || self.terminating || self.requiresReview ||
        (self.staleSessionRecoveryRequired && !closeStaleSession)) return;
    NSString *helper = [NSBundle.mainBundle pathForResource:@"s1h_native_preview" ofType:nil];
    if (!helper || ![NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
        self.stateLabel.stringValue = [self text:@"缺少实验通信程序。" english:@"The experimental USB worker is missing."];
        self.desiredRunning = NO;
        return;
    }
    self.stateLabel.stringValue = [self text:@"正在连接 S1H……" english:@"Connecting to the S1H…"];
    self.outputURL = [self.baseOutputURL URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.outputURL withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        self.stateLabel.stringValue = [self text:@"无法创建本次预览缓存目录。" english:@"Could not create this preview session's cache."];
        self.desiredRunning = NO;
        return;
    }
    self.cameraReady = NO;
    self.captureAvailable = NO;
    self.pendingAction = nil;
    self.cameraTransferID = nil;
    self.cameraTransferStatus = nil;
    self.currentControls = @{};
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel updateCapabilities:@{} busy:NO];
    self.previewView.layer.contents = nil;
    self.lastFrameIdentity = (PreviewFrameIdentity){0};
    self.viewWidth = 0;
    self.viewHeight = 0;
    self.updatesSinceSample = 0;
    self.frameSampleTime = 0;
    self.updatesPerSecond = -1;
    self.metricsLabel.stringValue = @"—";
    [self pruneOldRuns];
    [self setConnectButtonEnabled:NO];
    self.stopButton.enabled = YES;
    self.qualityPopup.enabled = NO;
    NSURL *logURL = [self.outputURL URLByAppendingPathComponent:@"worker.log"];
    [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    self.workerPipe = [NSPipe pipe];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:helper];
    NSMutableArray *arguments = [@[@"--output-dir", self.outputURL.path, @"--frames", @"1000000000", @"--fps", @"30",
        @"--parent-pid", [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier], @"--interactive"] mutableCopy];
    if (closeStaleSession) [arguments addObject:@"--close-stale-session"];
    NSURL *directory = [self photoDirectory:self.saveDirectory];
    self.cameraSaveDirectory = nil;
    if (directory && [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:NULL] && access(directory.fileSystemRepresentation, W_OK | X_OK) == 0) {
        self.cameraSaveDirectory = directory.path;
        [arguments addObjectsFromArray:@[@"--camera-save-dir", self.cameraSaveDirectory]];
    } else {
        [self.controlPanel setWarningMessage:[self text:@"机身拍摄的保存文件夹不可用，请选择可写的文件夹。" english:@"The camera capture folder is unavailable. Choose a writable folder."]];
    }
    if (self.qualityPopup.indexOfSelectedItem > 0) {
        NSString *format = self.qualityPopup.indexOfSelectedItem == 2 ? @"max" : @"0";
        [arguments addObjectsFromArray:@[@"--preview-format", format, @"--keep-preview-format"]];
    }
    task.arguments = arguments;
    self.commandPipe = [NSPipe pipe];
    task.standardInput = self.commandPipe;
    task.standardOutput = self.workerPipe;
    task.standardError = self.workerPipe;
    self.worker = task;
    __weak PreviewApp *weakSelf = self;
    NSFileHandle *workerLog = self.logFile;
    __block NSUInteger loggedBytes = 0;
    const NSUInteger logLimit = 1024 * 1024;
    self.workerPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        if (loggedBytes < logLimit) {
            NSUInteger count = MIN(data.length, logLimit - loggedBytes);
            NSData *prefix = count == data.length ? data : [data subdataWithRange:NSMakeRange(0, count)];
            @try { [workerLog writeData:prefix]; } @catch (NSException *exception) { (void)exception; }
            loggedBytes += count;
        }
    };
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf workerFinished:finished]; });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        self.stateLabel.stringValue = [self text:@"无法启动通信程序。" english:@"Could not start the USB worker."];
        task.terminationHandler = nil;
        self.worker = nil;
        @try { [self.commandPipe.fileHandleForWriting closeFile]; } @catch (NSException *exception) { (void)exception; }
        self.commandPipe = nil;
        self.workerPipe.fileHandleForReading.readabilityHandler = nil;
        [self setConnectButtonEnabled:YES];
        self.stopButton.enabled = NO;
        self.qualityPopup.enabled = YES;
        self.desiredRunning = NO;
    }
}
- (void)workerFinished:(NSTask *)finished {
    if (self.worker != finished) return;
    // Read a final action result before tearing down this run's status path.
    [self refresh:nil];
    if (self.pendingAction) {
        if ([self.pendingAction[@"action"] isEqual:@"capture"]) self.requiresReview = YES;
        [self.controlPanel setWarningMessage:[self text:@"连接已结束，操作结果尚未确认。请检查相机和照片目录。" english:@"The connection ended before the operation was confirmed. Check the camera and photo folder."]];
    }
    if ([self cameraTransferInProgress]) {
        self.requiresReview = YES;
        [self.controlPanel setWarningMessage:[self text:@"连接已结束，机身拍摄的保存结果未确认。请检查相机和照片目录。"
            english:@"The connection ended during a camera capture transfer. Check the camera and save folder."]];
    }
    self.workerPipe.fileHandleForReading.readabilityHandler = nil;
    [self.logFile closeFile];
    self.logFile = nil;
    self.workerPipe = nil;
    @try { [self.commandPipe.fileHandleForWriting closeFile]; } @catch (NSException *exception) { (void)exception; }
    self.commandPipe = nil;
    self.worker = nil;
    self.cameraReady = NO;
    self.captureAvailable = NO;
    self.metricsLabel.stringValue = @"—";
    self.pendingAction = nil;
    self.cameraSaveDirectory = nil;
    self.cameraTransferStatus = nil;
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel updateCapabilities:self.currentControls ?: @{} busy:NO];
    [self setConnectButtonEnabled:YES];
    self.stopButton.enabled = NO;
    self.qualityPopup.enabled = YES;
    if (self.terminating) { [NSApp replyToApplicationShouldTerminate:YES]; return; }
    if (self.requiresReview) {
        self.desiredRunning = NO;
        [self showCaptureReviewRequired];
        return;
    }
    if (self.staleSessionRecoveryRequired) {
        self.desiredRunning = NO;
        [self showStaleSessionRecoveryRequired];
        return;
    }
    if (!self.desiredRunning) {
        self.stateLabel.stringValue = [self text:@"已停止，通信进程已退出。" english:@"Stopped; the USB worker has exited."];
        return;
    }
    if (self.reconnectBox.state != NSControlStateValueOn) {
        self.desiredRunning = NO;
        self.stateLabel.stringValue = [self text:@"连接已结束，可再次点击“连接”。" english:@"The connection ended. Click Connect to try again."];
        return;
    }
    self.stateLabel.stringValue = [self text:@"等待相机；3 秒后重试。" english:@"Waiting for the camera; retrying in 3 seconds."];
    self.stopButton.enabled = YES;
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.generation == generation && self.desiredRunning) [self launchWorkerClosingStaleSession:NO];
    });
}
- (void)reconnectChanged:(id)sender {
    (void)sender;
    if (self.reconnectBox.state == NSControlStateValueOff && !self.worker) [self stop:nil];
}
- (void)qualityChanged:(id)sender {
    (void)sender;
    NSString *format = self.qualityPopup.indexOfSelectedItem == 2 ? @"max" : (self.qualityPopup.indexOfSelectedItem == 1 ? @"0" : @"auto");
    [NSUserDefaults.standardUserDefaults setObject:format forKey:@"previewFormat"];
}
- (void)stop:(id)sender {
    (void)sender;
    self.desiredRunning = NO;
    self.cameraReady = NO;
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel setBusy:self.pendingAction != nil || [self cameraTransferInProgress]];
    self.generation += 1;
    NSTask *task = self.worker;
    if (!task) {
        [self setConnectButtonEnabled:YES];
        self.stopButton.enabled = NO;
        if (self.requiresReview) [self showCaptureReviewRequired];
        else if (self.staleSessionRecoveryRequired) [self showStaleSessionRecoveryRequired];
        else self.stateLabel.stringValue = [self text:@"已停止。" english:@"Stopped."];
        return;
    }
    self.stateLabel.stringValue = [self text:@"正在停止并释放相机……" english:@"Stopping and releasing the camera…"];
    self.stopButton.enabled = NO;
    if (task.running) [task terminate];
    // The USB worker has its own ten-second cancellation watchdog. Let its
    // valid in-flight transaction and cleanup finish before this fallback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.worker == task && task.running) kill(task.processIdentifier, SIGKILL);
    });
}
- (NSURL *)photoDirectory:(NSURL *)url {
    NSURL *resolved = url.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    if (!resolved.fileURL || !resolved.path.isAbsolutePath) return nil;
    NSString *cache = self.baseOutputURL.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    NSString *destination = resolved.path.precomposedStringWithCanonicalMapping.lowercaseString;
    cache = cache.precomposedStringWithCanonicalMapping.lowercaseString;
    if ([destination isEqualToString:cache] || [destination hasPrefix:[cache stringByAppendingString:@"/"]]) return nil;
    return resolved;
}
- (void)chooseSaveDirectory {
    if (self.pendingAction || [self cameraTransferInProgress] || self.terminating) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = self.saveDirectory;
    panel.message = [self text:@"选择拍摄原片的保存文件夹" english:@"Choose a folder for captured originals"];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSURL *directory = [self photoDirectory:panel.URL];
        if (!directory) {
            [self.controlPanel setWarningMessage:[self text:@"请选择预览缓存之外的照片文件夹。" english:@"Choose a photo folder outside the preview cache."]];
            return;
        }
        if (!self.worker) {
            [self saveSelectedDirectory:directory];
            return;
        }
        if (access(directory.fileSystemRepresentation, W_OK | X_OK) != 0) {
            [self.controlPanel setWarningMessage:[self text:@"无法写入所选照片文件夹。" english:@"The selected photo folder is not writable."]];
            return;
        }
        if (self.pendingAction || [self cameraTransferInProgress] || !self.cameraReady) {
            [self.controlPanel setWarningMessage:[self text:@"请等待相机空闲后再更改保存文件夹。" english:@"Wait until the camera is ready before changing the save folder."]];
            return;
        }
        if ([self sendAction:@{@"action": @"set_camera_save_dir", @"directory": directory.path}])
            [self.controlPanel setResultMessage:[self text:@"正在更新照片保存文件夹……" english:@"Updating the photo save folder…"]];
    }];
}
- (void)saveSelectedDirectory:(NSURL *)directory {
    self.saveDirectory = directory;
    [NSUserDefaults.standardUserDefaults setObject:directory.path forKey:@"photoSaveDirectory"];
    [self.controlPanel setSaveDirectory:directory.path];
}
- (void)revealSavedPhoto {
    NSURL *photo = self.lastSavedPhotoURL;
    if (!photo) return;
    if ([photo checkResourceIsReachableAndReturnError:NULL]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[photo]];
    } else {
        self.lastSavedPhotoURL = nil;
        [self.controlPanel setLastSavedPath:nil];
        [self.controlPanel setWarningMessage:[self text:@"照片已移出原保存位置。" english:@"The last photo is unavailable at its saved location."]];
    }
}
- (void)showCaptureReviewRequired {
    self.stateLabel.textColor = NSColor.systemRedColor;
    self.stateLabel.stringValue = [self text:@"已暂停自动重连。请检查机身和照片目录，确认后再连接。" english:@"Automatic reconnect paused. Check the camera and save folder before reconnecting."];
}
- (void)showStaleSessionRecoveryRequired {
    self.startButton.title = [self text:@"修复连接" english:@"Recover"];
    self.stateLabel.textColor = NSColor.systemRedColor;
    self.stateLabel.stringValue = [self text:@"相机仍保留旧会话，已暂停重试。确认机身未写入后，点击「修复连接」。"
        english:@"The previous camera session is still open. Retries paused. Confirm the camera is idle, then click Recover."];
}
- (BOOL)sendAction:(NSDictionary *)fields {
    if (!self.worker.running || !self.cameraReady || self.pendingAction || [self cameraTransferInProgress] || self.terminating || self.requiresReview) return NO;
    NSMutableDictionary *command = [fields mutableCopy];
    command[@"id"] = NSUUID.UUID.UUIDString;
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:&error];
    if (!json || json.length > 4096) {
        [self.controlPanel setWarningMessage:[self text:@"操作信息过长，请选择路径更短的照片文件夹。" english:@"The camera request is too long. Choose a shorter photo folder path."]];
        return NO;
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    BOOL written = NO;
    @try { written = [self.commandPipe.fileHandleForWriting writeData:line error:&error]; }
    @catch (NSException *exception) { (void)exception; }
    if (!written) {
        [self.controlPanel setWarningMessage:[self text:@"无法向相机通信进程提交操作。" english:@"Could not submit the operation to the camera worker."]];
        return NO;
    }
    self.pendingAction = command;
    [self.controlPanel updateCapabilities:self.currentControls ?: @{} busy:YES];
    return YES;
}
- (void)capturePhotoWithTarget:(NSString *)target {
    if (!self.cameraReady || !self.captureAvailable || self.pendingAction) return;
    NSURL *directory = [self photoDirectory:self.saveDirectory];
    NSError *error = nil;
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        [self.controlPanel setWarningMessage:[self text:@"无法创建照片文件夹，请重新选择保存位置。" english:@"Could not create the photo folder. Choose another destination."]];
        return;
    }
    if ([self sendAction:@{@"action": @"capture", @"directory": directory.path, @"target": target}])
        [self.controlPanel setResultMessage:[self text:@"正在拍摄并保存原片……" english:@"Capturing and saving originals…"]];
}
- (void)setCameraProperty:(NSString *)key value:(NSNumber *)value {
    if ([self sendAction:@{@"action": @"set", @"property": key, @"value": value}])
        [self.controlPanel setResultMessage:[self text:@"正在设置并回读确认……" english:@"Applying and verifying the setting…"]];
    else [self.controlPanel updateCapabilities:self.currentControls ?: @{} busy:self.pendingAction != nil || [self cameraTransferInProgress]];
}
- (void)refreshCameraControls {
    if ([self sendAction:@{@"action": @"refresh"}])
        [self.controlPanel setResultMessage:[self text:@"正在读取相机实际设置……" english:@"Reading the camera settings…"]];
}
- (NSUInteger)confirmSavedFiles:(NSArray *)files inDirectory:(NSString *)directory {
    NSUInteger count = 0;
    for (id file in files) {
        if (![file isKindOfClass:NSDictionary.class]) continue;
        NSString *path = [file[@"path"] isKindOfClass:NSString.class] ? file[@"path"] : nil;
        NSNumber *expectedBytes = [file[@"bytes"] isKindOfClass:NSNumber.class] ? file[@"bytes"] : nil;
        if (!path.isAbsolutePath || ![path.stringByDeletingLastPathComponent isEqualToString:directory]) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular] || !expectedBytes || attributes.fileSize == 0 ||
            attributes.fileSize != expectedBytes.unsignedLongLongValue) continue;
        self.lastSavedPhotoURL = [NSURL fileURLWithPath:path];
        count++;
    }
    if (count) [self.controlPanel setLastSavedPath:self.lastSavedPhotoURL.path];
    return count;
}
- (BOOL)cameraTransferInProgress {
    return [self.cameraTransferStatus isEqualToString:@"busy"];
}
- (void)showCameraTransferStatus:(NSDictionary *)transfer previousDirectory:(NSString *)previousDirectory {
    NSString *identifier = [transfer[@"id"] isKindOfClass:NSString.class] ? transfer[@"id"] : nil;
    NSString *result = [transfer[@"status"] isKindOfClass:NSString.class] ? transfer[@"status"] : nil;
    if (!identifier.length || !result || ![@[@"busy", @"ok", @"error", @"outcome_unknown"] containsObject:result]) return;
    if ([self.cameraTransferID isEqualToString:identifier] && [self.cameraTransferStatus isEqualToString:result]) return;
    self.cameraTransferID = identifier;
    self.cameraTransferStatus = result;
    if ([self cameraTransferInProgress]) {
        [self.controlPanel setResultMessage:[self text:@"正在接收机身快门拍摄的原片……" english:@"Receiving photos taken with the camera shutter…"]];
        return;
    }

    NSArray *files = [transfer[@"files"] isKindOfClass:NSArray.class] ? transfer[@"files"] : @[];
    NSString *directory = [transfer[@"directory"] isKindOfClass:NSString.class] ? transfer[@"directory"] : nil;
    BOOL knownDirectory = [directory isEqualToString:self.cameraSaveDirectory] || [directory isEqualToString:previousDirectory];
    NSUInteger saved = knownDirectory ? [self confirmSavedFiles:files inDirectory:directory] : 0;
    if ([result isEqualToString:@"ok"] && saved > 0 && saved == files.count) {
        [self.controlPanel setResultMessage:[NSString stringWithFormat:[self text:@"机身拍摄已保存 %lu 个原片文件。" english:@"Saved %lu original file(s) from the camera shutter."], (unsigned long)saved]];
        return;
    }
    if ([result isEqualToString:@"outcome_unknown"] || [result isEqualToString:@"ok"]) {
        self.requiresReview = YES;
        self.desiredRunning = NO;
    }
    NSString *message = saved ? [NSString stringWithFormat:[self text:@"已核对 %lu 个原片文件。请检查机身和照片目录，确认其余保存结果。"
        english:@"Verified %lu original file(s). Check the camera and save folder for the remaining files."], (unsigned long)saved]
        : [self text:@"未能确认机身拍摄的原片已保存。请检查相机和照片目录。" english:@"Could not confirm that the camera capture was saved. Check the camera and save folder."];
    [self.controlPanel setWarningMessage:message];
}
- (void)showActionStatus:(NSDictionary *)action {
    NSDictionary *pending = self.pendingAction;
    if (!pending || ![action[@"id"] isEqual:pending[@"id"]]) return;
    NSString *result = [action[@"status"] isKindOfClass:NSString.class] ? action[@"status"] : @"";
    NSString *detail = [action[@"message"] isKindOfClass:NSString.class] ? action[@"message"] : @"";
    if ([result isEqualToString:@"busy"]) {
        NSDictionary *phaseMessages = @{
            @"preparing": [self text:@"正在准备拍摄……" english:@"Preparing to capture…"],
            @"shutter": [self text:@"正在触发快门……" english:@"Triggering the shutter…"],
            @"waiting": [self text:@"正在等待相机完成拍摄……" english:@"Waiting for the camera to finish…"],
            @"download": [self text:@"正在接收原片……" english:@"Receiving the original…"]
        };
        NSDictionary *workerMessages = @{
            @"Preparing camera action.": phaseMessages[@"preparing"],
            @"Checking the camera before capture.": phaseMessages[@"preparing"],
            @"Taking one photograph.": phaseMessages[@"shutter"],
            @"Waiting for the camera to finish the capture.":
                [self text:@"相机已接受快门，正在等待照片可下载……" english:@"Shutter accepted. Waiting for the photo to become available…"]
        };
        NSString *phase = [action[@"phase"] isKindOfClass:NSString.class] ? action[@"phase"] : @"";
        NSString *progress = phaseMessages[phase] ?: workerMessages[detail] ?: detail;
        NSNumber *total = [action[@"total_bytes"] isKindOfClass:NSNumber.class] ? action[@"total_bytes"] : nil;
        NSNumber *downloaded = [action[@"downloaded_bytes"] isKindOfClass:NSNumber.class] ? action[@"downloaded_bytes"] : nil;
        if (downloaded && total.doubleValue > 0 && downloaded.doubleValue >= 0 && downloaded.doubleValue <= total.doubleValue)
            progress = [NSString stringWithFormat:@"%@ %.1f / %.1f MB", progress, downloaded.doubleValue / 1e6, total.doubleValue / 1e6];
        if (progress.length) [self.controlPanel setResultMessage:progress];
        return;
    }
    if (![@[@"ok", @"rejected", @"error", @"outcome_unknown"] containsObject:result]) return;
    self.pendingAction = nil;
    BOOL captured = [pending[@"action"] isEqual:@"capture"];
    BOOL ok = [result isEqualToString:@"ok"];
    if ([pending[@"action"] isEqual:@"set_camera_save_dir"]) {
        if (ok) {
            self.cameraSaveDirectory = pending[@"directory"];
            [self saveSelectedDirectory:[NSURL fileURLWithPath:self.cameraSaveDirectory isDirectory:YES]];
            [self.controlPanel setResultMessage:[self text:@"已更新照片保存文件夹。" english:@"Updated the photo save folder."]];
        } else {
            [self.controlPanel setWarningMessage:[self text:@"未能更改照片保存文件夹。请确认所选文件夹可写，并在相机空闲后重试。"
                english:@"Could not change the photo save folder. Check that it is writable and try again once the camera is ready."]];
        }
        return;
    }
    BOOL unknown = [result isEqualToString:@"outcome_unknown"];
    NSArray *reportedFiles = [action[@"files"] isKindOfClass:NSArray.class] ? action[@"files"] : @[];
    NSUInteger savedCount = captured ? [self confirmSavedFiles:reportedFiles inDirectory:pending[@"directory"]] : 0;
    if (captured && ok && (!savedCount || savedCount != reportedFiles.count)) {
        ok = NO;
        unknown = YES;
        detail = [self text:@"通信进程报告已保存，但无法核对全部文件。" english:@"The worker reported a save, but not every file could be verified."];
    }
    if (captured && (unknown || (!ok && [result isEqualToString:@"error"] && [action[@"capture_issued"] boolValue]))) {
        self.requiresReview = YES;
        self.desiredRunning = NO;
    }
    if (ok) {
        NSString *message = [pending[@"action"] isEqual:@"set"] ? [self text:@"参数已修改并回读确认。" english:@"Setting applied and confirmed by the camera."]
            : [self text:@"已更新相机参数。" english:@"Camera settings refreshed."];
        if (captured) message = [NSString stringWithFormat:[self text:@"已保存 %lu 个原片文件。" english:@"Saved %lu original file(s)."], (unsigned long)savedCount];
        [self.controlPanel setResultMessage:message];
    } else {
        if (captured && ([detail containsString:@"0x2013"] || [detail hasPrefix:@"The camera reported no active card storage."])) {
            detail = [self text:@"相机报告存储卡不可用。请在机身确认卡已识别、可写。"
                english:@"The camera reported no usable card. Check that the camera recognizes a writable card."];
        } else if (captured && [detail hasPrefix:@"Could not confirm card storage."]) {
            detail = [self text:@"无法确认机身存储卡，未触发快门。" english:@"Card storage could not be confirmed. The shutter was not triggered."];
        } else if (captured && [detail hasPrefix:@"No new photo object arrived"] && !savedCount) {
            detail = [self text:@"相机接受了快门，但没有交付照片，Mac 未收到文件。请先检查机身和存储状态。"
                english:@"The camera accepted the shutter, but it delivered no photo to the Mac. Check the camera and storage before trying again."];
            if ([action[@"original_target_restored"] isEqual:@NO])
                detail = [detail stringByAppendingString:[self text:@" 原存储目标尚未确认恢复。" english:@" The original storage target could not be verified."]];
        }
        NSString *prefix = unknown ? [self text:@"结果未确认。" english:@"Outcome unconfirmed."] : [self text:@"操作未完成。" english:@"Operation incomplete."];
        [self.controlPanel setWarningMessage:detail.length ? [NSString stringWithFormat:@"%@ %@", prefix, detail] : prefix];
    }
}
- (void)refresh:(NSTimer *)timer {
    (void)timer;
    if (!self.worker) return;
    NSURL *statusURL = [self.outputURL URLByAppendingPathComponent:@"status.json"];
    NSData *data = [NSData dataWithContentsOfURL:statusURL];
    NSDictionary *status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![status isKindOfClass:NSDictionary.class]) return;
    NSString *state = [status[@"status"] isKindOfClass:NSString.class] ? status[@"status"] : @"";
    NSDictionary *controls = [status[@"controls"] isKindOfClass:NSDictionary.class] ? status[@"controls"] : @{};
    BOOL controlsChanged = ![self.currentControls isEqualToDictionary:controls];
    self.currentControls = controls;
    if ([status[@"requires_review"] boolValue]) {
        self.requiresReview = YES;
        self.desiredRunning = NO;
    }
    BOOL blockedByStaleSession = [status[@"stale_session"] isEqual:@YES];
    if (blockedByStaleSession) {
        self.staleSessionRecoveryRequired = YES;
        self.desiredRunning = NO;
        self.startButton.title = [self text:@"修复连接" english:@"Recover"];
    } else if ([state isEqualToString:@"previewing"] && self.staleSessionRecoveryRequired) {
        self.staleSessionRecoveryRequired = NO;
        self.startButton.title = [self text:@"连接" english:@"Connect"];
    }
    NSDictionary *action = [status[@"action_status"] isKindOfClass:NSDictionary.class] ? status[@"action_status"] : nil;
    NSString *previousDirectory = self.cameraSaveDirectory;
    if (action) [self showActionStatus:action];
    NSDictionary *transfer = [status[@"camera_transfer"] isKindOfClass:NSDictionary.class] ? status[@"camera_transfer"] : nil;
    if (transfer) [self showCameraTransferStatus:transfer previousDirectory:previousDirectory];
    self.cameraReady = self.desiredRunning && !self.requiresReview && [state isEqualToString:@"previewing"];
    self.captureAvailable = [status[@"capture_available"] boolValue];
    [self.controlPanel setCameraReady:self.cameraReady];
    [self.controlPanel setCaptureAvailable:self.cameraReady && self.captureAvailable];
    BOOL busy = self.pendingAction != nil || [action[@"status"] isEqual:@"busy"] || [self cameraTransferInProgress];
    if (controlsChanged) [self.controlPanel updateCapabilities:controls busy:busy];
    else [self.controlPanel setBusy:busy];
    if (self.requiresReview) [self showCaptureReviewRequired];
    else if (blockedByStaleSession) [self showStaleSessionRecoveryRequired];
    else if ([state isEqualToString:@"previewing"] && self.desiredRunning) {
        if ([self cameraTransferInProgress]) {
            self.stateLabel.stringValue = [self text:@"正在接收机身拍摄原片，已暂停取景更新" english:@"Receiving camera photos. Live view updates paused."];
            self.metricsLabel.stringValue = [self text:@"显示拍摄前的最后一帧" english:@"Showing the last frame before capture"];
        } else if ([self.pendingAction[@"action"] isEqual:@"capture"]) {
            self.stateLabel.stringValue = [self text:@"拍摄处理中，已暂停取景更新" english:@"Capture in progress. Live view updates paused."];
            self.metricsLabel.stringValue = [self text:@"显示拍摄前的最后一帧" english:@"Showing the last frame before capture"];
        } else {
            self.stateLabel.stringValue = [self text:@"S1H 原生 USB 实时预览" english:@"S1H native USB live preview"];
            [self refreshPreviewMetrics];
        }
    } else if (self.desiredRunning) {
        NSString *message = [status[@"message"] isKindOfClass:NSString.class] ? status[@"message"] : state;
        NSDictionary<NSString *, NSString *> *progressMessages = @{
            @"Starting experimental native USB preview.": [self text:@"正在启动实验原生 USB 预览……" english:@"Starting experimental native USB preview."],
            @"Connecting to DC-S1H.": [self text:@"正在连接 DC-S1H……" english:@"Connecting to DC-S1H."],
            @"Preparing the camera connection.": [self text:@"正在准备相机连接……" english:@"Preparing the camera connection."],
            @"Connected to Panasonic DC-S1H.": [self text:@"已连接松下 DC-S1H。" english:@"Connected to Panasonic DC-S1H."],
            @"Preparing the selected preview format.": [self text:@"正在准备所选预览分辨率……" english:@"Preparing the selected preview format."],
            @"Stopping native preview.": [self text:@"正在停止原生预览……" english:@"Stopping native preview."],
            @"Preview cancelled and stopped.": [self text:@"预览已取消并停止。" english:@"Preview cancelled and stopped."],
            @"Preview completed and stopped.": [self text:@"预览已完成并停止。" english:@"Preview completed and stopped."]
        };
        NSString *localizedMessage = progressMessages[message];
        if (localizedMessage) self.stateLabel.stringValue = localizedMessage;
        else if (message.length) {
            NSString *prefix = [state isEqualToString:@"error"] ? [self text:@"错误：" english:@"Error:"] : [self text:@"状态：" english:@"Status:"];
            self.stateLabel.stringValue = [NSString stringWithFormat:@"%@ %@", prefix, message];
        } else self.stateLabel.stringValue = [self text:@"正在准备预览……" english:@"Preparing preview…"];
    }
}
- (void)refreshPreviewMetrics {
    if (!self.viewWidth || !self.viewHeight) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.frameSampleTime >= 1.0) {
        self.updatesPerSecond = self.updatesSinceSample / (now - self.frameSampleTime);
        self.updatesSinceSample = 0;
        self.frameSampleTime = now;
    }
    if (self.updatesPerSecond < 0) {
        self.metricsLabel.stringValue = [NSString stringWithFormat:@"%lu × %lu", (unsigned long)self.viewWidth, (unsigned long)self.viewHeight];
        return;
    }
    NSString *format = [self text:@"%lu × %lu    取景更新 %.1f 次/秒" english:@"%lu × %lu    %.1f view updates/s"];
    self.metricsLabel.stringValue = [NSString stringWithFormat:format, (unsigned long)self.viewWidth, (unsigned long)self.viewHeight, self.updatesPerSecond];
}
- (void)refreshPreview:(NSTimer *)timer {
    (void)timer;
    if (!self.worker || !self.desiredRunning || !self.window.visible || self.window.miniaturized || self.framePending || [self cameraTransferInProgress]) return;
    NSURL *runURL = self.outputURL;
    NSURL *frameURL = [runURL URLByAppendingPathComponent:@"latest.jpg"];
    PreviewFrameIdentity previous = self.lastFrameIdentity;
    NSUInteger generation = self.generation;
    self.framePending = YES;
    dispatch_async(self.previewQueue, ^{
        @autoreleasepool {
            PreviewFrameIdentity identity = {0};
            CGImageRef frame = copyLatestPreviewFrame(frameURL, previous, &identity);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.framePending = NO;
                if (!frame) return;
                if (self.worker && self.desiredRunning && self.generation == generation && [self.outputURL isEqual:runURL] && ![self cameraTransferInProgress]) {
                    self.previewView.layer.contents = (__bridge id)frame;
                    self.lastFrameIdentity = identity;
                    self.viewWidth = CGImageGetWidth(frame);
                    self.viewHeight = CGImageGetHeight(frame);
                    if (!self.frameSampleTime) self.frameSampleTime = NSProcessInfo.processInfo.systemUptime;
                    self.updatesSinceSample += 1;
                }
                CGImageRelease(frame);
            });
        }
    });
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (!self.worker) return NSTerminateNow;
    self.terminating = YES;
    [self stop:nil];
    return NSTerminateLater;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end

int main(void) {
    @autoreleasepool {
        // This process owns the command pipe; a worker exit is handled as a
        // failed write, not an asynchronous process-terminating SIGPIPE.
        signal(SIGPIPE, SIG_IGN);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        __attribute__((objc_precise_lifetime)) PreviewApp *delegate = [PreviewApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
