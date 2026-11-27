#import "S1HPreviewView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSPoint clamped_pan(NSSize viewport, NSSize image, NSPoint pan) {
    CGFloat x = MAX(0, (image.width - viewport.width) / 2);
    CGFloat y = MAX(0, (image.height - viewport.height) / 2);
    return NSMakePoint(MIN(x, MAX(-x, pan.x)), MIN(y, MAX(-y, pan.y)));
}

@implementation S1HPreviewView {
    CALayer *_imageLayer;
    CAShapeLayer *_gridShadow;
    CAShapeLayer *_grid;
    NSSize _imagePixels;
    NSPoint _pan;
    NSPoint _lastDrag;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    _imageLayer = [CALayer layer];
    _imageLayer.contentsGravity = kCAGravityResize;
    _imageLayer.actions = @{@"contents": NSNull.null};
    _gridShadow = [CAShapeLayer layer];
    _gridShadow.fillColor = nil;
    _gridShadow.strokeColor = [NSColor.blackColor colorWithAlphaComponent:0.55].CGColor;
    _grid = [CAShapeLayer layer];
    _grid.fillColor = nil;
    _grid.strokeColor = [NSColor.whiteColor colorWithAlphaComponent:0.65].CGColor;
    [self.layer addSublayer:_imageLayer];
    [self.layer addSublayer:_gridShadow];
    [self.layer addSublayer:_grid];
    return self;
}

- (void)setPixelZoom:(NSInteger)pixelZoom {
    pixelZoom = MIN(2, MAX(0, pixelZoom));
    if (_pixelZoom == pixelZoom) return;
    _pixelZoom = pixelZoom;
    _pan = NSZeroPoint;
    [self setNeedsLayout:YES];
}

- (void)setShowsGrid:(BOOL)showsGrid {
    if (_showsGrid == showsGrid) return;
    _showsGrid = showsGrid;
    [self setNeedsLayout:YES];
}

- (void)displayFrame:(CGImageRef)frame {
    _imageLayer.contents = frame ? (__bridge id)frame : nil;
    NSSize pixels = frame ? NSMakeSize(CGImageGetWidth(frame), CGImageGetHeight(frame)) : NSZeroSize;
    if (!NSEqualSizes(_imagePixels, pixels)) {
        _imagePixels = pixels;
        _pan = NSZeroPoint;
        [self setNeedsLayout:YES];
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self setNeedsLayout:YES];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self setNeedsLayout:YES];
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat backingScale = MAX(1.0, self.window.backingScaleFactor);
    NSRect image = NSZeroRect;
    if (_imagePixels.width > 0 && _imagePixels.height > 0 && !NSIsEmptyRect(bounds)) {
        CGFloat scale = _pixelZoom ? _pixelZoom / backingScale :
            MIN(NSWidth(bounds) / _imagePixels.width, NSHeight(bounds) / _imagePixels.height);
        NSSize size = NSMakeSize(_imagePixels.width * scale, _imagePixels.height * scale);
        _pan = clamped_pan(bounds.size, size, _pan);
        image = NSMakeRect(NSMidX(bounds) - size.width / 2 + _pan.x,
                           NSMidY(bounds) - size.height / 2 + _pan.y, size.width, size.height);
        if (_pixelZoom) {
            image.origin.x = round(image.origin.x * backingScale) / backingScale;
            image.origin.y = round(image.origin.y * backingScale) / backingScale;
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _imageLayer.frame = image;
    _imageLayer.magnificationFilter = _pixelZoom ? kCAFilterNearest : kCAFilterLinear;
    BOOL gridVisible = _showsGrid && !NSIsEmptyRect(image);
    _grid.hidden = _gridShadow.hidden = !gridVisible;
    if (gridVisible) {
        CGMutablePathRef path = CGPathCreateMutable();
        for (int line = 1; line <= 2; ++line) {
            CGFloat x = NSMinX(image) + NSWidth(image) * line / 3;
            CGFloat y = NSMinY(image) + NSHeight(image) * line / 3;
            CGPathMoveToPoint(path, NULL, x, NSMinY(image));
            CGPathAddLineToPoint(path, NULL, x, NSMaxY(image));
            CGPathMoveToPoint(path, NULL, NSMinX(image), y);
            CGPathAddLineToPoint(path, NULL, NSMaxX(image), y);
        }
        for (CAShapeLayer *layer in @[_gridShadow, _grid]) {
            layer.frame = bounds;
            layer.contentsScale = backingScale;
            layer.path = path;
        }
        _gridShadow.lineWidth = 3 / backingScale;
        _grid.lineWidth = 1 / backingScale;
        CGPathRelease(path);
    }
    [CATransaction commit];
}

- (void)mouseDown:(NSEvent *)event {
    if (!_pixelZoom || !_imagePixels.width) { [super mouseDown:event]; return; }
    _lastDrag = [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pixelZoom || !_imagePixels.width) { [super mouseDragged:event]; return; }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _pan.x += point.x - _lastDrag.x;
    _pan.y += point.y - _lastDrag.y;
    _lastDrag = point;
    [self setNeedsLayout:YES];
}
@end
