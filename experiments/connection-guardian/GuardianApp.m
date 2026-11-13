// Independent menu-bar UI. Camera and process work belongs to the asynchronous
// controller; this file never opens a USB interface or sends camera commands.
#import <AppKit/AppKit.h>
#import "GuardianController.h"

@interface GuardianApp : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) GuardianController *controller;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *phaseItem;
@property(nonatomic, strong) NSMenuItem *messageItem;
@property(nonatomic, strong) NSMenuItem *cameraItem;
@property(nonatomic, strong) NSMenuItem *tetherItem;
@property(nonatomic, strong) NSMenuItem *shootingItem;
@property(nonatomic, strong) NSMenuItem *ownerItem;
@property(nonatomic, strong) NSMenuItem *endItem;
@property(nonatomic, strong) NSMenuItem *startItem;
@property(nonatomic, strong) NSMenuItem *pauseItem;
@property(nonatomic, strong) NSMenuItem *reconnectItem;
@property(nonatomic, strong) NSMenuItem *forceItem;
@property(nonatomic, strong) NSMenuItem *openItem;
@property(nonatomic, strong) NSMenuItem *logsItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSWindow *statusWindow;
@property(nonatomic, strong) NSTextField *windowUSB;
@property(nonatomic, strong) NSTextField *windowTether;
@property(nonatomic, strong) NSTextField *windowShooting;
@property(nonatomic, strong) NSTextField *windowGuardian;
@property(nonatomic, strong) NSButton *windowStart;
@property(nonatomic, strong) NSButton *windowEnd;
@property(nonatomic, strong) NSButton *windowPause;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic) BOOL chinese;
@property(nonatomic) BOOL terminating;
@end

@implementation GuardianApp
- (NSString *)text:(NSString *)zh english:(NSString *)en {
    return self.chinese ? zh : en;
}
- (NSString *)string:(id)value {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
- (BOOL)snapshotBool:(NSString *)key {
    id value = self.snapshot[key];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (NSString *)menuText:(NSString *)text {
    NSString *singleLine = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
        componentsJoinedByString:@" "];
    if (singleLine.length <= 110) return singleLine;
    NSRange range = [singleLine rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 109)];
    return [[singleLine substringWithRange:range] stringByAppendingString:@"…"];
}
- (void)setInfo:(NSMenuItem *)item text:(NSString *)text {
    item.title = [self menuText:text];
    item.toolTip = text;
}
- (NSMenuItem *)informationItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    item.enabled = NO;
    [self.menu addItem:item];
    return item;
}
- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [self.menu addItem:item];
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    self.snapshot = @{ @"state": @"idle", @"desired_running": @NO, @"busy": @NO };
    self.menu = [NSMenu new];
    self.menu.autoenablesItems = NO;
    self.menu.minimumWidth = 320;
    [self informationItem:[self text:@"LUMIX 连接守护" english:@"LUMIX Connection Guardian"]];
    self.phaseItem = [self informationItem:@""];
    self.messageItem = [self informationItem:@""];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.cameraItem = [self informationItem:@""];
    self.tetherItem = [self informationItem:@""];
    self.shootingItem = [self informationItem:@""];
    self.ownerItem = [self informationItem:@""];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.endItem = [self actionItem:[self text:@"结束本次拍摄" english:@"End This Shooting Session"] action:@selector(endSession:)];
    self.endItem.attributedTitle = [[NSAttributedString alloc] initWithString:self.endItem.title
        attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:NSFont.systemFontSize]}];
    self.endItem.toolTip = [self text:@"先暂停自动恢复，再请求 Tether 正常退出。守护工具继续保留，不会自动强制退出 Tether。"
        english:@"Pause automatic recovery first, then ask Tether to quit normally. Guardian stays open and never forces Tether to quit automatically."];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.startItem = [self actionItem:[self text:@"开始守护并打开 Tether" english:@"Start Guardian and Open Tether"] action:@selector(start:)];
    self.startItem.toolTip = [self text:@"启用自动恢复，也允许在核实系统相机服务占用、Tether 未运行且其他相机软件已关闭时尝试重启该服务。"
        english:@"Enable automatic recovery, including a guarded camera-service restart only when its ownership is verified, Tether is absent and other camera apps are closed."];
    self.pauseItem = [self actionItem:[self text:@"仅暂停自动恢复（保留 Tether）" english:@"Pause Recovery Only (Leave Tether As Is)"] action:@selector(pause:)];
    self.pauseItem.toolTip = [self text:@"只暂停后续自动恢复，不请求 Tether 退出。收工请选择“结束本次拍摄”。"
        english:@"Pause future automatic recovery without asking Tether to quit. Choose End This Shooting Session when you have finished shooting."];
    self.reconnectItem = [self actionItem:[self text:@"重新连接（正常重启 Tether）" english:@"Reconnect (Quit Tether Normally)"] action:@selector(reconnect:)];
    self.forceItem = [self actionItem:[self text:@"强制重启 Tether（退出已超时）" english:@"Force Restart Tether (Quit Timed Out)"] action:@selector(forceAction:)];
    self.forceItem.toolTip = [self text:@"仅在正常退出超时后，由你明确选择强制重启。" english:@"Available only after normal quit times out; never performed automatically."];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.openItem = [self actionItem:[self text:@"打开官方 LUMIX Tether" english:@"Open Official LUMIX Tether"] action:@selector(openTether:)];
    [self actionItem:[self text:@"查看连接状态…" english:@"Show Connection Status…"] action:@selector(showStatus:)];
    self.logsItem = [self actionItem:[self text:@"显示诊断与日志文件夹" english:@"Show Diagnostics and Logs Folder"] action:@selector(showLogs:)];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.quitItem = [self actionItem:[self text:@"退出守护工具（保留 Tether）" english:@"Quit Guardian (Leave Tether As Is)"] action:@selector(quit:)];
    self.quitItem.keyEquivalent = @"q";
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"camera" accessibilityDescription:[self text:@"LUMIX 连接守护" english:@"LUMIX Connection Guardian"]];
    image.template = YES;
    self.statusItem.button.image = image;
    if (!image) self.statusItem.button.title = @"LUMIX";
    self.statusItem.menu = self.menu;
    [self createStatusWindow];
    [self render];
    __weak GuardianApp *weakSelf = self;
    self.controller = [[GuardianController alloc] initWithResourceDirectory:NSBundle.mainBundle.resourceURL
        onUpdate:^(NSDictionary *snapshot) {
            GuardianApp *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.snapshot = [snapshot copy];
            [strongSelf render];
        }];
    // Launch idle. Starting automatic recovery requires the user's menu action.
    [self showStatus:nil];
}
- (NSTextField *)windowLabel:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:14];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.statusWindow.contentView addSubview:label];
    return label;
}
- (void)createStatusWindow {
    self.statusWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 300)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.statusWindow.title = [self text:@"LUMIX 连接状态" english:@"LUMIX Connection Status"];
    self.statusWindow.releasedWhenClosed = NO;
    self.windowUSB = [self windowLabel:NSMakeRect(22, 252, 616, 24)];
    self.windowTether = [self windowLabel:NSMakeRect(22, 216, 616, 24)];
    self.windowShooting = [self windowLabel:NSMakeRect(22, 180, 616, 24)];
    self.windowShooting.font = [NSFont boldSystemFontOfSize:14];
    self.windowGuardian = [self windowLabel:NSMakeRect(22, 90, 616, 74)];
    self.windowGuardian.lineBreakMode = NSLineBreakByWordWrapping;
    self.windowGuardian.maximumNumberOfLines = 4;
    self.windowGuardian.textColor = NSColor.secondaryLabelColor;
    self.windowStart = [NSButton buttonWithTitle:[self text:@"开始守护" english:@"Start Guardian"] target:self action:@selector(start:)];
    self.windowStart.frame = NSMakeRect(22, 24, 184, 32);
    self.windowStart.toolTip = self.startItem.toolTip;
    self.windowEnd = [NSButton buttonWithTitle:[self text:@"结束本次拍摄" english:@"End Shooting Session"] target:self action:@selector(endSession:)];
    self.windowEnd.frame = NSMakeRect(222, 24, 206, 32);
    self.windowEnd.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    self.windowEnd.toolTip = self.endItem.toolTip;
    self.windowPause = [NSButton buttonWithTitle:[self text:@"仅暂停自动恢复" english:@"Pause Recovery Only"] target:self action:@selector(pause:)];
    self.windowPause.frame = NSMakeRect(444, 24, 194, 32);
    self.windowPause.toolTip = self.pauseItem.toolTip;
    for (NSButton *button in @[self.windowStart, self.windowEnd, self.windowPause])
        [self.statusWindow.contentView addSubview:button];
    [self.statusWindow center];
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *status = [appMenu addItemWithTitle:[self text:@"查看连接状态…" english:@"Show Connection Status…"]
        action:@selector(showStatus:) keyEquivalent:@""];
    status.target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [appMenu addItemWithTitle:[self text:@"退出 LUMIX 连接守护" english:@"Quit LUMIX Connection Guardian"]
        action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    appItem.submenu = appMenu;
    NSApp.mainMenu = mainMenu;
}
- (void)showStatus:(id)sender {
    (void)sender;
    [self.statusWindow makeKeyAndOrderFront:nil];
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender; (void)flag;
    [self showStatus:nil];
    return YES;
}
- (NSDictionary *)inspection {
    id inspection = self.snapshot[@"inspection"];
    if (![inspection isKindOfClass:NSDictionary.class]) return @{};
    id nested = inspection[@"inspection"];
    return [nested isKindOfClass:NSDictionary.class] ? nested : inspection;
}
- (NSString *)phaseText {
    if (self.terminating) return [self text:@"正在退出守护工具…" english:@"Stopping Guardian…"];
    NSString *state = [self string:self.snapshot[@"state"]];
    if ([state isEqualToString:@"tether_running"] && ![self snapshotBool:@"tether_observation_valid"])
        return [self text:@"Tether 进程状态待确认" english:@"Tether Process State Not Confirmed"];
    if ([state isEqualToString:@"session_ended"] && ![self snapshotBool:@"session_ended"])
        return [self snapshotBool:@"tether_observation_valid"] && [self snapshotBool:@"tether_running"]
            ? [self text:@"检测到 Tether 已重新打开" english:@"Tether Has Been Reopened"]
            : [self text:@"结束状态待确认" english:@"Session End State Not Confirmed"];
    if ([state isEqualToString:@"force_quitting"] && [self snapshotBool:@"ending_session"])
        return [self text:@"正在按你的选择强制退出 Tether…" english:@"Force Quit Requested…"];
    NSDictionary *labels = @{
        @"idle": [self text:@"尚未开始守护" english:@"Guardian Is Idle"],
        @"paused": [self text:@"自动恢复已暂停" english:@"Automatic Recovery Paused"],
        @"waiting_usb": [self text:@"等待相机 USB 连接" english:@"Waiting for Camera USB"],
        @"waiting_for_usb": [self text:@"等待相机 USB 连接" english:@"Waiting for Camera USB"],
        @"waiting_device": [self text:@"等待相机 USB 连接" english:@"Waiting for Camera USB"],
        @"starting": [self text:@"正在开始守护…" english:@"Starting Guardian…"],
        @"watching": [self text:@"正在守护" english:@"Guardian Is Watching"],
        @"running": [self text:@"正在守护" english:@"Guardian Is Watching"],
        @"tether_running": [self text:@"Tether 进程正在运行" english:@"Tether Process Is Running"],
        @"recovering": [self text:@"正在恢复连接…" english:@"Recovering Connection…"],
        @"launching": [self text:@"正在打开官方 Tether…" english:@"Opening Official Tether…"],
        @"restarting_service": [self text:@"正在释放系统相机服务…" english:@"Releasing System Camera Service…"],
        @"quitting_tether": [self text:@"正在等待 Tether 正常退出…" english:@"Waiting for Tether to Quit…"],
        @"quit_timeout": [self text:@"Tether 正常退出已超时" english:@"Tether Quit Timed Out"],
        @"needs_force": [self text:@"Tether 正常退出已超时" english:@"Tether Quit Timed Out"],
        @"force_quitting": [self text:@"正在按你的选择强制重启…" english:@"Force Restart Requested…"],
        @"ending_wait": [self text:@"正在结束本次拍摄，等待连接准备完成…" english:@"Ending Session; Waiting for Preparation…"],
        @"ending_tether": [self text:@"正在结束本次拍摄，等待 Tether 退出…" english:@"Ending Session; Waiting for Tether to Quit…"],
        @"ending_needs_force": [self text:@"结束拍摄：Tether 正常退出已超时" english:@"Ending Session: Tether Quit Timed Out"],
        @"ending_force_quitting": [self text:@"正在按你的选择强制退出 Tether…" english:@"Force Quit Requested…"],
        @"session_ended": [self text:@"本次拍摄已结束" english:@"Shooting Session Ended"],
        @"end_needs_attention": [self text:@"本次拍摄尚未结束，请查看提示" english:@"Session Has Not Ended; See Details"],
        @"inspection_error": [self text:@"连接状态暂时无法确认" english:@"Connection State Is Unknown"],
        @"blocked": [self text:@"需要处理" english:@"Attention Needed"],
        @"needs_attention": [self text:@"需要处理" english:@"Attention Needed"],
        @"retry_wait": [self text:@"正在等待重试…" english:@"Waiting to Retry…"],
        @"waiting": [self text:@"正在等待连接稳定…" english:@"Waiting for a Stable Connection…"],
        @"busy": [self text:@"正在处理…" english:@"Working…"],
        @"helper_timeout": [self text:@"正在等待连接检查安全结束…" english:@"Waiting for Connection Check to Finish…"],
        @"error": [self text:@"需要处理" english:@"Attention Needed"],
        @"stopped": [self text:@"守护已停止" english:@"Guardian Stopped"]
    };
    NSString *label = labels[state];
    if (label) return label;
    if ([self snapshotBool:@"busy"]) return [self text:@"正在处理…" english:@"Working…"];
    if ([self snapshotBool:@"desired_running"]) return [self text:@"正在守护" english:@"Guardian Is Watching"];
    return [self text:@"自动恢复未启用" english:@"Automatic Recovery Is Off"];
}
- (void)render {
    BOOL busy = [self snapshotBool:@"busy"];
    BOOL desired = [self snapshotBool:@"desired_running"];
    BOOL present = [self snapshotBool:@"device_present"];
    BOOL tetherRunning = [self snapshotBool:@"tether_running"];
    BOOL ending = [self snapshotBool:@"ending_session"];
    BOOL ended = [self snapshotBool:@"session_ended"];
    BOOL tetherValid = [self snapshotBool:@"tether_observation_valid"];
    BOOL inspectionValid = [self snapshotBool:@"inspection_observation_valid"];
    NSDictionary *inspection = [self inspection];
    NSString *state = [self string:self.snapshot[@"state"]];
    BOOL inspectionError = [state isEqualToString:@"inspection_error"] ||
        (inspection[@"inspection_error"] && inspection[@"inspection_error"] != NSNull.null);
    inspectionValid = inspectionValid && !inspectionError;
    NSString *phase = [self phaseText];
    [self setInfo:self.phaseItem text:phase];
    NSString *message = [self string:self.snapshot[self.chinese ? @"message_zh" : @"message_en"]];
    if (!message.length) message = [self string:self.snapshot[@"message_en"]];
    if (!tetherValid && ([state isEqualToString:@"tether_running"] || [state isEqualToString:@"session_ended"]))
        message = [self text:@"当前 Tether 进程状态尚未确认；不能据此判断拍摄连接。"
            english:@"The current Tether process state is not confirmed; this does not establish a shooting connection."];
    else if ([state isEqualToString:@"session_ended"] && !ended && tetherRunning)
        message = [self text:@"检测到 Tether 进程已重新运行。自动恢复保持暂停，请在 Tether 中确认拍摄连接。"
            english:@"Tether is running again. Automatic recovery remains paused; confirm the shooting connection in Tether."];
    if (self.terminating) message = [self text:@"等待本工具的连接检查结束；不更改官方 Tether 当前状态。" english:@"Waiting for this tool's connection check; official Tether is left as it is."];
    if (!message.length) message = [self text:@"在相机选择 PC(Tether)，然后开始守护。" english:@"Select PC(Tether) on the camera, then start Guardian."];
    [self setInfo:self.messageItem text:message];
    NSString *model = [self string:inspection[@"usb_product_name"]];
    id speedValue = inspection[@"usb_link_speed_bps"];
    double speed = [speedValue isKindOfClass:NSNumber.class] ? [speedValue doubleValue] : 0;
    NSString *linkRate = @"";
    if (speed >= 1000000000.0) linkRate = [NSString stringWithFormat:@"%g Gbps", speed / 1000000000.0];
    else if (speed >= 1000000.0) linkRate = [NSString stringWithFormat:@"%g Mbps", speed / 1000000.0];
    else if (speed > 0) linkRate = [NSString stringWithFormat:@"%g bps", speed];
    id count = inspection[@"matching_usb_id_device_count"];
    BOOL hasCount = [count isKindOfClass:NSNumber.class];
    NSString *camera = [self text:@"尚未检查" english:@"Not Yet Checked"];
    if (!inspectionValid && inspection.count) camera = [self text:@"状态暂时无法确认" english:@"State Is Unknown"];
    else if (!inspectionValid) camera = [self text:@"尚未确认" english:@"Not Yet Confirmed"];
    else if (present) camera = model.length ? model : [self text:@"相机已连接" english:@"Camera Present"];
    else if (hasCount && [count unsignedIntegerValue] == 0) camera = [self text:@"未检测到相机" english:@"No Camera Detected"];
    else if (hasCount) camera = model.length
        ? [NSString stringWithFormat:[self text:@"%@（尚未确认支持）" english:@"%@ (Support Unconfirmed)"], model]
        : [self text:@"相机型号尚未确认" english:@"Camera Model Is Unconfirmed"];
    if (inspectionValid && present && linkRate.length) camera = [NSString stringWithFormat:
        [self text:@"%@ · 协商速率 %@" english:@"%@ · Negotiated %@"], camera, linkRate];
    [self setInfo:self.cameraItem text:[@"USB: " stringByAppendingString:camera]];
    self.cameraItem.toolTip = [self text:@"显示 USB 链路协商速率；它不是当前实际传输的 MB/s。当前被动监测方式无法可靠读取 Tether 的实时 USB 吞吐量。"
        english:@"Shows the negotiated USB link rate, not current MB/s. Passive monitoring cannot reliably read Tether's real-time USB throughput on this setup."];
    [self setInfo:self.tetherItem text:[NSString stringWithFormat:[self text:@"Tether 进程：%@" english:@"Tether Process: %@"],
        !tetherValid ? [self text:@"未知（暂时无法确认）" english:@"Unknown (Not Confirmed)"]
            : (tetherRunning ? [self text:@"正在运行" english:@"Running"] : [self text:@"未运行" english:@"Not Running"])]];
    self.tetherItem.toolTip = [self text:@"显示进程是否运行，不代表 Tether 已连接相机。" english:@"Shows whether the process is running; this does not confirm a camera connection inside Tether."];
    NSString *shooting = @"";
    if (ending) shooting = [self text:@"正在结束本次拍摄…" english:@"Ending This Session…"];
    else if (ended) shooting = [self text:@"本次拍摄已结束" english:@"This Session Has Ended"];
    else if ([state isEqualToString:@"end_needs_attention"]) shooting = [self text:@"结束未完成，请查看提示" english:@"Session Not Ended; See Details"];
    else if (!inspectionValid) shooting = [self text:@"未知（USB 状态未确认）" english:@"Unknown (USB State Not Confirmed)"];
    else if (!present) shooting = hasCount && [count unsignedIntegerValue] == 0
        ? [self text:@"不可用（未检测到相机）" english:@"Unavailable (No Camera Detected)"]
        : [self text:@"不可用（相机型号尚未确认）" english:@"Unavailable (Camera Model Unconfirmed)"];
    else if (!tetherValid) shooting = [self text:@"未知（Tether 进程状态未确认）" english:@"Unknown (Tether Process Not Confirmed)"];
    else if (!tetherRunning) shooting = [self text:@"不可用（Tether 未运行）" english:@"Unavailable (Tether Is Not Running)"];
    else shooting = [self text:@"待在 Tether 中确认" english:@"Confirm in Tether"];
    [self setInfo:self.shootingItem text:[NSString stringWithFormat:[self text:@"拍摄连接：%@" english:@"Shooting Connection: %@"], shooting]];
    self.shootingItem.toolTip = [self text:@"守护工具不会通过进程或 USB 占用推断已联机。请在官方 Tether 中确认相机、实时预览和拍摄状态。"
        english:@"Guardian does not infer a shooting connection from a process or USB ownership. Confirm the camera, live view and shooting status in official Tether."];
    NSString *ownerState = [self string:inspection[@"owner_state"]];
    NSString *owner = @"";
    id ownerProcess = inspection[@"owner_process"];
    if ([ownerProcess isKindOfClass:NSDictionary.class]) owner = [[self string:ownerProcess[@"executable"]] lastPathComponent];
    if ([owner isEqualToString:@"ptpcamerad"]) owner = [self text:@"系统相机服务" english:@"System Camera Service"];
    if (!inspectionValid) owner = [self text:@"暂时无法确认" english:@"State Is Unknown"];
    else if ([ownerState isEqualToString:@"none"]) owner = [self text:@"无占用记录" english:@"No Owner Recorded"];
    else if (!owner.length) owner = [self text:@"尚未确认" english:@"Not Yet Confirmed"];
    [self setInfo:self.ownerItem text:[NSString stringWithFormat:[self text:@"接口占用：%@" english:@"Interface Owner: %@"], owner]];
    self.startItem.title = desired ? [self text:@"保持 Tether 运行" english:@"Keep Tether Running"]
        : (ended ? [self text:@"开始新一次拍摄并守护" english:@"Start a New Session and Guardian"]
            : [self text:@"开始守护并打开 Tether" english:@"Start Guardian and Open Tether"]);
    self.startItem.enabled = !self.terminating && !busy && !ending;
    self.endItem.enabled = !self.terminating && !ending && !ended;
    self.pauseItem.enabled = !self.terminating && (desired || ending);
    self.pauseItem.title = ending ? [self text:@"取消结束等待，保持暂停" english:@"Cancel End Wait; Keep Recovery Paused"]
        : [self text:@"仅暂停自动恢复（保留 Tether）" english:@"Pause Recovery Only (Leave Tether As Is)"];
    self.pauseItem.toolTip = ending
        ? [self text:@"取消后续结束等待并保持自动恢复暂停；已经送达 Tether 的正常退出请求无法撤回。"
            english:@"Cancel further end-session waiting and keep recovery paused. A normal quit request already delivered to Tether cannot be undone."]
        : [self text:@"只暂停后续自动恢复，不请求 Tether 退出。收工请选择“结束本次拍摄”。"
            english:@"Pause future automatic recovery without asking Tether to quit. Choose End This Shooting Session when you have finished shooting."];
    self.pauseItem.state = !desired && !ending && !ended && ![state isEqualToString:@"idle"]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.reconnectItem.enabled = !self.terminating && !busy && !ending;
    // Normal quit remains "busy" after its deadline. The controller owns the
    // separate force permission and revalidates the exact process on action.
    NSString *forceAction = [self string:self.snapshot[@"force_action"]];
    BOOL forceQuit = [self snapshotBool:@"can_force_quit"] && [forceAction isEqualToString:@"quit"];
    BOOL forceRestart = [self snapshotBool:@"can_force_restart"] && [forceAction isEqualToString:@"restart"];
    self.forceItem.title = ending || [forceAction isEqualToString:@"quit"]
        ? [self text:@"强制退出 Tether（退出已超时）" english:@"Force Quit Tether (Quit Timed Out)"]
        : [self text:@"强制重启 Tether（退出已超时）" english:@"Force Restart Tether (Quit Timed Out)"];
    self.forceItem.toolTip = [self text:@"仅在正常退出超时后，由你另行明确选择；结束拍摄时不会重新打开 Tether。"
        english:@"Requires a separate explicit action after normal quit times out. Ending a session does not reopen Tether."];
    self.forceItem.enabled = !self.terminating && (forceQuit || forceRestart);
    self.openItem.enabled = !self.terminating && !busy && !ending;
    NSString *logDirectory = [self string:self.snapshot[@"log_directory"]];
    self.logsItem.enabled = !self.terminating && logDirectory.isAbsolutePath;
    self.quitItem.enabled = !self.terminating;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"LUMIX — %@\n%@", phase, message];
    self.windowUSB.stringValue = self.cameraItem.title;
    self.windowUSB.toolTip = self.cameraItem.toolTip;
    self.windowTether.stringValue = self.tetherItem.title;
    self.windowTether.toolTip = self.tetherItem.toolTip;
    self.windowShooting.stringValue = self.shootingItem.title;
    self.windowShooting.toolTip = self.shootingItem.toolTip;
    self.windowGuardian.stringValue = [NSString stringWithFormat:[self text:@"守护状态：%@\n%@" english:@"Guardian: %@\n%@"], phase, message];
    self.windowGuardian.toolTip = self.windowGuardian.stringValue;
    self.windowStart.enabled = self.startItem.enabled;
    self.windowStart.title = ended ? [self text:@"开始新的拍摄" english:@"Start a New Session"] : [self text:@"开始守护" english:@"Start Guardian"];
    self.windowEnd.enabled = self.endItem.enabled;
    self.windowPause.enabled = self.pauseItem.enabled;
    self.windowPause.title = ending ? [self text:@"取消结束等待" english:@"Cancel End Wait"]
        : [self text:@"仅暂停自动恢复" english:@"Pause Recovery Only"];
    self.windowPause.toolTip = self.pauseItem.toolTip;
}
- (void)start:(id)sender { (void)sender; if (self.startItem.enabled) [self.controller start]; }
- (void)endSession:(id)sender { (void)sender; if (self.endItem.enabled) [self.controller endSession]; }
- (void)pause:(id)sender { (void)sender; if (self.pauseItem.enabled) [self.controller pause]; }
- (void)reconnect:(id)sender { (void)sender; if (self.reconnectItem.enabled) [self.controller reconnect]; }
- (void)forceAction:(id)sender {
    (void)sender;
    if (!self.forceItem.enabled) return;
    NSString *action = [self string:self.snapshot[@"force_action"]];
    if ([action isEqualToString:@"quit"] && [self snapshotBool:@"can_force_quit"]) [self.controller forceQuit];
    else if ([action isEqualToString:@"restart"] && [self snapshotBool:@"can_force_restart"]) [self.controller forceRestart];
}
- (void)openTether:(id)sender { (void)sender; if (self.openItem.enabled) [self.controller openTether]; }
- (void)showLogs:(id)sender {
    (void)sender;
    NSString *path = [self string:self.snapshot[@"log_directory"]];
    if (self.logsItem.enabled && path.isAbsolutePath) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path isDirectory:YES]];
}
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.terminating) return NSTerminateLater;
    if (!self.controller) return NSTerminateNow;
    self.terminating = YES;
    [self render];
    [self.controller stopToolWithCompletion:^{
        // Defer even a synchronous completion until AppKit has received Later.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp replyToApplicationShouldTerminate:YES];
        });
    }];
    return NSTerminateLater;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        __attribute__((objc_precise_lifetime)) GuardianApp *delegate = [GuardianApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
