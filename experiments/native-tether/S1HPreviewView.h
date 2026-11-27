#import <Cocoa/Cocoa.h>

@interface S1HPreviewView : NSView
// 0 fits the window. 1 and 2 use one or two screen pixels per preview pixel.
@property(nonatomic) NSInteger pixelZoom;
@property(nonatomic) BOOL showsGrid;
- (void)displayFrame:(CGImageRef)frame;
@end
