// Independent AppKit tether UI. No Panasonic application code is used.
// USB runs in an owned child process, never on the AppKit thread. Application
// shutdown requests cancellation and has a bounded child-process fallback.
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import "S1HBorderBeam.h"
#import "S1HCapturedPhotoPreview.h"
#import "S1HControlPanel.h"
#import "S1HInterfaceStyle.h"
#import "S1HPhotoNaming.h"
#import "S1HPreviewView.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

enum { ConnectionRetryInitialDelay = 3, ConnectionRetryMaximumDelay = 30 };
enum { CachedRunLimit = 8, CompletedRunGraceSeconds = 60, MaximumStatusBytes = 2 * 1024 * 1024 };

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

static NSDictionary *readWorkerStatus(NSURL *directory, NSDate **modified) {
    if (!directory) return nil;
    NSURL *url = [directory URLByAppendingPathComponent:@"status.json"];
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > MaximumStatusBytes) {
        close(fd);
        return nil;
    }
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *data = [file readDataUpToLength:(NSUInteger)info.st_size error:NULL];
    [file closeAndReturnError:NULL];
    if (data.length != (NSUInteger)info.st_size) return nil;
    id status = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![status isKindOfClass:NSDictionary.class]) return nil;
    if (modified) *modified = [NSDate dateWithTimeIntervalSince1970:info.st_mtimespec.tv_sec + info.st_mtimespec.tv_nsec / 1e9];
    return status;
}

static NSURL *canonicalDirectory(NSURL *url) {
    NSString *ancestor = url.path;
    if (!url.fileURL || !ancestor.isAbsolutePath) return nil;
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (;;) {
        const char *path = ancestor.fileSystemRepresentation;
        char *resolved = realpath(path, NULL);
        struct stat info;
        if (resolved) {
            BOOL isDirectory = stat(resolved, &info) == 0 && S_ISDIR(info.st_mode);
            NSString *canonical = isDirectory ? [NSFileManager.defaultManager
                stringWithFileSystemRepresentation:resolved length:strlen(resolved)] : nil;
            free(resolved);
            if (!canonical) return nil;
            for (NSString *component in missing.reverseObjectEnumerator)
                canonical = [canonical stringByAppendingPathComponent:component];
            return [NSURL fileURLWithPath:canonical isDirectory:YES];
        }
        // Resolve existing aliases, including /var, before passing a path to
        // the worker. A missing leaf can be created, a dangling link cannot.
        if (errno != ENOENT || lstat(path, &info) == 0 || errno != ENOENT) return nil;
        NSString *component = ancestor.lastPathComponent;
        NSString *parent = ancestor.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:ancestor] || !component.length ||
            [component isEqualToString:@"."] || [component isEqualToString:@".."]) return nil;
        [missing addObject:component];
        ancestor = parent;
    }
}

static NSString *usbLinkLabel(id speed) {
    if (![speed isKindOfClass:NSNumber.class] || [speed longLongValue] <= 0) return nil;
    double mbps = [speed doubleValue] / 1000000.0;
    return mbps >= 1000 ? [NSString stringWithFormat:@"USB %.3g Gbps", mbps / 1000.0] :
        [NSString stringWithFormat:@"USB %.3g Mbps", mbps];
}

static NSNumber *cameraServiceInterfaceID(NSDictionary *snapshot) {
    id interfaceID = snapshot[@"interface_registry_id"];
    if (![snapshot[@"device_model_state"] isEqual:@"confirmed"] ||
        ![snapshot[@"s1h_device_count"] isEqual:@1] || ![snapshot[@"s1h_interface_count"] isEqual:@1] ||
        ![interfaceID isKindOfClass:NSNumber.class] || [interfaceID unsignedLongLongValue] == 0) return nil;
    return interfaceID;
}

static NSArray<NSString *> *cameraServiceReleaseArguments(NSDictionary *snapshot, NSNumber *interfaceID) {
    NSDictionary *owner = [snapshot[@"owner_process"] isKindOfClass:NSDictionary.class] ? snapshot[@"owner_process"] : nil;
    id pid = owner[@"pid"];
    id startSeconds = owner[@"start_seconds"];
    id startMicros = owner[@"start_microseconds"];
    if (!interfaceID || ![snapshot[@"owner_state"] isEqual:@"confirmed"] ||
        ![owner[@"executable"] isEqual:@"/usr/libexec/ptpcamerad"] || ![pid isKindOfClass:NSNumber.class] ||
        ![pid isEqual:snapshot[@"owner_pid"]] || [pid longLongValue] <= 1 ||
        ![startSeconds isKindOfClass:NSNumber.class] || [startSeconds unsignedLongLongValue] == 0 ||
        ![startMicros isKindOfClass:NSNumber.class] || [startMicros unsignedLongLongValue] >= 1000000) return nil;
    return @[@"--release-camera-service", interfaceID.stringValue, [pid stringValue],
        [startSeconds stringValue], [startMicros stringValue]];
}

@interface PreviewApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) S1HPreviewView *previewView;
@property(nonatomic,strong) NSTextField *stateLabel;
@property(nonatomic,strong) NSTextField *metricsLabel;
@property(nonatomic,strong) NSButton *startButton;
@property(nonatomic,strong) S1HBorderBeam *startButtonBeam;
@property(nonatomic,strong) NSButton *stopButton;
@property(nonatomic,strong) NSButton *reconnectBox;
@property(nonatomic,strong) NSButton *liveViewBox;
@property(nonatomic,strong) NSPopUpButton *qualityPopup;
@property(nonatomic,strong) S1HControlPanel *controlPanel;
@property(nonatomic,strong) NSPipe *commandPipe;
@property(nonatomic,strong) NSURL *saveDirectory;
@property(nonatomic,copy) NSString *photoNamePrefix;
@property(nonatomic,copy) NSDictionary *pendingAction;
@property(nonatomic,copy) NSString *cameraSaveDirectory;
@property(nonatomic,copy) NSString *cameraTransferID;
@property(nonatomic,copy) NSString *cameraTransferStatus;
@property(nonatomic,strong) NSURL *lastSavedPhotoURL;
@property(nonatomic,strong) NSURL *reviewedPhotoURL;
@property(nonatomic,strong) NSURL *reviewImageURL;
@property(nonatomic,strong) id reviewImage;
@property(nonatomic,strong) dispatch_queue_t photoPreviewQueue;
@property(nonatomic) BOOL photoPreviewPending;
@property(nonatomic) BOOL liveViewEnabled;
@property(nonatomic) NSUInteger previewPresentationGeneration;
@property(nonatomic,strong) NSDictionary *currentControls;
@property(nonatomic,strong) NSNumber *cameraBatteryPercent;
@property(nonatomic,copy) NSString *cameraUSBLink;
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
@property(nonatomic,copy) NSString *workerFailureMessage;
@property(nonatomic) BOOL cameraInterfaceUnavailable;
@property(nonatomic,copy) NSString *cameraInterfaceOwner;
@property(nonatomic,strong) NSTask *cameraServiceTask;
@property(nonatomic) BOOL automaticReleaseAttempted;
@property(nonatomic) NSUInteger reconnectDelay;
@property(nonatomic) BOOL workerStopRequested;
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
- (NSPopUpButton *)previewTools {
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(676, 9, 126, 30) pullsDown:YES];
    [button addItemWithTitle:[self text:@"取景与诊断" english:@"View & Tools"]];
    NSArray<NSString *> *titles = @[
        [self text:@"适合窗口" english:@"Fit Window"],
        [self text:@"100% 实际像素" english:@"100% Actual Pixels"],
        [self text:@"200% 放大（可拖动）" english:@"200% Zoom (Drag to Pan)"]
    ];
    for (NSUInteger index = 0; index < titles.count; ++index) {
        NSMenuItem *item = [button.menu addItemWithTitle:titles[index] action:@selector(previewZoomChanged:) keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)index;
        item.state = (NSInteger)index == self.previewView.pixelZoom ? NSControlStateValueOn : NSControlStateValueOff;
    }
    NSMenuItem *grid = [button.menu addItemWithTitle:[self text:@"构图九宫格" english:@"Composition Grid"]
        action:@selector(previewGridChanged:) keyEquivalent:@""];
    grid.target = self;
    grid.state = self.previewView.showsGrid ? NSControlStateValueOn : NSControlStateValueOff;
    [button.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *report = [button.menu addItemWithTitle:[self text:@"相机接口报告…" english:@"Camera Capability Report…"]
        action:@selector(showDeviceCapabilities:) keyEquivalent:@""];
    report.target = self;
    NSMenuItem *release = [button.menu addItemWithTitle:[self text:@"解除系统相机占用…" english:@"Release System Camera Interface…"]
        action:@selector(checkCameraService:) keyEquivalent:@""];
    release.target = self;
    S1HStylePopup(button);
    return button;
}
- (BOOL)canCheckCameraService {
    return self.cameraInterfaceUnavailable && !self.worker && !self.cameraServiceTask && !self.terminating &&
        !self.pendingAction && !self.requiresReview && !self.staleSessionRecoveryRequired;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(checkCameraService:)) return [self canCheckCameraService];
    if (item.action == @selector(previewGridChanged:)) return self.liveViewEnabled;
    return YES;
}
- (NSString *)cameraServiceFailure:(NSDictionary *)snapshot reason:(id)reason {
    if (!snapshot || [reason isEqual:@"inspection_error"])
        return [self text:@"无法核对相机接口的当前占用者。请重试。" english:@"Could not verify the camera interface owner. Try again."];
    if ([reason isEqual:@"camera_apps_running"]) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSDictionary *app in snapshot[@"known_camera_apps"]) {
            id name = app[@"name"];
            if ([name isKindOfClass:NSString.class] && [name length] && ![names containsObject:name])
                [names addObject:name];
        }
        if (names.count)
            return [NSString stringWithFormat:[self text:@"请先退出这些相机或导入应用：%@。"
                english:@"Quit these camera or import apps first: %@."], [names componentsJoinedByString:@", "]];
        return [self text:@"请先退出相机和照片导入软件。" english:@"Quit camera and photo import apps first."];
    }
    if ([reason isEqual:@"other_usb_ptp_interface_present"])
        return [self text:@"检测到其他 USB 相机，未释放系统相机服务。" english:@"Another USB camera is connected. The service was left alone."];
    if ([reason isEqual:@"expected_interface_changed"] || !cameraServiceInterfaceID(snapshot))
        return [self text:@"请确认只连接一台处于 PC(Tether) 模式的 S1H，然后重新检查。"
            english:@"Connect one S1H in PC(Tether) mode, then check again."];
    if ([reason isEqual:@"owner_executable_mismatch"] || [reason isEqual:@"unknown_interface_owner"] ||
        [reason isEqual:@"expected_owner_changed"] ||
        [reason isEqual:@"ownership_or_process_identity_changed"])
        return [self text:@"占用者与可恢复的系统相机服务不匹配。请关闭其他相机软件后重试。"
            english:@"The owner does not match the recoverable system camera service. Quit other camera apps and retry."];
    return [self text:@"系统相机接口未确认释放。请检查占用状态后重试。"
        english:@"The system camera interface was not confirmed released. Check ownership and try again."];
}
- (void)runCameraService:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *, BOOL))completion {
    NSString *helper = [NSBundle.mainBundle pathForResource:@"s1h_camera_service" ofType:nil];
    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.arguments = arguments;
    if (helper) task.executableURL = [NSURL fileURLWithPath:helper];
    if (!helper || ![task launchAndReturnError:nil]) {
        completion(nil, NO);
        return;
    }
    self.cameraServiceTask = task;
    [self setConnectButtonEnabled:NO];
    self.stopButton.enabled = YES;
    self.reconnectBox.enabled = NO;
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = [output.fileHandleForReading readDataToEndOfFileAndReturnError:nil];
        [task waitUntilExit];
        id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL success = task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cameraServiceTask != task) return;
            self.cameraServiceTask = nil;
            if (self.terminating) { [NSApp replyToApplicationShouldTerminate:YES]; return; }
            [self setConnectButtonEnabled:YES];
            self.stopButton.enabled = NO;
            self.reconnectBox.enabled = YES;
            if (self.generation == generation)
                completion([result isKindOfClass:NSDictionary.class] ? result : nil, success);
            else
                self.stateLabel.stringValue = [self text:@"已停止。" english:@"Stopped."];
        });
    });
}
- (void)checkCameraService:(id)sender {
    (void)sender;
    [self inspectCameraServiceAutomatically:NO];
}
- (void)cameraServiceDidFail:(NSDictionary *)snapshot reason:(id)reason automatic:(BOOL)automatic {
    NSString *message = [self cameraServiceFailure:snapshot reason:reason];
    if (automatic) [self scheduleReconnectWithReason:message];
    else self.stateLabel.stringValue = message;
}
- (void)resumeAfterCameraServiceCheckAutomatically:(BOOL)automatic {
    if (automatic) [self launchWorkerClosingStaleSession:NO];
    else [self startConnectionClosingStaleSession:NO];
}
- (void)releaseCameraService:(NSArray<NSString *> *)arguments
                 interfaceID:(NSNumber *)interfaceID
                   automatic:(BOOL)automatic {
    if (automatic) self.automaticReleaseAttempted = YES;
    self.stateLabel.stringValue = [self text:@"正在释放系统相机接口……" english:@"Releasing the system camera interface…"];
    [self runCameraService:arguments completion:^(NSDictionary *result, BOOL success) {
        NSDictionary *fresh = [result[@"inspection"] isKindOfClass:NSDictionary.class] ? result[@"inspection"] : nil;
        id outcome = result[@"status"];
        NSLog(@"S1H camera interface recovery (%@): %@, %@, signals %@",
            automatic ? @"automatic" : @"manual", outcome ?: @"no result", result[@"reason"] ?: @"none",
            result[@"signals_sent"] ?: @[]);
        if (success && ([outcome isEqual:@"released"] || [outcome isEqual:@"not_needed"]) &&
            [cameraServiceInterfaceID(fresh) isEqual:interfaceID] && [fresh[@"owner_state"] isEqual:@"none"]) {
            [self resumeAfterCameraServiceCheckAutomatically:automatic];
            return;
        }
        [self cameraServiceDidFail:fresh reason:result[@"reason"] automatic:automatic];
    }];
}
- (void)inspectCameraServiceAutomatically:(BOOL)automatic {
    if (![self canCheckCameraService] || self.window.attachedSheet) return;
    if (!automatic) self.desiredRunning = NO;
    self.generation += 1;
    self.stateLabel.stringValue = [self text:@"正在检查相机接口占用……" english:@"Checking camera interface ownership…"];
    [self runCameraService:@[@"--inspect"] completion:^(NSDictionary *snapshot, BOOL success) {
        NSNumber *interfaceID = cameraServiceInterfaceID(snapshot);
        id guard = snapshot[@"restart_guard"];
        if (success && interfaceID && [guard isEqual:@"no_owner"] && [snapshot[@"owner_state"] isEqual:@"none"]) {
            if (automatic) [self scheduleReconnectWithReason:nil];
            else [self startConnectionClosingStaleSession:NO];
            return;
        }
        if (!success || !interfaceID || ![guard isEqual:@"opt_in_required"]) {
            [self cameraServiceDidFail:snapshot reason:guard automatic:automatic];
            return;
        }
        NSArray<NSString *> *arguments = cameraServiceReleaseArguments(snapshot, interfaceID);
        if (!arguments) {
            [self cameraServiceDidFail:snapshot reason:@"inspection_error" automatic:automatic];
            return;
        }
        if (automatic) {
            [self releaseCameraService:arguments interfaceID:interfaceID automatic:YES];
            return;
        }
        // The service helper rechecks this exact USB interface and the owning process before sending any signal.
        self.stateLabel.stringValue = [self text:@"S1H 的接口被 macOS 相机服务 ptpcamerad 占用。"
            english:@"The macOS camera service ptpcamerad owns the S1H interface."];
        if (self.window.attachedSheet) return;
        NSAlert *confirmation = [NSAlert new];
        confirmation.alertStyle = NSAlertStyleWarning;
        confirmation.messageText = [self text:@"释放系统相机接口并连接？" english:@"Release the system camera interface and connect?"];
        confirmation.informativeText = [self text:@"请先确认相机空闲、写卡灯已熄灭、没有照片正在导入或传输。操作会结束当前用户的 macOS 相机服务。若服务在正常退出超时后仍独占该接口，可能强制结束该服务。"
            english:@"Confirm that the camera is idle, the card access light is off, and no import or transfer is running. This ends the macOS camera service for your user. If it still owns the interface after a graceful shutdown times out, it may be forced to quit."];
        [confirmation addButtonWithTitle:[self text:@"取消" english:@"Cancel"]];
        [confirmation addButtonWithTitle:[self text:@"释放并连接" english:@"Release and Connect"]];
        [confirmation beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response != NSAlertSecondButtonReturn || ![self canCheckCameraService]) return;
            [self releaseCameraService:arguments interfaceID:interfaceID automatic:NO];
        }];
    }];
}
- (void)previewZoomChanged:(NSMenuItem *)sender {
    self.previewView.pixelZoom = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.previewView.pixelZoom forKey:@"previewPixelZoom"];
    for (NSMenuItem *item in sender.menu.itemArray) {
        if (item.action == @selector(previewZoomChanged:))
            item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
    }
}
- (void)previewGridChanged:(NSMenuItem *)sender {
    self.previewView.showsGrid = !self.previewView.showsGrid;
    sender.state = self.previewView.showsGrid ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:self.previewView.showsGrid forKey:@"previewGrid"];
}
- (void)showDeviceCapabilities:(id)sender {
    (void)sender;
    if (self.window.attachedSheet) return;
    NSDictionary *status = readWorkerStatus(self.outputURL, NULL);
    NSDictionary *device = status[@"device_capabilities"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [self text:@"相机接口报告" english:@"Camera Capability Report"];
    if (![device isKindOfClass:NSDictionary.class]) {
        alert.informativeText = [self canCheckCameraService] && self.workerFailureMessage.length ?
            self.workerFailureMessage : [self text:@"连接相机并等待取景后，可查看相机上报的 PTP 接口。"
                english:@"Connect the camera and wait for live view to inspect the reported PTP capabilities."];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSMutableString *report = [NSMutableString stringWithFormat:@"%@ · PTP\n", device[@"model"] ?: @"DC-S1H"];
    NSString *link = usbLinkLabel(status[@"usb_link_bps"]);
    if (link) [report appendFormat:@"%@\n", link];
    NSNumber *battery = [status[@"battery_percent"] isKindOfClass:NSNumber.class] ? status[@"battery_percent"] : nil;
    if (battery && battery.integerValue >= 0 && battery.integerValue <= 100)
        [report appendFormat:[self text:@"相机电量 %ld%%\n" english:@"Camera battery %ld%%\n"], (long)battery.integerValue];
    NSDictionary<NSString *, NSString *> *labels = @{
        @"operations": [self text:@"操作" english:@"Operations"],
        @"events": [self text:@"事件" english:@"Events"],
        @"properties": [self text:@"设备属性" english:@"Device properties"]
    };
    for (NSString *key in @[@"operations", @"events", @"properties"]) {
        NSArray *values = [device[key] isKindOfClass:NSArray.class] ? device[key] : @[];
        NSMutableArray<NSString *> *codes = [NSMutableArray arrayWithCapacity:values.count];
        for (id value in values) {
            if ([value isKindOfClass:NSNumber.class])
                [codes addObject:[NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]]];
        }
        [report appendFormat:@"\n%@ (%lu)\n%@\n", labels[key], (unsigned long)codes.count,
            codes.count ? [codes componentsJoinedByString:@"  "] : @"—"];
    }
    alert.informativeText = [self text:@"相机上报的 PTP 能力。当前可操作项以拍摄面板为准。"
                                english:@"PTP capabilities reported by the camera. The capture panel shows the controls currently available in this app."];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 532, 270)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    text.editable = NO;
    text.selectable = YES;
    text.verticallyResizable = YES;
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    text.textContainerInset = NSMakeSize(8, 8);
    text.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    text.string = report;
    scroll.documentView = text;
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:[self text:@"关闭" english:@"Close"]];
    [alert addButtonWithTitle:[self text:@"复制报告" english:@"Copy Report"]];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertSecondButtonReturn) return;
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:report forType:NSPasteboardTypeString];
    }];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"liveViewEnabled": @YES}];
    self.liveViewEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"liveViewEnabled"];
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    self.baseOutputURL = [cache URLByAppendingPathComponent:@"S1H Native Preview/experimental" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:self.baseOutputURL withIntermediateDirectories:YES attributes:nil error:NULL];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1160, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"S1H Native Tether";
    self.window.minSize = NSMakeSize(850, 550);
    self.window.titlebarAppearsTransparent = YES;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.delegate = self;

    NSView *content = self.window.contentView;
    NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
    backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    backdrop.material = NSVisualEffectMaterialUnderWindowBackground;
    backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    [content addSubview:backdrop];
    NSRect workspace = [content convertRect:self.window.contentLayoutRect fromView:nil];
    NSView *view = [[NSView alloc] initWithFrame:workspace];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:view];
    CGFloat height = NSHeight(view.bounds);
    self.previewView = [[S1HPreviewView alloc] initWithFrame:NSMakeRect(16, 72, 780, height - 142)];
    self.previewView.pixelZoom = [NSUserDefaults.standardUserDefaults integerForKey:@"previewPixelZoom"];
    self.previewView.showsGrid = self.liveViewEnabled && [NSUserDefaults.standardUserDefaults boolForKey:@"previewGrid"];
    self.previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.previewView];

    NSView *toolbar = [NSView new];
    NSView *toolbarGlass = S1HStyleGlass(NSMakeRect(16, height - 58, NSWidth(view.bounds) - 32, 48),
        toolbar, NSVisualEffectMaterialHeaderView, 12.0);
    toolbarGlass.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:toolbarGlass];
    self.startButton = [NSButton buttonWithTitle:[self text:@"连接" english:@"Connect"] target:self action:@selector(start:)];
    self.startButton.frame = NSMakeRect(12, 9, 94, 30);
    S1HStyleButton(self.startButton);
    [toolbar addSubview:self.startButton];
    self.startButtonBeam = [[S1HBorderBeam alloc] initWithFrame:self.startButton.frame];
    [toolbar addSubview:self.startButtonBeam positioned:NSWindowAbove relativeTo:self.startButton];
    [self setConnectButtonEnabled:YES];
    self.stopButton = [NSButton buttonWithTitle:[self text:@"停止" english:@"Stop"] target:self action:@selector(stop:)];
    self.stopButton.frame = NSMakeRect(118, 9, 94, 30);
    self.stopButton.enabled = NO;
    S1HStyleButton(self.stopButton);
    [toolbar addSubview:self.stopButton];
    self.reconnectBox = [NSButton checkboxWithTitle:[self text:@"断线后重试" english:@"Retry after disconnect"] target:self action:@selector(reconnectChanged:)];
    self.reconnectBox.frame = NSMakeRect(224, 9, 180, 30);
    self.reconnectBox.state = NSControlStateValueOn;
    [toolbar addSubview:self.reconnectBox];
    self.liveViewBox = [NSButton checkboxWithTitle:[self text:@"实时取景" english:@"Live View"] target:self action:@selector(liveViewChanged:)];
    self.liveViewBox.frame = NSMakeRect(410, 9, 98, 30);
    self.liveViewBox.state = self.liveViewEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.liveViewBox.toolTip = [self text:@"关闭实时取景后，显示最近传到 Mac 的照片。" english:@"Turn off live view to review the last photo transferred to the Mac."];
    [toolbar addSubview:self.liveViewBox];
    [self updatePreviewAccessibility];
    self.qualityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(513, 9, 153, 30) pullsDown:NO];
    self.qualityPopup.toolTip = [self text:@"实时取景分辨率" english:@"Live view resolution"];
    [self.qualityPopup addItemsWithTitles:@[[self text:@"保持相机当前分辨率" english:@"Keep camera setting"], [self text:@"标准预览分辨率" english:@"Standard resolution"], [self text:@"最高预览分辨率" english:@"Highest resolution"]]];
    NSString *savedFormat = [NSUserDefaults.standardUserDefaults stringForKey:@"previewFormat"];
    NSInteger formatIndex = 2;
    if ([savedFormat isEqualToString:@"0"]) formatIndex = 1;
    else if ([savedFormat isEqualToString:@"auto"]) formatIndex = 0;
    [self.qualityPopup selectItemAtIndex:formatIndex];
    self.qualityPopup.target = self;
    self.qualityPopup.action = @selector(qualityChanged:);
    S1HStylePopup(self.qualityPopup);
    [toolbar addSubview:self.qualityPopup];
    [toolbar addSubview:[self previewTools]];
    self.controlPanel = [[S1HControlPanel alloc] initWithFrame:NSMakeRect(812, 72, 332, height - 142)];
    self.controlPanel.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    __weak PreviewApp *panelSelf = self;
    self.controlPanel.onCapture = ^(NSString *target) { [panelSelf capturePhotoWithTarget:target]; };
    self.controlPanel.onSetBodyCaptureTarget = ^(NSString *target) { [panelSelf setBodyCaptureTarget:target]; };
    self.controlPanel.onChooseDirectory = ^{ [panelSelf chooseSaveDirectory]; };
    self.controlPanel.onChoosePhotoNaming = ^{ [panelSelf choosePhotoNaming]; };
    self.controlPanel.onSetProperty = ^(NSString *key, NSNumber *raw) { [panelSelf setCameraProperty:key value:raw]; };
    self.controlPanel.onRefresh = ^{ [panelSelf refreshCameraControls]; };
    self.controlPanel.onFocusStep = ^(NSString *direction) { [panelSelf stepRemoteFocus:direction]; };
    self.controlPanel.onRevealSavedPhoto = ^{ [panelSelf revealSavedPhoto]; };
    NSString *savedDirectory = [NSUserDefaults.standardUserDefaults stringForKey:@"photoSaveDirectory"];
    NSString *savedPrefix = [NSUserDefaults.standardUserDefaults stringForKey:@"photoNamePrefix"] ?: @"";
    self.photoNamePrefix = s1h_photo_prefix_valid(savedPrefix) ? savedPrefix : @"";
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
    self.photoPreviewQueue = dispatch_queue_create("s1h.photo-preview.decode", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    self.timer = [NSTimer timerWithTimeInterval:0.125 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    self.previewTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(refreshPreview:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
    [self startConnectionClosingStaleSession:NO];
}
- (void)start:(id)sender {
    (void)sender;
    if (self.worker || self.cameraServiceTask || self.pendingAction || self.terminating || self.window.attachedSheet) return;
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
    if (self.worker || self.cameraServiceTask || self.pendingAction || self.terminating) return;
    if (self.requiresReview) [self.controlPanel setResultMessage:nil];
    self.requiresReview = NO;
    self.automaticReleaseAttempted = NO;
    self.reconnectDelay = 0;
    self.stateLabel.textColor = NSColor.labelColor;
    self.desiredRunning = YES;
    self.generation += 1;
    [self launchWorkerClosingStaleSession:closeStaleSession];
}
- (NSURL *)workerSessionsDirectory {
    // Older builds only prune UUID folders directly under baseOutputURL.
    return [self.baseOutputURL URLByAppendingPathComponent:@"sessions" isDirectory:YES];
}
- (void)pruneOldRuns {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self workerSessionsDirectory]
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
    NSUInteger remaining = runs.count;
    NSDate *oldEnough = [NSDate dateWithTimeIntervalSinceNow:-CompletedRunGraceSeconds];
    for (NSDictionary *run in runs) {
        if (remaining <= CachedRunLimit) break;
        NSURL *url = run[@"url"];
        if ([url.lastPathComponent isEqualToString:self.outputURL.lastPathComponent]) continue;
        NSDate *modified = nil;
        id state = readWorkerStatus(url, &modified)[@"status"];
        // Other installed copies can own a live run in the same cache, and
        // a newly finished worker still needs its result read by its app.
        if (([state isEqual:@"error"] || [state isEqual:@"stopped"]) &&
            [modified compare:oldEnough] == NSOrderedAscending &&
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL]) remaining--;
    }
}
- (void)launchWorkerClosingStaleSession:(BOOL)closeStaleSession {
    if (!self.desiredRunning || self.worker || self.cameraServiceTask || self.terminating || self.requiresReview ||
        (self.staleSessionRecoveryRequired && !closeStaleSession)) return;
    NSString *helper = [NSBundle.mainBundle pathForResource:@"s1h_native_preview" ofType:nil];
    if (!helper || ![NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
        self.stateLabel.stringValue = [self text:@"缺少实验通信程序。" english:@"The experimental USB worker is missing."];
        self.desiredRunning = NO;
        return;
    }
    self.stateLabel.stringValue = [self text:@"正在连接 S1H……" english:@"Connecting to the S1H…"];
    self.stateLabel.toolTip = nil;
    self.outputURL = [[self workerSessionsDirectory] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.outputURL withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        self.stateLabel.stringValue = [self text:@"无法创建本次预览缓存目录。" english:@"Could not create this preview session's cache."];
        self.desiredRunning = NO;
        return;
    }
    self.cameraReady = NO;
    self.captureAvailable = NO;
    self.workerFailureMessage = nil;
    self.cameraInterfaceUnavailable = NO;
    self.cameraInterfaceOwner = nil;
    self.pendingAction = nil;
    self.cameraTransferID = nil;
    self.cameraTransferStatus = nil;
    self.currentControls = @{};
    [self.controlPanel setRemoteFocusAvailable:NO];
    self.cameraBatteryPercent = nil;
    self.cameraUSBLink = nil;
    [self.controlPanel setTransferProgressMessage:nil fraction:-1.0];
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel updateCapabilities:@{} busy:NO];
    if (self.liveViewEnabled) [self.previewView displayFrame:NULL];
    self.lastFrameIdentity = (PreviewFrameIdentity){0};
    self.viewWidth = 0;
    self.viewHeight = 0;
    self.updatesSinceSample = 0;
    self.frameSampleTime = 0;
    self.updatesPerSecond = -1;
    self.metricsLabel.stringValue = @"—";
    self.metricsLabel.toolTip = nil;
    self.metricsLabel.textColor = NSColor.secondaryLabelColor;
    [self pruneOldRuns];
    [self setConnectButtonEnabled:NO];
    self.stopButton.enabled = YES;
    self.liveViewBox.enabled = NO;
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
    if (!self.liveViewEnabled) [arguments addObject:@"--no-live-view"];
    if (self.photoNamePrefix.length) [arguments addObjectsFromArray:@[@"--photo-name-prefix", self.photoNamePrefix]];
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
    self.workerStopRequested = NO;
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
        self.liveViewBox.enabled = YES;
        self.qualityPopup.enabled = YES;
        self.desiredRunning = NO;
    }
}
- (void)workerFinished:(NSTask *)finished {
    if (self.worker != finished) return;
    // Read a final action result before tearing down this run's status path.
    [self refresh:nil];
    if (self.pendingAction) {
        id kind = self.pendingAction[@"action"];
        if ([kind isEqual:@"capture"] || [kind isEqual:@"set_body_capture_target"]) self.requiresReview = YES;
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
    self.workerStopRequested = NO;
    self.cameraReady = NO;
    self.captureAvailable = NO;
    self.metricsLabel.stringValue = @"—";
    self.pendingAction = nil;
    self.cameraSaveDirectory = nil;
    self.cameraTransferStatus = nil;
    [self.controlPanel setTransferProgressMessage:nil fraction:-1.0];
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel updateCapabilities:self.currentControls ?: @{} busy:NO];
    [self setConnectButtonEnabled:YES];
    self.stopButton.enabled = NO;
    self.liveViewBox.enabled = !self.terminating;
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
    if (self.workerFailureMessage.length) {
        self.metricsLabel.stringValue = self.workerFailureMessage;
        self.metricsLabel.toolTip = self.workerFailureMessage;
        self.metricsLabel.textColor = self.cameraInterfaceOwner.length ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    }
    if (!self.automaticReleaseAttempted && self.reconnectBox.state == NSControlStateValueOn &&
        [self.cameraInterfaceOwner isEqualToString:@"ptpcamerad"] && [self canCheckCameraService] && !self.window.attachedSheet) {
        [self inspectCameraServiceAutomatically:YES];
        return;
    }
    [self scheduleReconnectWithReason:nil];
}
- (void)scheduleReconnectWithReason:(NSString *)reason {
    if (!self.desiredRunning || self.terminating) return;
    if (self.reconnectBox.state != NSControlStateValueOn) {
        self.desiredRunning = NO;
        self.stateLabel.stringValue = [self text:@"连接已结束，可再次点击“连接”。" english:@"The connection ended. Click Connect to try again."];
        return;
    }
    self.reconnectDelay = self.reconnectDelay ? MIN(self.reconnectDelay * 2, ConnectionRetryMaximumDelay) : ConnectionRetryInitialDelay;
    NSString *format = [self text:@"等待相机，%lu 秒后重试。" english:@"Waiting for the camera. Retrying in %lu seconds."];
    NSString *waiting = [NSString stringWithFormat:format, (unsigned long)self.reconnectDelay];
    self.stateLabel.stringValue = reason.length ? [NSString stringWithFormat:@"%@ %@", reason, waiting] : waiting;
    self.stateLabel.toolTip = reason;
    self.stopButton.enabled = YES;
    NSUInteger generation = self.generation;
    __weak PreviewApp *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.reconnectDelay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PreviewApp *app = weakSelf;
        if (app.generation == generation && app.desiredRunning && app.reconnectBox.state == NSControlStateValueOn)
            [app launchWorkerClosingStaleSession:NO];
    });
}
- (void)reconnectChanged:(id)sender {
    (void)sender;
    if (self.reconnectBox.state == NSControlStateValueOff && !self.worker && !self.cameraServiceTask) [self stop:nil];
}
- (void)qualityChanged:(id)sender {
    (void)sender;
    NSString *format = self.qualityPopup.indexOfSelectedItem == 2 ? @"max" : (self.qualityPopup.indexOfSelectedItem == 1 ? @"0" : @"auto");
    [NSUserDefaults.standardUserDefaults setObject:format forKey:@"previewFormat"];
}
- (void)updatePreviewAccessibility {
    [self.previewView setAccessibilityLabel:self.liveViewEnabled
        ? [self text:@"相机实时取景" english:@"Camera live view"]
        : [self text:@"最近拍摄照片" english:@"Last captured photo"]];
}
- (void)showLiveView:(BOOL)enabled {
    self.liveViewBox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.liveViewEnabled == enabled) return;
    self.liveViewEnabled = enabled;
    self.previewPresentationGeneration += 1;
    self.viewWidth = self.viewHeight = 0;
    self.updatesSinceSample = 0;
    self.frameSampleTime = 0;
    self.updatesPerSecond = -1;
    self.previewView.showsGrid = enabled && [NSUserDefaults.standardUserDefaults boolForKey:@"previewGrid"];
    [self updatePreviewAccessibility];
    [self.previewView displayFrame:enabled ? NULL : (__bridge CGImageRef)self.reviewImage];
    if (!enabled) {
        [self loadPhotoPreview];
        if (!self.worker && !self.desiredRunning) [self refreshPhotoReviewMetrics];
    } else if (!self.worker && !self.desiredRunning) {
        self.metricsLabel.stringValue = @"—";
    }
}
- (void)liveViewChanged:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    if (!self.worker && !self.terminating) {
        [self showLiveView:enabled];
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"liveViewEnabled"];
        return;
    }
    sender.state = self.liveViewEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if ([self sendAction:@{@"action": @"set_live_view", @"enabled": @(enabled)}]) sender.enabled = NO;
}
- (void)loadPhotoPreview {
    NSURL *photoURL = self.lastSavedPhotoURL;
    if (self.liveViewEnabled || self.photoPreviewPending || !photoURL || [photoURL isEqual:self.reviewedPhotoURL]) return;
    self.photoPreviewPending = YES;
    dispatch_async(self.photoPreviewQueue, ^{
        @autoreleasepool {
            id image = CFBridgingRelease(S1HCopyCapturedPhotoPreview(photoURL));
            dispatch_async(dispatch_get_main_queue(), ^{
                self.photoPreviewPending = NO;
                if ([photoURL isEqual:self.lastSavedPhotoURL]) {
                    self.reviewedPhotoURL = photoURL;
                    if (image) {
                        self.reviewImage = image;
                        self.reviewImageURL = photoURL;
                        if (!self.liveViewEnabled) [self.previewView displayFrame:(__bridge CGImageRef)image];
                    }
                }
                [self loadPhotoPreview];
            });
        }
    });
}
- (void)refreshPhotoReviewMetrics {
    NSString *message = nil;
    if (self.photoPreviewPending)
        message = [self text:@"正在准备照片预览…" english:@"Preparing photo preview…"];
    else if ([self.lastSavedPhotoURL isEqual:self.reviewedPhotoURL] && ![self.reviewImageURL isEqual:self.lastSavedPhotoURL])
        message = [self text:@"照片已保存，无法生成预览" english:@"Photo saved. Preview unavailable."];
    else
        message = self.reviewImageURL.lastPathComponent ?: [self text:@"传到 Mac 的照片会显示在这里" english:@"Photos transferred to the Mac appear here"];
    self.metricsLabel.stringValue = self.cameraUSBLink ? [NSString stringWithFormat:@"%@    %@", message, self.cameraUSBLink] : message;
}
- (void)stop:(id)sender {
    (void)sender;
    if (self.worker && self.workerStopRequested) return;
    self.desiredRunning = NO;
    self.cameraReady = NO;
    [self.controlPanel setTransferProgressMessage:nil fraction:-1.0];
    [self.controlPanel setCameraReady:NO];
    [self.controlPanel setCaptureAvailable:NO];
    [self.controlPanel setBusy:self.pendingAction != nil || [self cameraTransferInProgress]];
    self.generation += 1;
    NSTask *serviceTask = self.cameraServiceTask;
    if (serviceTask) {
        self.stopButton.enabled = NO;
        self.stateLabel.stringValue = [self text:@"正在停止接口恢复……" english:@"Stopping interface recovery…"];
        if (serviceTask.running) [serviceTask terminate];
        return;
    }
    NSTask *task = self.worker;
    if (!task) {
        [self setConnectButtonEnabled:YES];
        self.stopButton.enabled = NO;
        self.liveViewBox.enabled = YES;
        self.metricsLabel.stringValue = @"—";
        self.metricsLabel.toolTip = nil;
        self.metricsLabel.textColor = NSColor.secondaryLabelColor;
        if (self.requiresReview) [self showCaptureReviewRequired];
        else if (self.staleSessionRecoveryRequired) [self showStaleSessionRecoveryRequired];
        else self.stateLabel.stringValue = [self text:@"已停止。" english:@"Stopped."];
        return;
    }
    self.workerStopRequested = YES;
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
    NSURL *resolved = canonicalDirectory(url);
    NSString *cache = canonicalDirectory(self.baseOutputURL).path;
    if (!resolved || !cache.length) return nil;
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
- (void)savePhotoNamePrefix:(NSString *)prefix {
    self.photoNamePrefix = prefix;
    [NSUserDefaults.standardUserDefaults setObject:prefix forKey:@"photoNamePrefix"];
    [self.controlPanel setResultMessage:[self text:@"已更新照片文件命名。" english:@"Updated photo file naming."]];
}
- (void)choosePhotoNaming {
    if (self.pendingAction || [self cameraTransferInProgress] || self.terminating || self.window.attachedSheet) return;
    NSAlert *panel = [NSAlert new];
    panel.messageText = [self text:@"照片文件命名" english:@"Photo File Naming"];
    panel.informativeText = [self text:@"填入前缀后，保存到 Mac 的照片会自动编号，例如「样片_0001.RW2」。留空则沿用机身文件名。"
        english:@"Enter a prefix to number photos saved to the Mac, such as Sample_0001.RW2. Leave it blank to keep camera filenames."];
    [panel addButtonWithTitle:[self text:@"保存" english:@"Save"]];
    [panel addButtonWithTitle:[self text:@"取消" english:@"Cancel"]];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 270, 24)];
    field.placeholderString = [self text:@"文件名前缀" english:@"Filename prefix"];
    field.accessibilityLabel = field.placeholderString;
    field.stringValue = self.photoNamePrefix;
    panel.accessoryView = field;
    panel.window.initialFirstResponder = field;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *prefix = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!s1h_photo_prefix_valid(prefix)) {
            [self.controlPanel setWarningMessage:[self text:@"请输入较短的前缀，避免用点开头、路径符号或控制字符。"
                english:@"Use a shorter prefix without a leading dot, path punctuation, or control characters."]];
        } else if (!self.worker) {
            [self savePhotoNamePrefix:prefix];
        } else if (self.pendingAction || [self cameraTransferInProgress] || !self.cameraReady) {
            [self.controlPanel setWarningMessage:[self text:@"请等相机空闲后再更改照片文件命名。" english:@"Wait until the camera is ready before changing photo file naming."]];
        } else if ([self sendAction:@{@"action": @"set_photo_name_prefix", @"prefix": prefix}]) {
            [self.controlPanel setResultMessage:[self text:@"正在更新照片文件命名……" english:@"Updating photo file naming…"]];
        }
    }];
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
    if ([self sendAction:@{@"action": @"capture", @"directory": directory.path, @"target": target}]) {
        [self.controlPanel setResultMessage:nil];
        [self showCaptureProgress:@{}];
    }
}
- (void)setCameraProperty:(NSString *)key value:(NSNumber *)value {
    if ([self sendAction:@{@"action": @"set", @"property": key, @"value": value}])
        [self.controlPanel setResultMessage:[self text:@"正在设置并回读确认……" english:@"Applying and verifying the setting…"]];
    else [self.controlPanel updateCapabilities:self.currentControls ?: @{} busy:self.pendingAction != nil || [self cameraTransferInProgress]];
}
- (void)setBodyCaptureTarget:(NSString *)target {
    if ([self sendAction:@{@"action": @"set_body_capture_target", @"target": target}])
        [self.controlPanel setResultMessage:[self text:@"正在更改并回读机身存储目标……" english:@"Applying and verifying the camera storage target…"]];
}
- (void)refreshCameraControls {
    if ([self sendAction:@{@"action": @"refresh"}])
        [self.controlPanel setResultMessage:[self text:@"正在读取相机实际设置……" english:@"Reading the camera settings…"]];
}
- (void)stepRemoteFocus:(NSString *)direction {
    if ([self sendAction:@{@"action":@"focus_step", @"direction":direction}])
        [self.controlPanel setResultMessage:[self text:@"正在微调焦点……" english:@"Adjusting focus…"]];
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
    if (count) {
        [self.controlPanel setLastSavedPath:self.lastSavedPhotoURL.path];
        [self loadPhotoPreview];
    }
    return count;
}
- (BOOL)cameraTransferInProgress {
    return [self.cameraTransferStatus isEqualToString:@"busy"];
}
- (void)showCaptureProgress:(NSDictionary *)snapshot {
    if (!snapshot) {
        [self.controlPanel setTransferProgressMessage:nil fraction:-1.0];
        return;
    }
    NSString *phase = [snapshot[@"phase"] isKindOfClass:NSString.class] ? snapshot[@"phase"] : @"preparing";
    NSNumber *received = [snapshot[@"downloaded_bytes"] isKindOfClass:NSNumber.class] ? snapshot[@"downloaded_bytes"] : nil;
    NSNumber *total = [snapshot[@"total_bytes"] isKindOfClass:NSNumber.class] ? snapshot[@"total_bytes"] : nil;
    double fraction = -1.0;
    if (received && isfinite(total.doubleValue) && total.doubleValue > 0.0 &&
        received.doubleValue >= 0.0 && received.doubleValue <= total.doubleValue)
        fraction = received.doubleValue / total.doubleValue;

    NSString *message = [self text:@"正在准备拍摄…" english:@"Preparing to capture…"];
    if ([phase isEqualToString:@"shutter"]) {
        message = [self text:@"正在触发快门…" english:@"Triggering the shutter…"];
    } else if ([phase isEqualToString:@"waiting"]) {
        message = [self text:@"等待相机交付原片…" english:@"Waiting for the original…"];
    } else if ([phase isEqualToString:@"verifying"]) {
        message = [self text:@"正在校验并保存…" english:@"Verifying and saving…"];
    } else if ([phase isEqualToString:@"download"]) {
        message = [self text:@"正在传输原片…" english:@"Transferring the original…"];
        if (fraction >= 0.0) {
            NSNumber *fileIndex = [snapshot[@"file_index"] isKindOfClass:NSNumber.class] ? snapshot[@"file_index"] : nil;
            NSInteger index = fileIndex.integerValue;
            NSString *label = index > 0
                ? [NSString stringWithFormat:[self text:@"文件 %ld" english:@"File %ld"], (long)index]
                : [self text:@"传输" english:@"Transfer"];
            message = [NSString stringWithFormat:@"%@ · %.1f / %.1f MB · %ld%%", label,
                received.doubleValue / 1e6, total.doubleValue / 1e6, (long)floor(fraction * 100.0)];
        }
    }
    if (![phase isEqualToString:@"download"] && ![phase isEqualToString:@"verifying"]) fraction = -1.0;
    [self.controlPanel setTransferProgressMessage:message fraction:fraction];
}
- (void)updateCaptureProgressForAction:(NSDictionary *)action transfer:(NSDictionary *)transfer {
    NSDictionary *progress = nil;
    if (self.desiredRunning) {
        if ([self cameraTransferInProgress] && [transfer[@"status"] isEqual:@"busy"] &&
            [transfer[@"id"] isEqual:self.cameraTransferID]) {
            progress = transfer;
        } else if ([self.pendingAction[@"action"] isEqual:@"capture"]) {
            BOOL matchingAction = [action[@"id"] isEqual:self.pendingAction[@"id"]] && [action[@"status"] isEqual:@"busy"];
            progress = matchingAction ? action : @{};
        }
    }
    [self showCaptureProgress:progress];
}
- (void)showCameraTransferStatus:(NSDictionary *)transfer previousDirectory:(NSString *)previousDirectory {
    NSString *identifier = [transfer[@"id"] isKindOfClass:NSString.class] ? transfer[@"id"] : nil;
    NSString *result = [transfer[@"status"] isKindOfClass:NSString.class] ? transfer[@"status"] : nil;
    if (!identifier.length || !result || ![@[@"busy", @"ok", @"error", @"outcome_unknown"] containsObject:result]) return;
    if ([self.cameraTransferID isEqualToString:identifier] && [self.cameraTransferStatus isEqualToString:result]) return;
    self.cameraTransferID = identifier;
    self.cameraTransferStatus = result;
    if ([self cameraTransferInProgress]) {
        [self.controlPanel setResultMessage:nil];
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
    if (![@[@"ok", @"rejected", @"error", @"outcome_unknown"] containsObject:result]) return;
    self.pendingAction = nil;
    BOOL captured = [pending[@"action"] isEqual:@"capture"];
    BOOL ok = [result isEqualToString:@"ok"];
    if ([pending[@"action"] isEqual:@"set_live_view"]) {
        if (ok && [pending[@"enabled"] boolValue] == self.liveViewEnabled) {
            [NSUserDefaults.standardUserDefaults setBool:self.liveViewEnabled forKey:@"liveViewEnabled"];
            [self.controlPanel setResultMessage:nil];
        } else {
            [self.controlPanel setWarningMessage:[self text:@"相机未确认实时取景切换。请在相机空闲时重试。"
                english:@"The camera did not confirm the live view change. Retry when it is idle."]];
        }
        return;
    }
    if ([pending[@"action"] isEqual:@"focus_step"]) {
        if (ok) [self.controlPanel setResultMessage:[self text:@"相机已确认本次调焦命令。" english:@"The camera accepted the focus adjustment."]];
        else if ([result isEqual:@"rejected"])
            [self.controlPanel setWarningMessage:[self text:@"请将机身设为 MF，再刷新相机参数。"
                english:@"Set the camera to MF and refresh the camera settings."]];
        else [self.controlPanel setWarningMessage:detail];
        return;
    }
    if ([pending[@"action"] isEqual:@"set_body_capture_target"]) {
        if (ok) {
            [self.controlPanel setResultMessage:[self text:@"机身快门的存储目标已回读确认。" english:@"Camera shutter storage target confirmed."]];
        } else if ([result isEqualToString:@"outcome_unknown"]) {
            self.requiresReview = YES;
            self.desiredRunning = NO;
            [self.controlPanel setWarningMessage:[self text:@"无法确认机身快门的存储目标。请在机身检查后再连接。"
                english:@"The camera shutter storage target is unconfirmed. Check the camera before reconnecting."]];
        } else {
            NSString *message = [self text:@"相机未确认存储目标更改。请检查存储卡并刷新参数。"
                english:@"The camera did not confirm the storage target change. Check the card and refresh camera settings."];
            [self.controlPanel setWarningMessage:detail.length ? [NSString stringWithFormat:@"%@ %@", message, detail] : message];
        }
        return;
    }
    if ([pending[@"action"] isEqual:@"set_photo_name_prefix"]) {
        if (ok) [self savePhotoNamePrefix:pending[@"prefix"]];
        else [self.controlPanel setWarningMessage:[self text:@"照片文件命名未能更新，请重新检查前缀。"
            english:@"Photo file naming could not be updated. Check the prefix and try again."]];
        return;
    }
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
    NSDictionary *status = readWorkerStatus(self.outputURL, NULL);
    if (!status) return;
    NSString *state = [status[@"status"] isKindOfClass:NSString.class] ? status[@"status"] : @"";
    NSString *message = [status[@"message"] isKindOfClass:NSString.class] ? status[@"message"] : state;
    if ([state isEqualToString:@"error"] && message.length && ![message isEqualToString:state]) {
        if ([message isEqualToString:@"Connect exactly one DC-S1H in PC(Tether) mode; its registry identity must be readable."])
            message = [self text:@"请连接一台 DC-S1H，并在机身选择 PC(Tether)。" english:message];
        else if ([message isEqualToString:@"Camera interface unavailable. Close other camera/import software first."]) {
            self.cameraInterfaceUnavailable = YES;
            id owner = status[@"usb_interface_owner"];
            self.cameraInterfaceOwner = [owner isKindOfClass:NSString.class] ? owner : nil;
            if (self.cameraInterfaceOwner.length) {
                BOOL systemService = [self.cameraInterfaceOwner isEqualToString:@"ptpcamerad"];
                NSString *name = systemService ?
                    [self text:@"macOS 相机服务（ptpcamerad）" english:@"macOS camera service (ptpcamerad)"] : self.cameraInterfaceOwner;
                NSString *format = systemService ?
                    [self text:@"相机接口被 %@ 占用。取景与诊断 → 解除系统相机占用…"
                        english:@"Camera interface in use by %@. View & Tools → Release System Camera Interface…"] :
                    [self text:@"相机接口被 %@ 占用。请在该软件中断开相机，再重新连接。"
                        english:@"Camera interface in use by %@. Disconnect the camera in that app, then reconnect."];
                message = [NSString stringWithFormat:format, name];
            } else {
                message = [self text:@"相机接口无法打开。取景与诊断 → 解除系统相机占用…"
                    english:@"Unable to open the camera interface. View & Tools → Release System Camera Interface…"];
            }
        }
        self.workerFailureMessage = message;
    }
    NSDictionary *controls = [status[@"controls"] isKindOfClass:NSDictionary.class] ? status[@"controls"] : @{};
    NSDictionary *focus = [controls[@"focus_mode"] isKindOfClass:NSDictionary.class] ? controls[@"focus_mode"] : nil;
    [self.controlPanel setRemoteFocusAvailable:[focus[@"current"] isEqual:@3]];
    NSDictionary *cameraStorage = [status[@"capture_storage"] isKindOfClass:NSDictionary.class] ? status[@"capture_storage"] : nil;
    [self.controlPanel setCameraStorage:cameraStorage];
    NSNumber *battery = [status[@"battery_percent"] isKindOfClass:NSNumber.class] ? status[@"battery_percent"] : nil;
    self.cameraBatteryPercent = battery && battery.integerValue >= 0 && battery.integerValue <= 100 ? battery : nil;
    self.cameraUSBLink = usbLinkLabel(status[@"usb_link_bps"]);
    BOOL controlsChanged = ![self.currentControls isEqualToDictionary:controls];
    self.currentControls = controls;
    BOOL workerRequiresReview = [status[@"requires_review"] isEqual:@YES];
    if (workerRequiresReview) {
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
    id liveViewState = status[@"live_view_enabled"];
    if ([state isEqualToString:@"previewing"] && self.desiredRunning && [liveViewState isKindOfClass:NSNumber.class])
        [self showLiveView:[liveViewState boolValue]];
    NSString *previousDirectory = self.cameraSaveDirectory;
    if (action) [self showActionStatus:action];
    NSDictionary *transfer = [status[@"camera_transfer"] isKindOfClass:NSDictionary.class] ? status[@"camera_transfer"] : nil;
    if (transfer) [self showCameraTransferStatus:transfer previousDirectory:previousDirectory];
    [self updateCaptureProgressForAction:action transfer:transfer];
    self.cameraReady = self.desiredRunning && !self.requiresReview && [state isEqualToString:@"previewing"];
    if (self.cameraReady && (!self.liveViewEnabled || ([status[@"frames"] isKindOfClass:NSNumber.class] &&
        [status[@"frames"] unsignedIntegerValue] > 0))) {
        self.reconnectDelay = 0;
        self.automaticReleaseAttempted = NO;
    }
    self.captureAvailable = [status[@"capture_available"] isEqual:@YES];
    [self.controlPanel setCameraReady:self.cameraReady];
    [self.controlPanel setCaptureAvailable:self.cameraReady && self.captureAvailable];
    BOOL busy = self.pendingAction != nil || [action[@"status"] isEqual:@"busy"] || [self cameraTransferInProgress];
    self.liveViewBox.enabled = self.cameraReady && !busy;
    if (controlsChanged) [self.controlPanel updateCapabilities:controls busy:busy];
    else [self.controlPanel setBusy:busy];
    if (self.requiresReview) {
        // The worker exits on its own when it requests review. A file check
        // can also request review in the app while the session is healthy.
        // Only stop that session once outstanding transfers have finished.
        if (!workerRequiresReview && !blockedByStaleSession && !self.workerStopRequested && !busy && self.captureAvailable &&
            [state isEqualToString:@"previewing"] && self.worker.running) [self stop:nil];
        [self showCaptureReviewRequired];
    }
    else if (blockedByStaleSession) [self showStaleSessionRecoveryRequired];
    else if ([state isEqualToString:@"previewing"] && self.desiredRunning) {
        if ([self.pendingAction[@"action"] isEqual:@"set_live_view"]) {
            self.stateLabel.stringValue = [self text:@"正在切换实时取景…" english:@"Switching live view…"];
        } else if (!self.liveViewEnabled) {
            if ([self cameraTransferInProgress] || [self.pendingAction[@"action"] isEqual:@"capture"])
                self.stateLabel.stringValue = [self text:@"正在接收照片 · 实时取景已关闭" english:@"Receiving photo · Live view off"];
            else
                self.stateLabel.stringValue = [self text:@"照片回看 · 实时取景已关闭" english:@"Photo review · Live view off"];
            [self refreshPhotoReviewMetrics];
        } else if ([self cameraTransferInProgress]) {
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
    NSMutableString *metrics = [NSMutableString stringWithFormat:@"%lu × %lu", (unsigned long)self.viewWidth, (unsigned long)self.viewHeight];
    if (self.updatesPerSecond >= 0) {
        [metrics appendFormat:[self text:@"    取景更新 %.1f 次/秒" english:@"    %.1f view updates/s"], self.updatesPerSecond];
    }
    if (self.cameraUSBLink) [metrics appendFormat:@"    %@", self.cameraUSBLink];
    if (self.cameraBatteryPercent)
        [metrics appendFormat:[self text:@"    电量 %ld%%" english:@"    Battery %ld%%"], (long)self.cameraBatteryPercent.integerValue];
    self.metricsLabel.stringValue = metrics;
}
- (BOOL)canRefreshPreview {
    return self.liveViewEnabled && self.worker && self.desiredRunning && self.window.visible && !self.window.miniaturized &&
        ![self.pendingAction[@"action"] isEqual:@"capture"] && ![self cameraTransferInProgress];
}
- (void)refreshPreview:(NSTimer *)timer {
    (void)timer;
    if (self.framePending || ![self canRefreshPreview]) return;
    NSURL *runURL = self.outputURL;
    NSURL *frameURL = [runURL URLByAppendingPathComponent:@"latest.jpg"];
    PreviewFrameIdentity previous = self.lastFrameIdentity;
    NSUInteger generation = self.generation;
    NSUInteger presentation = self.previewPresentationGeneration;
    self.framePending = YES;
    dispatch_async(self.previewQueue, ^{
        @autoreleasepool {
            PreviewFrameIdentity identity = {0};
            CGImageRef frame = copyLatestPreviewFrame(frameURL, previous, &identity);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.framePending = NO;
                if (!frame) return;
                if ([self canRefreshPreview] && self.generation == generation &&
                    self.previewPresentationGeneration == presentation && [self.outputURL isEqual:runURL]) {
                    [self.previewView displayFrame:frame];
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
    if (!self.worker && !self.cameraServiceTask) return NSTerminateNow;
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
