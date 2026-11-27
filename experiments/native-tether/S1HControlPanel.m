#import "S1HControlPanel.h"
#import "S1HCaptureConsole.h"
#import "S1HInterfaceStyle.h"
#include <math.h>

static const CGFloat CaptureConsoleHeight = 132.0;
static const CGFloat TransferProgressHeight = 36.0;

@interface S1HControlDocumentView : NSView
@end
@implementation S1HControlDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface S1HControlPanel ()
@property(nonatomic) BOOL chinese;
@property(nonatomic) BOOL busyState;
@property(nonatomic) BOOL cameraReady;
@property(nonatomic) BOOL captureAvailable;
@property(nonatomic) BOOL remoteFocusAvailable;
@property(nonatomic, copy) NSString *saveDirectory;
@property(nonatomic, copy) NSString *lastSavedPath;
@property(nonatomic, copy) NSDictionary *controls;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *whiteBalanceTranslations;
@property(nonatomic, strong) S1HCaptureConsole *captureConsole;
@property(nonatomic, strong) NSView *transferProgressStrip;
@property(nonatomic, strong) NSLayoutConstraint *transferProgressHeight;
@property(nonatomic, strong) NSTextField *transferProgressLabel;
@property(nonatomic, strong) NSProgressIndicator *transferProgressIndicator;
@property(nonatomic, strong) NSPopUpButton *captureTargetPopup;
@property(nonatomic, strong) NSPopUpButton *bodyCaptureTargetPopup;
@property(nonatomic, strong) NSTextField *bodyCaptureTargetLabel;
@property(nonatomic, copy) NSDictionary *cameraStorage;
@property(nonatomic, strong) NSTextField *driveModeLabel;
@property(nonatomic, strong) NSButton *directoryButton;
@property(nonatomic, strong) NSButton *photoNamingButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSTextField *directoryLabel;
@property(nonatomic, strong) NSTextField *lastSavedLabel;
@property(nonatomic, strong) NSTextField *resultLabel;
@property(nonatomic, strong) NSStackView *focusControls;
@property(nonatomic, strong) NSButton *focusAButton;
@property(nonatomic, strong) NSButton *focusBButton;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSPopUpButton *> *popups;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *reasonLabels;
@end

@implementation S1HControlPanel
@synthesize onCapture = _onCapture;
@synthesize onSetBodyCaptureTarget = _onSetBodyCaptureTarget;
@synthesize onChooseDirectory = _onChooseDirectory;
@synthesize onChoosePhotoNaming = _onChoosePhotoNaming;
@synthesize onSetProperty = _onSetProperty;
@synthesize onRefresh = _onRefresh;
@synthesize onFocusStep = _onFocusStep;

- (NSString *)text:(NSString *)zh english:(NSString *)en {
    return self.chinese ? zh : en;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self buildPanel];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self buildPanel];
    return self;
}

- (NSTextField *)label:(NSString *)text font:(NSFont *)font wrapping:(BOOL)wrapping {
    NSTextField *label = wrapping ? [NSTextField wrappingLabelWithString:text] : [NSTextField labelWithString:text];
    label.font = font;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.lineBreakMode = wrapping ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingMiddle;
    return label;
}

- (void)addView:(NSView *)view toStack:(NSStackView *)stack {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (void)addProperty:(NSString *)key title:(NSString *)title toStack:(NSStackView *)stack {
    NSTextField *titleLabel = [self label:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium] wrapping:NO];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    popup.identifier = key;
    popup.target = self;
    popup.action = @selector(propertyChanged:);
    popup.accessibilityLabel = title;
    S1HStylePopup(popup);
    [popup.heightAnchor constraintGreaterThanOrEqualToConstant:26.0].active = YES;
    NSTextField *reason = [self label:@"" font:[NSFont systemFontOfSize:11] wrapping:YES];
    reason.textColor = NSColor.secondaryLabelColor;
    NSStackView *row = [NSStackView stackViewWithViews:@[titleLabel, popup, reason]];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 3;
    for (NSView *child in @[titleLabel, popup, reason])
        [child.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
    [self addView:row toStack:stack];
    self.popups[key] = popup;
    self.reasonLabels[key] = reason;
}

- (void)buildTransferProgressStrip {
    CGFloat width = MAX(0.0, NSWidth(self.bounds) - 24.0);
    self.transferProgressStrip = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, TransferProgressHeight)];
    self.transferProgressStrip.translatesAutoresizingMaskIntoConstraints = NO;
    self.transferProgressStrip.hidden = YES;
    self.transferProgressHeight = [self.transferProgressStrip.heightAnchor constraintEqualToConstant:0];

    self.transferProgressLabel = [NSTextField labelWithString:@""];
    self.transferProgressLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.transferProgressLabel.textColor = NSColor.secondaryLabelColor;
    self.transferProgressLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.transferProgressLabel.frame = NSMakeRect(0, 18, width, 15);
    self.transferProgressLabel.autoresizingMask = NSViewWidthSizable;
    [self.transferProgressStrip addSubview:self.transferProgressLabel];

    self.transferProgressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 5, width, 11)];
    self.transferProgressIndicator.style = NSProgressIndicatorStyleBar;
    self.transferProgressIndicator.controlSize = NSControlSizeSmall;
    self.transferProgressIndicator.minValue = 0;
    self.transferProgressIndicator.maxValue = 1;
    self.transferProgressIndicator.autoresizingMask = NSViewWidthSizable;
    [self.transferProgressIndicator setAccessibilityLabel:[self text:@"文件传输进度" english:@"Photo transfer progress"]];
    [self.transferProgressStrip addSubview:self.transferProgressIndicator];
    [self addSubview:self.transferProgressStrip];
}

- (void)buildRemoteFocusInStack:(NSStackView *)stack {
    NSTextField *heading = [self label:[self text:@"远程对焦" english:@"Remote Focus"]
        font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold] wrapping:NO];
    NSTextField *hint = [self label:[self text:@"每次点击移动一步。" english:@"Moves focus one step per click."]
        font:[NSFont systemFontOfSize:11] wrapping:YES];
    hint.textColor = NSColor.secondaryLabelColor;
    self.focusAButton = [NSButton buttonWithTitle:[self text:@"向前对焦" english:@"Focus Forward"] target:self action:@selector(stepFocus:)];
    self.focusBButton = [NSButton buttonWithTitle:[self text:@"向后对焦" english:@"Focus Back"] target:self action:@selector(stepFocus:)];
    self.focusAButton.identifier = @"focusA";
    self.focusBButton.identifier = @"focusB";
    NSStackView *row = [NSStackView stackViewWithViews:@[self.focusAButton, self.focusBButton]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionFillEqually;
    row.spacing = 6;
    for (NSButton *button in @[self.focusAButton, self.focusBButton]) {
        S1HStyleButton(button);
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:28.0].active = YES;
    }
    self.focusControls = [NSStackView new];
    self.focusControls.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.focusControls.alignment = NSLayoutAttributeLeading;
    self.focusControls.spacing = 4;
    [self addView:heading toStack:self.focusControls];
    [self addView:hint toStack:self.focusControls];
    [self addView:row toStack:self.focusControls];
    [self addView:self.focusControls toStack:stack];
}

- (void)buildPanel {
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    self.controls = @{};
    self.saveDirectory = @"";
    self.popups = [NSMutableDictionary dictionary];
    self.reasonLabels = [NSMutableDictionary dictionary];
    self.whiteBalanceTranslations = self.chinese ? @{
        @"Auto": @"自动", @"Daylight": @"晴天", @"Fluorescent": @"荧光灯", @"Tungsten": @"白炽灯",
        @"Flash": @"闪光灯", @"Cloudy": @"阴天", @"Shade": @"阴影", @"White Set": @"手动白平衡",
        @"White Set 1": @"手动白平衡 1", @"White Set 2": @"手动白平衡 2",
        @"White Set 3": @"手动白平衡 3", @"White Set 4": @"手动白平衡 4",
        @"Temperature 1": @"色温 1", @"Temperature 2": @"色温 2", @"Temperature 3": @"色温 3",
        @"Temperature 4": @"色温 4", @"Auto cool": @"自动（偏冷）", @"Auto warm": @"自动（偏暖）"
    } : @{};

    self.captureConsole = [[S1HCaptureConsole alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(self.bounds), CaptureConsoleHeight)];
    self.captureConsole.translatesAutoresizingMaskIntoConstraints = NO;
    self.captureConsole.captureButton.target = self;
    self.captureConsole.captureButton.action = @selector(capture:);
    [self addSubview:self.captureConsole];
    [self buildTransferProgressStrip];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    NSRect settingsFrame = NSMakeRect(0, 0, NSWidth(self.bounds), MAX(0.0, NSHeight(self.bounds) - CaptureConsoleHeight));
    NSView *settingsGlass = S1HStyleGlass(settingsFrame, scroll, NSVisualEffectMaterialSidebar, 16.0);
    settingsGlass.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:settingsGlass];
    [NSLayoutConstraint activateConstraints:@[
        [self.captureConsole.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.captureConsole.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.captureConsole.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.captureConsole.heightAnchor constraintEqualToConstant:CaptureConsoleHeight],
        [self.transferProgressStrip.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.transferProgressStrip.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.transferProgressStrip.topAnchor constraintEqualToAnchor:self.captureConsole.bottomAnchor],
        self.transferProgressHeight,
        [settingsGlass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [settingsGlass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [settingsGlass.topAnchor constraintEqualToAnchor:self.transferProgressStrip.bottomAnchor],
        [settingsGlass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];

    S1HControlDocumentView *document = [S1HControlDocumentView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    NSStackView *stack = [NSStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-12]
    ]];

    [self addView:[self label:[self text:@"拍摄设置" english:@"Shooting settings"]
        font:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold] wrapping:NO] toStack:stack];

    self.driveModeLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:YES];
    self.driveModeLabel.hidden = YES;
    [self addView:self.driveModeLabel toStack:stack];
    self.resultLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:YES];
    self.resultLabel.hidden = YES;
    [self addView:self.resultLabel toStack:stack];
    [self buildRemoteFocusInStack:stack];
    self.bodyCaptureTargetLabel = [self label:[self text:@"机身快门存储目标 · 存储卡状态未知"
        english:@"Camera Shutter Storage · Card status unknown"] font:[NSFont systemFontOfSize:12] wrapping:YES];
    [self addView:self.bodyCaptureTargetLabel toStack:stack];
    self.bodyCaptureTargetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.bodyCaptureTargetPopup addItemsWithTitles:@[[self text:@"当前目标未知" english:@"Current target unknown"],
        [self text:@"仅存储卡" english:@"Card Only"], [self text:@"仅保存到 Mac" english:@"Save to Mac Only"],
        [self text:@"存储卡＋Mac" english:@"Card + Mac"]]];
    for (NSInteger index = 0; index < self.bodyCaptureTargetPopup.numberOfItems; ++index)
        [self.bodyCaptureTargetPopup itemAtIndex:index].tag = index - 1;
    self.bodyCaptureTargetPopup.menu.autoenablesItems = NO;
    self.bodyCaptureTargetPopup.itemArray.firstObject.enabled = NO;
    self.bodyCaptureTargetPopup.target = self;
    self.bodyCaptureTargetPopup.action = @selector(bodyCaptureTargetChanged:);
    self.bodyCaptureTargetPopup.accessibilityLabel = [self text:@"机身快门存储目标" english:@"Camera shutter storage target"];
    self.bodyCaptureTargetPopup.toolTip = [self text:@"更改相机当前的联机存储目标，机身快门会采用此设置。"
        english:@"Change the active tether storage destination used by the camera shutter."];
    S1HStylePopup(self.bodyCaptureTargetPopup);
    [self addView:self.bodyCaptureTargetPopup toStack:stack];
    [self.bodyCaptureTargetPopup.heightAnchor constraintGreaterThanOrEqualToConstant:26.0].active = YES;
    [self addView:[self label:[self text:@"软件快门存储目标（单次）" english:@"App Shutter Storage (Per Capture)"]
        font:[NSFont systemFontOfSize:12] wrapping:NO] toStack:stack];
    self.captureTargetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.captureTargetPopup addItemsWithTitles:@[[self text:@"保持机身存储目标" english:@"Keep Camera Storage Target"],
        [self text:@"仅保存到 Mac" english:@"Save to Mac Only"],
        [self text:@"存储卡＋Mac（测试）" english:@"Card + Mac (Test)"]]];
    [self.captureTargetPopup selectItemAtIndex:1];
    self.captureTargetPopup.accessibilityLabel = [self text:@"软件快门存储目标" english:@"App shutter storage target"];
    self.captureTargetPopup.toolTip = [self text:@"此选项用于软件快门。拍摄时临时切换，确认结束后恢复相机原设置。机身快门沿用相机当前的联机存储目标。存储卡＋Mac 需要相机已识别的存储卡。"
        english:@"This option applies to the app shutter. The camera's target is restored after a confirmed finish. The camera shutter uses the active tether target. Card + Mac requires a recognized card."];
    S1HStylePopup(self.captureTargetPopup);
    [self addView:self.captureTargetPopup toStack:stack];
    [self.captureTargetPopup.heightAnchor constraintGreaterThanOrEqualToConstant:26.0].active = YES;
    self.directoryButton = [NSButton buttonWithTitle:[self text:@"选择照片保存文件夹…" english:@"Choose Save Folder…"] target:self action:@selector(chooseDirectory:)];
    [self addView:self.directoryButton toStack:stack];
    self.directoryLabel = [self label:@"" font:[NSFont systemFontOfSize:11] wrapping:YES];
    self.directoryLabel.textColor = NSColor.secondaryLabelColor;
    [self addView:self.directoryLabel toStack:stack];
    self.photoNamingButton = [NSButton buttonWithTitle:[self text:@"照片文件命名…" english:@"Photo File Naming…"] target:self action:@selector(choosePhotoNaming:)];
    [self addView:self.photoNamingButton toStack:stack];
    self.lastSavedLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:NO];
    [self addView:self.lastSavedLabel toStack:stack];
    self.revealButton = [NSButton buttonWithTitle:[self text:@"在访达中显示最近一张" english:@"Show Last Photo in Finder"] target:self action:@selector(revealSavedPhoto:)];
    [self addView:self.revealButton toStack:stack];

    self.refreshButton = [NSButton buttonWithTitle:[self text:@"刷新相机参数" english:@"Refresh Camera Settings"] target:self action:@selector(refresh:)];
    [self addView:self.refreshButton toStack:stack];
    for (NSButton *button in @[self.directoryButton, self.photoNamingButton, self.revealButton, self.refreshButton]) {
        S1HStyleButton(button);
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:28.0].active = YES;
    }
    [self addProperty:@"iso" title:@"ISO" toStack:stack];
    [self addProperty:@"shutter" title:[self text:@"快门速度" english:@"Shutter Speed"] toStack:stack];
    [self addProperty:@"aperture" title:[self text:@"光圈" english:@"Aperture"] toStack:stack];
    [self addProperty:@"white_balance" title:[self text:@"白平衡" english:@"White Balance"] toStack:stack];
    [self addProperty:@"color_temperature" title:[self text:@"白平衡色温" english:@"White Balance Temperature"] toStack:stack];
    [self addProperty:@"exposure_compensation" title:[self text:@"曝光补偿" english:@"Exposure Compensation"] toStack:stack];
    [self addProperty:@"focus_mode" title:[self text:@"对焦模式" english:@"Focus Mode"] toStack:stack];

    [self setLastSavedPath:nil];
    [self setSaveDirectory:nil];
    [self updateCapabilities:@{} busy:NO];
}

- (void)setOnCapture:(void (^)(NSString *))block {
    _onCapture = [block copy];
    [self updateInteractionStates];
}

- (void)setOnSetBodyCaptureTarget:(void (^)(NSString *))block {
    _onSetBodyCaptureTarget = [block copy];
    [self updateInteractionStates];
}
- (void)setOnChooseDirectory:(void (^)(void))block {
    _onChooseDirectory = [block copy];
    [self updateInteractionStates];
}
- (void)setOnChoosePhotoNaming:(void (^)(void))block {
    _onChoosePhotoNaming = [block copy];
    [self updateInteractionStates];
}
- (void)setOnSetProperty:(void (^)(NSString *, NSNumber *))block {
    _onSetProperty = [block copy];
    [self updateInteractionStates];
}
- (void)setOnRefresh:(void (^)(void))block {
    _onRefresh = [block copy];
    [self updateInteractionStates];
}

- (void)setOnFocusStep:(void (^)(NSString *))block {
    _onFocusStep = [block copy];
    [self updateInteractionStates];
}

- (void)updateCapabilities:(NSDictionary *)controls busy:(BOOL)busy {
    self.controls = [controls isKindOfClass:NSDictionary.class] ? [controls copy] : @{};
    self.busyState = busy;
    for (NSString *key in self.popups) {
        NSDictionary<NSString *, NSString *> *translations = [key isEqualToString:@"white_balance"] ? self.whiteBalanceTranslations : nil;
        NSPopUpButton *popup = self.popups[key];
        NSDictionary *node = [self.controls[key] isKindOfClass:NSDictionary.class] ? self.controls[key] : @{};
        NSArray *options = [node[@"options"] isKindOfClass:NSArray.class] ? node[@"options"] : @[];
        NSNumber *current = [node[@"current"] isKindOfClass:NSNumber.class] ? node[@"current"] : nil;
        [popup removeAllItems];
        NSInteger selected = -1;
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (id candidate in options) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSNumber *raw = [candidate[@"value"] isKindOfClass:NSNumber.class] ? candidate[@"value"] : nil;
            if (!raw || [seen containsObject:raw]) continue;
            [seen addObject:raw];
            NSString *label = [candidate[@"label"] isKindOfClass:NSString.class] ? candidate[@"label"] : nil;
            if (label.length) label = translations[label] ?: label;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label.length ? label : raw.stringValue action:NULL keyEquivalent:@""];
            item.representedObject = raw;
            [popup.menu addItem:item];
            if (current && [raw isEqualToNumber:current]) selected = popup.numberOfItems - 1;
        }
        if (selected >= 0) [popup selectItemAtIndex:selected];
        else {
            NSString *currentLabel = [node[@"current_label"] isKindOfClass:NSString.class] ? node[@"current_label"] : current.stringValue;
            if (currentLabel.length) currentLabel = translations[currentLabel] ?: currentLabel;
            NSString *placeholder = currentLabel.length ? [NSString stringWithFormat:[self text:@"当前值 %@" english:@"Current %@"], currentLabel]
                : [self text:@"当前值未知" english:@"Current value unknown"];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:placeholder action:NULL keyEquivalent:@""];
            item.enabled = NO;
            [popup.menu insertItem:item atIndex:0];
            [popup selectItemAtIndex:0];
        }
    }
    [self updateInteractionStates];
}

- (void)updateCaptureConsole {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    if (self.cameraReady) {
        for (NSString *key in @[@"iso", @"shutter", @"aperture", @"white_balance", @"exposure_compensation"]) {
            NSDictionary *node = [self.controls[key] isKindOfClass:NSDictionary.class] ? self.controls[key] : nil;
            NSString *label = [node[@"current_label"] isKindOfClass:NSString.class] ? node[@"current_label"] : nil;
            if (!label.length) continue;
            if ([key isEqualToString:@"white_balance"]) label = self.whiteBalanceTranslations[label] ?: label;
            values[key] = label;
        }
    }
    [self.captureConsole updateWithValues:values cameraReady:self.cameraReady busy:self.busyState];
}

- (void)updateInteractionStates {
    BOOL canControl = self.cameraReady && !self.busyState;
    self.focusControls.hidden = self.onFocusStep == nil;
    BOOL canFocus = canControl && self.remoteFocusAvailable && self.onFocusStep != nil;
    self.focusAButton.enabled = self.focusBButton.enabled = canFocus;
    NSDictionary *drive = [self.controls[@"drive_mode"] isKindOfClass:NSDictionary.class] ? self.controls[@"drive_mode"] : nil;
    NSNumber *mode = [drive[@"current"] isKindOfClass:NSNumber.class] ? drive[@"current"] : nil;
    self.driveModeLabel.hidden = !self.cameraReady || !mode;
    if (mode) {
        NSString *name = @{@0:[self text:@"单张" english:@"Single"],
                           @9:[self text:@"高分辨率（摇摇乐）" english:@"High Resolution"],
                           @10:[self text:@"手持高分辨率" english:@"Handheld High Resolution"]}[mode];
        if (!name) name = [self text:@"其他驱动模式" english:@"Other drive mode"];
        self.driveModeLabel.stringValue = [NSString stringWithFormat:[self text:@"机身拍摄模式  %@" english:@"Camera drive mode  %@"], name];
    }
    self.captureConsole.captureButton.enabled = canControl && self.captureAvailable && self.saveDirectory.length > 0 && self.onCapture != nil;
    [self updateCaptureConsole];
    self.bodyCaptureTargetLabel.hidden = !self.cameraReady;
    self.bodyCaptureTargetPopup.hidden = !self.cameraReady;
    self.bodyCaptureTargetPopup.enabled = canControl && [self.cameraStorage[@"target"] isKindOfClass:NSNumber.class] &&
        self.onSetBodyCaptureTarget != nil;
    self.captureTargetPopup.enabled = !self.busyState;
    self.directoryButton.enabled = !self.busyState && self.onChooseDirectory != nil;
    self.photoNamingButton.enabled = !self.busyState && self.onChoosePhotoNaming != nil;
    self.refreshButton.enabled = canControl && self.onRefresh != nil;
    self.revealButton.hidden = !self.lastSavedPath.length;
    self.revealButton.enabled = self.lastSavedPath.length > 0 && self.onRevealSavedPhoto != nil;
    for (NSString *key in self.popups) {
        NSPopUpButton *popup = self.popups[key];
        NSDictionary *node = [self.controls[key] isKindOfClass:NSDictionary.class] ? self.controls[key] : @{};
        BOOL available = [node[@"available"] isKindOfClass:NSNumber.class] && [node[@"available"] boolValue];
        BOOL writable = [node[@"writable"] isKindOfClass:NSNumber.class] && [node[@"writable"] boolValue];
        BOOL hasOptions = NO;
        for (NSMenuItem *item in popup.itemArray)
            if ([item.representedObject isKindOfClass:NSNumber.class]) { hasOptions = YES; break; }
        popup.enabled = available && writable && hasOptions && canControl && self.onSetProperty != nil;
        NSString *summary = @"";
        if (!self.cameraReady) summary = [self text:@"等待联机" english:@"Waiting for connection"];
        else if (!available) summary = [self text:@"相机未提供此参数" english:@"Not available from the camera"];
        else if (!writable) summary = [self text:@"当前只读" english:@"Currently read-only"];
        else if (!hasOptions) summary = [self text:@"没有已确认的可选值" english:@"No confirmed camera options"];
        else if (self.busyState) summary = [self text:@"正在处理…" english:@"Working…"];
        self.reasonLabels[key].stringValue = summary;
        self.reasonLabels[key].hidden = summary.length == 0;
        popup.toolTip = summary.length ? summary : nil;
    }
}

- (void)setBusy:(BOOL)busy {
    if (self.busyState == busy) return;
    self.busyState = busy;
    [self updateInteractionStates];
}

- (void)setCameraReady:(BOOL)ready {
    if (_cameraReady == ready) return;
    _cameraReady = ready;
    [self updateInteractionStates];
}

- (void)setCaptureAvailable:(BOOL)available {
    if (_captureAvailable == available) return;
    _captureAvailable = available;
    [self updateInteractionStates];
}

- (void)setRemoteFocusAvailable:(BOOL)available {
    if (_remoteFocusAvailable == available) return;
    _remoteFocusAvailable = available;
    [self updateInteractionStates];
}

- (void)setCameraStorage:(NSDictionary *)storage {
    if (_cameraStorage == storage || [_cameraStorage isEqualToDictionary:storage]) return;
    _cameraStorage = [storage copy];
    NSNumber *target = [storage[@"target"] isKindOfClass:NSNumber.class] ? storage[@"target"] : nil;
    NSNumber *card = [storage[@"logical_card_available"] isKindOfClass:NSNumber.class] ? storage[@"logical_card_available"] : nil;
    NSString *cardStatus = [self text:@"存储卡状态未知" english:@"Card status unknown"];
    if (card) cardStatus = card.boolValue ? [self text:@"已识别存储卡" english:@"Card detected"]
                                         : [self text:@"未识别存储卡" english:@"No card detected"];
    self.bodyCaptureTargetLabel.stringValue = [NSString stringWithFormat:[self text:@"机身快门存储目标 · %@"
        english:@"Camera Shutter Storage · %@"], cardStatus];
    [self.bodyCaptureTargetPopup selectItemWithTag:target ? target.integerValue : -1];
    [self.bodyCaptureTargetPopup.menu itemWithTag:0].enabled = card.boolValue;
    [self.bodyCaptureTargetPopup.menu itemWithTag:2].enabled = card.boolValue;
    [self updateInteractionStates];
}

- (void)setSaveDirectory:(NSString *)directory {
    _saveDirectory = [directory copy] ?: @"";
    self.directoryLabel.stringValue = _saveDirectory.length ? _saveDirectory : [self text:@"尚未选择保存文件夹。" english:@"No save folder selected."];
    self.directoryLabel.toolTip = _saveDirectory.length ? _saveDirectory : nil;
    [self updateInteractionStates];
}

- (void)setLastSavedPath:(NSString *)path {
    _lastSavedPath = [path copy];
    self.lastSavedLabel.hidden = !path.length;
    self.lastSavedLabel.stringValue = path.length ? [NSString stringWithFormat:[self text:@"最近保存 %@" english:@"Last saved %@"], path.lastPathComponent] : @"";
    self.lastSavedLabel.toolTip = path;
    [self updateInteractionStates];
}

- (void)setTransferProgressMessage:(NSString *)message fraction:(double)fraction {
    BOOL visible = message.length > 0;
    BOOL wasVisible = !self.transferProgressStrip.hidden;
    BOOL indeterminate = fraction < 0.0 || !isfinite(fraction);
    NSProgressIndicator *indicator = self.transferProgressIndicator;
    BOOL wasAnimating = wasVisible && indicator.indeterminate;
    if (wasAnimating && (!visible || !indeterminate)) [indicator stopAnimation:nil];
    if (visible != wasVisible) {
        self.transferProgressStrip.hidden = !visible;
        self.transferProgressHeight.constant = visible ? TransferProgressHeight : 0.0;
    }
    if (!visible) return;

    if (![self.transferProgressLabel.stringValue isEqualToString:message])
        self.transferProgressLabel.stringValue = message;
    if (indicator.indeterminate != indeterminate) indicator.indeterminate = indeterminate;
    if (indeterminate) {
        if (!wasAnimating) [indicator startAnimation:nil];
    } else {
        indicator.doubleValue = MIN(fraction, 1.0);
    }
}

- (void)setResultMessage:(NSString *)message {
    self.resultLabel.textColor = NSColor.labelColor;
    if (![self.resultLabel.stringValue isEqualToString:message ?: @""])
        self.resultLabel.stringValue = message ?: @"";
    self.resultLabel.hidden = !message.length;
}

- (void)setWarningMessage:(NSString *)message {
    [self setResultMessage:message];
    self.resultLabel.textColor = NSColor.systemRedColor;
}

- (void)capture:(id)sender {
    (void)sender;
    NSInteger index = self.captureTargetPopup.indexOfSelectedItem;
    NSArray<NSString *> *destinations = @[@"current", @"mac", @"card_and_mac"];
    if (self.captureConsole.captureButton.enabled && self.onCapture && index >= 0 && index < (NSInteger)destinations.count)
        self.onCapture(destinations[(NSUInteger)index]);
}
- (void)stepFocus:(NSButton *)sender {
    if (!sender.enabled || !self.onFocusStep) return;
    if (sender == self.focusAButton) self.onFocusStep(@"a");
    else if (sender == self.focusBButton) self.onFocusStep(@"b");
}

- (void)bodyCaptureTargetChanged:(NSPopUpButton *)sender {
    NSMenuItem *selection = sender.selectedItem;
    NSInteger requested = selection.tag;
    NSNumber *current = self.cameraStorage[@"target"];
    [sender selectItemWithTag:current ? current.integerValue : -1];
    NSArray<NSString *> *targets = @[@"card", @"mac", @"card_and_mac"];
    if (sender.enabled && selection.enabled && current && requested >= 0 && requested < (NSInteger)targets.count &&
        requested != current.integerValue && self.onSetBodyCaptureTarget)
        self.onSetBodyCaptureTarget(targets[(NSUInteger)requested]);
}
- (void)chooseDirectory:(id)sender {
    (void)sender;
    if (self.directoryButton.enabled && self.onChooseDirectory) self.onChooseDirectory();
}
- (void)choosePhotoNaming:(id)sender {
    (void)sender;
    if (self.photoNamingButton.enabled && self.onChoosePhotoNaming) self.onChoosePhotoNaming();
}
- (void)refresh:(id)sender {
    (void)sender;
    if (self.refreshButton.enabled && self.onRefresh) self.onRefresh();
}
- (void)revealSavedPhoto:(id)sender {
    (void)sender;
    if (self.revealButton.enabled && self.onRevealSavedPhoto) self.onRevealSavedPhoto();
}
- (void)propertyChanged:(NSPopUpButton *)sender {
    NSNumber *raw = [sender.selectedItem.representedObject isKindOfClass:NSNumber.class] ? sender.selectedItem.representedObject : nil;
    if (sender.enabled && raw && sender.identifier.length && self.onSetProperty)
        self.onSetProperty(sender.identifier, raw);
}
@end
