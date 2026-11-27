#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Decode a local capture for display. Call on a background queue.
CGImageRef _Nullable S1HCopyCapturedPhotoPreview(NSURL * _Nonnull url) CF_RETURNS_RETAINED;
