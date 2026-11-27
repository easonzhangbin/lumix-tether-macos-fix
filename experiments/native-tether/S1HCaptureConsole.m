#import "S1HCaptureConsole.h"
#import "S1HInterfaceStyle.h"
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSFont *S1HConsoleDataFont(CGFloat size, BOOL light) {
    static dispatch_once_t registration;
    dispatch_once(&registration, ^{
        NSBundle *bundle = NSBundle.mainBundle;
        for (NSString *name in @[@"LG1055-Light", @"LG1055_R"]) {
            NSURL *fontURL = [bundle URLForResource:name withExtension:@"ttf" subdirectory:@"Fonts"];
            if (fontURL) CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, NULL);
        }
    });
    NSFont *font = [NSFont fontWithName:(light ? @"LG1055Light-Light" : @"LG1055-Regular") size:size];
    return font ?: [NSFont monospacedDigitSystemFontOfSize:size weight:light ? NSFontWeightSemibold : NSFontWeightMedium];
}

static void S1HConsolePlaceLabel(NSTextField *label, NSRect frame, CGFloat baseline) {
    frame.origin.y = baseline + label.firstBaselineOffsetFromTop - NSHeight(frame);
    label.frame = frame;
}

@interface S1HCaptureLCD : NSView
@end

@implementation S1HCaptureLCD
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (NSIsEmptyRect(self.bounds)) return;
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12.0 yRadius:12.0];
    NSGradient *glass = [[NSGradient alloc] initWithStartingColor:S1HStyleColor(S1HStyleField)
                                                     endingColor:S1HStyleColor(S1HStylePanel)];
    [glass drawInBezierPath:body angle:-90.0];

    [S1HStyleColor(S1HStyleOutline) setFill];
    CGFloat dividerWidth = MAX(0.0, NSWidth(self.bounds) - 24.0);
    CGFloat pixel = 1.0 / MAX(1.0, self.window.backingScaleFactor);
    NSRectFill(NSMakeRect(12.0, NSHeight(self.bounds) - 31.0, dividerWidth, pixel));
    NSRectFill(NSMakeRect(12.0, 30.0, dividerWidth, pixel));
}
@end

@interface S1HRedShutterButton : NSButton
@property(nonatomic, strong) NSImage *readyGlyph;
@property(nonatomic, strong) NSImage *mutedGlyph;
@end

@implementation S1HRedShutterButton
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setButtonType:NSButtonTypeMomentaryPushIn];
        self.bordered = NO;
        self.focusRingType = NSFocusRingTypeExterior;
        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"camera.fill" accessibilityDescription:nil];
        NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:22.0 weight:NSFontWeightMedium];
        NSImageSymbolConfiguration *ready = [NSImageSymbolConfiguration configurationWithPaletteColors:@[S1HStyleColor(S1HStyleText)]];
        NSImageSymbolConfiguration *muted = [NSImageSymbolConfiguration configurationWithPaletteColors:@[S1HStyleColor(S1HStyleMuted)]];
        self.readyGlyph = [symbol imageWithSymbolConfiguration:[size configurationByApplyingConfiguration:ready]];
        self.mutedGlyph = [symbol imageWithSymbolConfiguration:[size configurationByApplyingConfiguration:muted]];
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    if (self.isEnabled == enabled) return;
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

- (NSRect)focusRingMaskBounds { return NSInsetRect(self.bounds, 3.5, 3.5); }

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithOvalInRect:self.focusRingMaskBounds] fill];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL enabled = self.isEnabled;
    BOOL pressed = enabled && self.cell.isHighlighted;
    NSRect outerRect = NSInsetRect(self.bounds, 4.0, 4.0);
    if (NSIsEmptyRect(outerRect)) return;

    NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:outerRect];
    [S1HStyleColor(S1HStylePanel) setFill];
    [outer fill];
    NSColor *accent = S1HStyleColor(S1HStyleAccent);
    NSColor *outline = S1HStyleColor(S1HStyleOutline);
    [(enabled ? accent : [accent blendedColorWithFraction:0.73 ofColor:outline]) setStroke];
    outer.lineWidth = 1.5;
    [outer stroke];

    NSRect keyRect = NSInsetRect(outerRect, pressed ? 6.0 : 5.0, pressed ? 6.0 : 5.0);
    NSBezierPath *key = [NSBezierPath bezierPathWithOvalInRect:keyRect];
    NSColor *highlight = S1HStyleColor(S1HStylePrimaryLight);
    NSColor *shade = S1HStyleColor(S1HStylePrimaryDark);
    if (!enabled) {
        highlight = [highlight blendedColorWithFraction:0.68 ofColor:S1HStyleColor(S1HStyleField)];
        shade = [shade blendedColorWithFraction:0.77 ofColor:S1HStyleColor(S1HStylePanel)];
    } else if (pressed) {
        highlight = [highlight blendedColorWithFraction:0.45 ofColor:shade];
        shade = [shade blendedColorWithFraction:0.24 ofColor:S1HStyleColor(S1HStyleBackground)];
    }
    NSGradient *red = [[NSGradient alloc] initWithStartingColor:highlight endingColor:shade];
    [red drawInBezierPath:key angle:90.0];
    [[highlight colorWithAlphaComponent:0.75] setStroke];
    key.lineWidth = 0.75;
    [key stroke];

    NSImage *glyph = enabled ? self.readyGlyph : self.mutedGlyph;
    NSSize size = glyph.size;
    CGFloat pressedOffset = pressed ? (self.isFlipped ? 0.75 : -0.75) : 0.0;
    NSRect glyphRect = NSMakeRect(NSMidX(keyRect) - size.width / 2.0,
                                  NSMidY(keyRect) - size.height / 2.0 + pressedOffset,
                                  size.width, size.height);
    [glyph drawInRect:glyphRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
             fraction:1.0 respectFlipped:YES hints:nil];
}
@end

@interface S1HCaptureConsole ()
@property(nonatomic, strong, readwrite) NSButton *captureButton;
@property(nonatomic) BOOL chinese;
@property(nonatomic, strong) S1HCaptureLCD *screen;
@property(nonatomic, strong) NSTextField *cameraLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSArray<NSTextField *> *metricLabels;
@property(nonatomic, strong) NSArray<NSTextField *> *metricValues;
@property(nonatomic, strong) NSTextField *balanceLabel;
@property(nonatomic, strong) NSTextField *balanceValue;
@property(nonatomic, strong) NSTextField *exposureValue;
@property(nonatomic, strong) NSTextField *captureCaption;
@end

@implementation S1HCaptureConsole
- (NSString *)text:(NSString *)zh english:(NSString *)en {
    return self.chinese ? zh : en;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self buildConsole];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self buildConsole];
    return self;
}

- (NSTextField *)label:(NSString *)text font:(NSFont *)font color:(NSColor *)color inView:(NSView *)view {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = font;
    field.textColor = color;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    [view addSubview:field];
    return field;
}

- (void)buildConsole {
    self.chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    self.screen = [S1HCaptureLCD new];
    [self addSubview:self.screen];

    NSColor *primary = S1HStyleColor(S1HStyleText);
    NSColor *secondary = S1HStyleColor(S1HStyleMuted);
    NSFont *small = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.cameraLabel = [self label:@"DC-S1H" font:[NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold]
                              color:primary inView:self.screen];
    self.statusLabel = [self label:@"" font:small color:secondary inView:self.screen];
    self.statusLabel.alignment = NSTextAlignmentRight;
    self.statusDot = [NSView new];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 2.5;
    [self.screen addSubview:self.statusDot];

    NSArray<NSString *> *titles = @[@"ISO", [self text:@"快门" english:@"Shutter"], [self text:@"光圈" english:@"Aperture"]];
    NSMutableArray<NSTextField *> *labels = [NSMutableArray arrayWithCapacity:titles.count];
    NSMutableArray<NSTextField *> *values = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        [labels addObject:[self label:title font:small color:secondary inView:self.screen]];
        [values addObject:[self label:@"—" font:S1HConsoleDataFont(19.0, YES)
                                color:primary inView:self.screen]];
    }
    self.metricLabels = labels;
    self.metricValues = values;

    self.balanceLabel = [self label:[self text:@"白平衡" english:@"WB"] font:small color:secondary inView:self.screen];
    self.balanceValue = [self label:@"—" font:small color:primary inView:self.screen];
    self.exposureValue = [self label:@"" font:S1HConsoleDataFont(11.0, NO)
                                  color:secondary inView:self.screen];
    self.exposureValue.alignment = NSTextAlignmentRight;

    self.captureButton = [[S1HRedShutterButton alloc] initWithFrame:NSZeroRect];
    self.captureButton.title = [self text:@"拍摄并保存" english:@"Capture and Save"];
    self.captureButton.accessibilityLabel = self.captureButton.title;
    self.captureButton.toolTip = self.captureButton.title;
    self.captureButton.enabled = NO;
    [self addSubview:self.captureButton];
    self.captureCaption = [self label:[self text:@"拍摄" english:@"Capture"]
                                     font:[NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold]
                                    color:secondary inView:self];
    self.captureCaption.alignment = NSTextAlignmentCenter;
    [self.captureCaption setAccessibilityElement:NO];
    [self updateWithValues:@{} cameraReady:NO busy:NO];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat screenWidth = MAX(0.0, width - 108.0);
    CGFloat screenHeight = 112.0;
    CGFloat laneX = width - 84.0;
    self.screen.frame = NSMakeRect(12.0, floor((height - screenHeight) / 2.0) + 1.0, screenWidth, screenHeight);
    self.captureButton.frame = NSMakeRect(laneX + 2.0, floor((height - 68.0) / 2.0) + 8.0, 68.0, 68.0);
    self.captureCaption.frame = NSMakeRect(laneX, NSMinY(self.captureButton.frame) - 18.0, 72.0, 15.0);

    self.cameraLabel.frame = NSMakeRect(12.0, 89.0, 88.0, 14.0);
    self.statusLabel.frame = NSMakeRect(screenWidth - 104.0, 89.0, 92.0, 14.0);
    [self layoutStatusDot];

    CGFloat column = MAX(0.0, screenWidth - 24.0) / 3.0;
    CGFloat fieldWidth = MAX(0.0, column - 5.0);
    for (NSUInteger index = 0; index < self.metricLabels.count; ++index) {
        CGFloat x = floor(12.0 + index * column);
        self.metricLabels[index].frame = NSMakeRect(x, 59.0, fieldWidth, 15.0);
        NSTextField *value = self.metricValues[index];
        [self fitMetric:value width:fieldWidth];
        S1HConsolePlaceLabel(value, NSMakeRect(x, 0.0, fieldWidth, 24.0), 34.0);
    }

    CGFloat balanceLabelWidth = ceil(self.balanceLabel.cell.cellSize.width) + 2.0;
    CGFloat balanceX = 17.0 + balanceLabelWidth;
    CGFloat exposureWidth = self.exposureValue.hidden ? 0.0 : 57.0;
    CGFloat footerBaseline = 12.0;
    S1HConsolePlaceLabel(self.balanceLabel, NSMakeRect(12.0, 0.0, balanceLabelWidth, 15.0), footerBaseline);
    S1HConsolePlaceLabel(self.balanceValue, NSMakeRect(balanceX, 0.0, MAX(0.0, screenWidth - balanceX - exposureWidth - 12.0), 15.0), footerBaseline);
    S1HConsolePlaceLabel(self.exposureValue, NSMakeRect(screenWidth - exposureWidth - 12.0, 0.0, exposureWidth, 15.0), footerBaseline);
}

- (void)fitMetric:(NSTextField *)field width:(CGFloat)width {
    NSFont *normal = S1HConsoleDataFont(19.0, YES);
    CGFloat estimatedWidth = [field.stringValue sizeWithAttributes:@{NSFontAttributeName:normal}].width;
    // Label cells reserve four points around the text.
    CGFloat available = width - 5.0;
    if (available > 0.0 && estimatedWidth > available)
        normal = S1HConsoleDataFont(MAX(13.0, floor(19.0 * available / estimatedWidth)), YES);
    field.font = normal;
}

- (void)layoutStatusDot {
    CGFloat width = [self.statusLabel.stringValue sizeWithAttributes:@{NSFontAttributeName:self.statusLabel.font}].width;
    CGFloat right = NSMaxX(self.statusLabel.frame);
    self.statusDot.frame = NSMakeRect(floor(right - width - 11.0), 94.0, 5.0, 5.0);
}

- (void)updateWithValues:(NSDictionary<NSString *, NSString *> *)values cameraReady:(BOOL)cameraReady busy:(BOOL)busy {
    BOOL shutterReady = cameraReady && self.captureButton.isEnabled && !busy;
    NSString *state = [self text:@"未连接" english:@"Offline"];
    NSColor *color = S1HStyleColor(S1HStyleMuted);
    if (busy) {
        state = [self text:@"处理中" english:@"Working"];
        color = S1HStyleColor(0xF5BA79);
    } else if (shutterReady) {
        state = [self text:@"就绪" english:@"Ready"];
        color = S1HStyleColor(0x9BE2C6);
    } else if (cameraReady) {
        state = [self text:@"已连接" english:@"Connected"];
        color = S1HStyleColor(0x9FC4D4);
    }
    self.statusLabel.stringValue = state;
    self.statusLabel.textColor = color;
    self.statusDot.layer.backgroundColor = color.CGColor;

    NSArray<NSString *> *keys = @[@"iso", @"shutter", @"aperture"];
    for (NSUInteger index = 0; index < keys.count; ++index) {
        NSString *value = cameraReady ? values[keys[index]] : nil;
        self.metricValues[index].stringValue = value.length ? value : @"—";
        self.metricValues[index].toolTip = value.length ? value : nil;
    }
    NSString *balance = cameraReady ? values[@"white_balance"] : nil;
    self.balanceValue.stringValue = balance.length ? balance : @"—";
    self.balanceValue.toolTip = balance.length ? balance : nil;
    NSString *exposure = cameraReady ? values[@"exposure_compensation"] : nil;
    self.exposureValue.stringValue = exposure ?: @"";
    self.exposureValue.hidden = !exposure.length;
    self.needsLayout = YES;
}
@end
