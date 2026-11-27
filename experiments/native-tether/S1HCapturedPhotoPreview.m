#import "S1HCapturedPhotoPreview.h"
#import <ImageIO/ImageIO.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

enum { S1HReviewMaxEdge = 1600, S1HReviewMaxJPEGBytes = 64 * 1024 * 1024,
       S1HReviewMaxRAWBytes = 1024 * 1024 * 1024 };

static size_t ReadPhotoBytes(int fd, void *output, off_t offset, size_t count) {
    size_t total = 0;
    while (total < count) {
        ssize_t size = pread(fd, (unsigned char *)output + total, count - total, offset + (off_t)total);
        if (size < 0 && errno == EINTR) continue;
        if (size <= 0) break;
        total += (size_t)size;
    }
    return total;
}

static CGImageRef CopyPhotoThumbnail(CGImageSourceRef source, BOOL raw) {
    if (!source || CGImageSourceGetCount(source) == 0) return NULL;
    CFStringRef type = CGImageSourceGetType(source);
    if (!type) return NULL;
    if (raw) {
        if (!CFEqual(type, CFSTR("com.panasonic.rw2-raw-image")) && !CFEqual(type, CFSTR("com.panasonic.raw-image")))
            return NULL;
    } else if (!CFEqual(type, CFSTR("public.jpeg"))) return NULL;
    if (!raw) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        if (!width || !height || width > 16000 || height > 16000 || width * height > 120000000 ||
            CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) return NULL;
    }
    // Let ImageIO apply EXIF orientation. Only use an existing embedded thumbnail for RAW.
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @(!raw),
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(S1HReviewMaxEdge),
        (__bridge NSString *)kCGImageSourceShouldCache: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
    });
    if (image && (CGImageGetWidth(image) > S1HReviewMaxEdge || CGImageGetHeight(image) > S1HReviewMaxEdge)) {
        CGImageRelease(image);
        return NULL;
    }
    return image;
}

static uint16_t ReadLE16(const unsigned char *bytes) {
    return (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t ReadLE32(const unsigned char *bytes) {
    return ReadLE16(bytes) | ((uint32_t)ReadLE16(bytes + 2) << 16);
}

static CGImageRef CopyRW2EmbeddedJPEG(int fd, off_t fileSize) {
    enum { MaxEntries = 256, EntrySize = 12, PreviewTag = 0x002e, UndefinedType = 7,
           MaxPreviewBytes = 16 * 1024 * 1024 };
    unsigned char header[8], countBytes[2], entries[MaxEntries * EntrySize];
    if (ReadPhotoBytes(fd, header, 0, sizeof header) != sizeof header ||
        memcmp(header, "II\x55\x00", 4) != 0) return NULL;
    uint32_t ifd = ReadLE32(header + 4);
    if (ifd < sizeof header || ifd > 4096 || (off_t)ifd + 2 > fileSize ||
        ReadPhotoBytes(fd, countBytes, ifd, sizeof countBytes) != sizeof countBytes) return NULL;
    uint16_t count = ReadLE16(countBytes);
    size_t tableLength = (size_t)count * EntrySize;
    off_t tableEnd = (off_t)ifd + 2 + (off_t)tableLength + 4;
    if (!count || count > MaxEntries || tableEnd > fileSize ||
        ReadPhotoBytes(fd, entries, ifd + 2, tableLength) != tableLength) return NULL;

    // JpgFromRaw contains the camera's rendered JPEG, including its own EXIF orientation.
    for (uint16_t i = 0; i < count; ++i) {
        const unsigned char *entry = entries + i * EntrySize;
        if (ReadLE16(entry) != PreviewTag) continue;
        uint32_t length = ReadLE32(entry + 4), start = ReadLE32(entry + 8);
        if (ReadLE16(entry + 2) != UndefinedType || length <= 4 || length > MaxPreviewBytes ||
            (off_t)start < tableEnd || (off_t)start + length > fileSize) return NULL;
        NSMutableData *jpeg = [NSMutableData dataWithLength:length];
        if (ReadPhotoBytes(fd, jpeg.mutableBytes, start, length) != length) return NULL;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
        CGImageRef thumbnail = CopyPhotoThumbnail(source, NO);
        if (source) CFRelease(source);
        return thumbnail;
    }
    return NULL;
}

CGImageRef S1HCopyCapturedPhotoPreview(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    BOOL raw = [extension isEqualToString:@"rw2"];
    if (!url.isFileURL || (!raw && ![extension isEqualToString:@"jpg"] && ![extension isEqualToString:@"jpeg"])) return NULL;
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    CGImageRef thumbnail = NULL;
    struct stat info;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 &&
        info.st_size <= (raw ? S1HReviewMaxRAWBytes : S1HReviewMaxJPEGBytes)) {
        // ImageIO's URL-backed source can locate the embedded thumbnail without
        // copying a large RAW. The descriptor refers to the same checked file.
        NSURL *descriptorURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/dev/fd/%d", fd]];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)descriptorURL, NULL);
        thumbnail = CopyPhotoThumbnail(source, raw);
        if (source) CFRelease(source);
        if (!thumbnail && raw) thumbnail = CopyRW2EmbeddedJPEG(fd, info.st_size);
    }
    close(fd);
    return thumbnail;
}
