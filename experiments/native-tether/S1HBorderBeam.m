#import "S1HBorderBeam.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

typedef struct {
    CGFloat radius;
    CGFloat sideLengths[4];
    CGPoint sideStarts[4];
    CGPoint arcCenters[4];
    CGFloat perimeter;
} S1HBeamOutline;

static S1HBeamOutline S1HBeamOutlineMake(NSRect rect) {
    CGFloat radius = MIN(7.0, MIN(NSWidth(rect), NSHeight(rect)) / 2.0);
    CGFloat left = NSMinX(rect), right = NSMaxX(rect), top = NSMaxY(rect), bottom = NSMinY(rect);
    CGFloat horizontal = NSWidth(rect) - 2.0 * radius;
    CGFloat vertical = NSHeight(rect) - 2.0 * radius;
    return (S1HBeamOutline){
        .radius = radius,
        .sideLengths = {horizontal, vertical, horizontal, vertical},
        .sideStarts = {{left + radius, top}, {right, top - radius}, {right - radius, bottom}, {left, bottom + radius}},
        .arcCenters = {{right - radius, top - radius}, {right - radius, bottom + radius},
                       {left + radius, bottom + radius}, {left + radius, top - radius}},
        .perimeter = 2.0 * (horizontal + vertical) + 2.0 * M_PI * radius
    };
}

static CGPoint S1HBeamPointAtDistance(const S1HBeamOutline *outline, CGFloat distance) {
    static const CGPoint sideDirections[] = {{1, 0}, {0, -1}, {-1, 0}, {0, 1}};
    distance = fmod(distance, outline->perimeter);
    if (distance < 0.0) distance += outline->perimeter;
    const CGFloat arcLength = M_PI_2 * outline->radius;
    for (NSUInteger side = 0; side < 4; side++) {
        if (distance < outline->sideLengths[side]) {
            CGPoint start = outline->sideStarts[side];
            return CGPointMake(start.x + sideDirections[side].x * distance,
                               start.y + sideDirections[side].y * distance);
        }
        distance -= outline->sideLengths[side];
        if (distance < arcLength) {
            CGPoint center = outline->arcCenters[side];
            CGFloat angle = (1.0 - side) * M_PI_2 - distance / outline->radius;
            return CGPointMake(center.x + outline->radius * cos(angle), center.y + outline->radius * sin(angle));
        }
        distance -= arcLength;
    }
    return outline->sideStarts[0];
}

@interface S1HBorderBeam ()
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic) CFTimeInterval animationStart;
@end

@implementation S1HBorderBeam

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.hidden = YES;
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(displayOptionsChanged:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:NSWorkspace.sharedWorkspace];
    }
    return self;
}

- (void)dealloc {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_animationTimer invalidate];
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (BOOL)isAccessibilityElement { return NO; }

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    self.hidden = !active;
    [self updateAnimation];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (self.window) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:self.window];
    }
    if (newWindow) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayOptionsChanged:)
            name:NSWindowDidChangeOcclusionStateNotification object:newWindow];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateAnimation];
}

- (void)displayOptionsChanged:(NSNotification *)notification {
    (void)notification;
    if (NSThread.isMainThread) [self updateAnimation];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self updateAnimation]; });
}

- (void)updateAnimation {
    NSWindow *window = self.window;
    BOOL animate = self.active && window.isVisible && (window.occlusionState & NSWindowOcclusionStateVisible) &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (animate && !self.animationTimer) {
        self.animationStart = CACurrentMediaTime();
        __weak S1HBorderBeam *view = self;
        self.animationTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            view.needsDisplay = YES;
        }];
        self.animationTimer.tolerance = 0.004;
        [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    } else if (!animate && self.animationTimer) {
        [self.animationTimer invalidate];
        self.animationTimer = nil;
    }
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!self.active) return;
    NSRect rect = NSInsetRect(self.bounds, 3.5, 4.0);
    if (NSIsEmptyRect(rect)) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context) return;

    const S1HBeamOutline outline = S1HBeamOutlineMake(rect);
    const CGFloat elapsed = self.animationTimer ? CACurrentMediaTime() - self.animationStart : 0.0;
    const CGFloat head = outline.perimeter * 0.33 + elapsed * 78.0;
    const CGFloat beamLength = MIN(62.0, outline.perimeter * 0.28);
    const NSUInteger segmentCount = 28;
    CGPoint points[29];
    for (NSUInteger index = 0; index <= segmentCount; index++) {
        points[index] = S1HBeamPointAtDistance(&outline, head - beamLength + beamLength * index / segmentCount);
    }

    CGContextSaveGState(context);
    CGContextSetLineCap(context, kCGLineCapRound);
    // Wider translucent strokes approximate a soft halo around the bright core.
    static const CGFloat widths[] = {6.0, 4.0, 2.4, 1.25};
    static const CGFloat opacities[] = {0.045, 0.08, 0.17, 0.9};
    for (NSUInteger layer = 0; layer < 4; layer++) {
        CGContextSetLineWidth(context, widths[layer]);
        for (NSUInteger index = 0; index < segmentCount; index++) {
            CGFloat progress = (index + 1.0) / segmentCount;
            CGFloat intensity = progress * progress;
            CGContextSetRGBStrokeColor(context, 0.08 + 0.62 * intensity, 0.82 + 0.16 * intensity, 0.98,
                                       opacities[layer] * intensity);
            CGContextStrokeLineSegments(context, &points[index], 2);
        }
    }
    CGContextRestoreGState(context);
}

@end
