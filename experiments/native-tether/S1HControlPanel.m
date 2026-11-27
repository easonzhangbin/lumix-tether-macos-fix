#import "S1HControlPanel.h"

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
@property(nonatomic, copy) NSString *saveDirectory;
@property(nonatomic, copy) NSString *lastSavedPath;
@property(nonatomic, copy) NSDictionary *controls;
@property(nonatomic, strong) NSButton *captureButton;
@property(nonatomic, strong) NSPopUpButton *captureTargetPopup;
@property(nonatomic, strong) NSTextField *driveModeLabel;
@property(nonatomic, strong) NSButton *directoryButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSTextField *directoryLabel;
@property(nonatomic, strong) NSTextField *lastSavedLabel;
@property(nonatomic, strong) NSTextField *resultLabel;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSPopUpButton *> *popups;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *reasonLabels;
@end

@implementation S1HControlPanel
@synthesize onCapture = _onCapture;
@synthesize onChooseDirectory = _onChooseDirectory;
@synthesize onSetProperty = _onSetProperty;
@synthesize onRefresh = _onRefresh;

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

- (void)buildPanel {
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    self.controls = @{};
    self.saveDirectory = @"";
    self.popups = [NSMutableDictionary dictionary];
    self.reasonLabels = [NSMutableDictionary dictionary];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    [self addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
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

    [self addView:[self label:[self text:@"拍摄控制" english:@"Shooting controls"]
        font:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold] wrapping:NO] toStack:stack];

    self.driveModeLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:YES];
    self.driveModeLabel.hidden = YES;
    [self addView:self.driveModeLabel toStack:stack];
    self.captureTargetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.captureTargetPopup addItemsWithTitles:@[[self text:@"保持机身存储目标" english:@"Keep Camera Storage Target"],
        [self text:@"仅保存到 Mac" english:@"Save to Mac Only"],
        [self text:@"存储卡＋Mac（测试）" english:@"Card + Mac (Test)"]]];
    [self.captureTargetPopup selectItemAtIndex:1];
    self.captureTargetPopup.accessibilityLabel = [self text:@"拍摄存储目标" english:@"Capture storage target"];
    self.captureTargetPopup.toolTip = [self text:@"此选项用于软件快门。拍摄时临时切换，确认结束后恢复相机原设置。机身快门沿用相机当前的联机存储目标。存储卡＋Mac 需要相机已识别的存储卡。"
        english:@"This option applies to the app shutter. The camera's target is restored after a confirmed finish. The camera shutter uses the active tether target. Card + Mac requires a recognized card."];
    [self addView:self.captureTargetPopup toStack:stack];
    self.captureButton = [NSButton buttonWithTitle:[self text:@"拍摄并保存" english:@"Capture and Save"] target:self action:@selector(capture:)];
    self.captureButton.bezelStyle = NSBezelStyleRounded;
    [self addView:self.captureButton toStack:stack];
    self.resultLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:YES];
    self.resultLabel.hidden = YES;
    [self addView:self.resultLabel toStack:stack];
    self.directoryButton = [NSButton buttonWithTitle:[self text:@"选择照片保存文件夹…" english:@"Choose Save Folder…"] target:self action:@selector(chooseDirectory:)];
    [self addView:self.directoryButton toStack:stack];
    self.directoryLabel = [self label:@"" font:[NSFont systemFontOfSize:11] wrapping:YES];
    self.directoryLabel.textColor = NSColor.secondaryLabelColor;
    [self addView:self.directoryLabel toStack:stack];
    self.lastSavedLabel = [self label:@"" font:[NSFont systemFontOfSize:12] wrapping:NO];
    [self addView:self.lastSavedLabel toStack:stack];
    self.revealButton = [NSButton buttonWithTitle:[self text:@"在访达中显示最近一张" english:@"Show Last Photo in Finder"] target:self action:@selector(revealSavedPhoto:)];
    [self addView:self.revealButton toStack:stack];

    self.refreshButton = [NSButton buttonWithTitle:[self text:@"刷新相机参数" english:@"Refresh Camera Settings"] target:self action:@selector(refresh:)];
    [self addView:self.refreshButton toStack:stack];
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
- (void)setOnChooseDirectory:(void (^)(void))block {
    _onChooseDirectory = [block copy];
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

- (void)updateCapabilities:(NSDictionary *)controls busy:(BOOL)busy {
    self.controls = [controls isKindOfClass:NSDictionary.class] ? [controls copy] : @{};
    self.busyState = busy;
    NSDictionary<NSString *, NSString *> *whiteBalanceTranslations = self.chinese ? @{
        @"Auto": @"自动", @"Daylight": @"晴天", @"Fluorescent": @"荧光灯", @"Tungsten": @"白炽灯",
        @"Flash": @"闪光灯", @"Cloudy": @"阴天", @"Shade": @"阴影", @"White Set": @"手动白平衡",
        @"White Set 1": @"手动白平衡 1", @"White Set 2": @"手动白平衡 2",
        @"White Set 3": @"手动白平衡 3", @"White Set 4": @"手动白平衡 4",
        @"Temperature 1": @"色温 1", @"Temperature 2": @"色温 2", @"Temperature 3": @"色温 3",
        @"Temperature 4": @"色温 4", @"Auto cool": @"自动（偏冷）", @"Auto warm": @"自动（偏暖）"
    } : nil;
    for (NSString *key in self.popups) {
        NSDictionary<NSString *, NSString *> *translations = [key isEqualToString:@"white_balance"] ? whiteBalanceTranslations : nil;
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

- (void)updateInteractionStates {
    BOOL canControl = self.cameraReady && !self.busyState;
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
    self.captureButton.enabled = canControl && self.captureAvailable && self.saveDirectory.length > 0 && self.onCapture != nil;
    self.captureTargetPopup.enabled = !self.busyState;
    self.directoryButton.enabled = !self.busyState && self.onChooseDirectory != nil;
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
    if (self.captureButton.enabled && self.onCapture && index >= 0 && index < (NSInteger)destinations.count)
        self.onCapture(destinations[(NSUInteger)index]);
}
- (void)chooseDirectory:(id)sender {
    (void)sender;
    if (self.directoryButton.enabled && self.onChooseDirectory) self.onChooseDirectory();
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
