#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

// PURE RGB's standard dark palette for the camera's dedicated LCD and key.
typedef NS_ENUM(uint32_t, S1HStyleRGB) {
    S1HStyleBackground = 0x242322,
    S1HStylePanel = 0x2B2927,
    S1HStyleField = 0x302F2E,
    S1HStyleOutline = 0x494643,
    S1HStyleText = 0xF2EDE4,
    S1HStyleMuted = 0xC4C4C4,
    S1HStyleAccent = 0xFF8052,
    S1HStylePrimaryLight = 0xDF361A,
    S1HStylePrimaryDark = 0xCA2415,
};

static inline NSColor *S1HStyleColor(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                              green:((rgb >> 8) & 255) / 255.0
                               blue:(rgb & 255) / 255.0 alpha:1.0];
}

static inline NSView *S1HStyleGlass(NSRect frame, NSView *content, NSVisualEffectMaterial fallback, CGFloat radius) {
    content.frame = NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame));
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
        glass.style = NSGlassEffectViewStyleClear;
        glass.cornerRadius = radius;
        glass.contentView = content;
        return glass;
    }
#endif
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:frame];
    glass.material = fallback;
    glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = radius;
    glass.layer.masksToBounds = YES;
    [glass addSubview:content];
    return glass;
}

static inline void S1HStyleButton(NSButton *button) {
    button.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
}

static inline void S1HStylePopup(NSPopUpButton *popup) {
    popup.alignment = NSTextAlignmentLeft;
    popup.font = [NSFont systemFontOfSize:13.0];
}
