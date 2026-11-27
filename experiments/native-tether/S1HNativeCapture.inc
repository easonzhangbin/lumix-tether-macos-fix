/* Independent S1H still capture and bounded photo transfer.
 * Included after NativePreviewTransport; no vendor runtime is used.
 * Protocol facts: libgphoto2 31a2f4089f19aec6caca7920b03e3eb7a251c5b6,
 * Panasonic 9404/03000011 and C108/C109; standard PTP object datasets.
 * One invocation issues at most one shutter command. It never deletes a
 * camera object, retries a shutter, resets USB, or starts/stops preview.
 */
#import "S1HPhotoNaming.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

#define S1H_CAPTURE_CHUNK (1024U * 1024U)
#define S1H_CAPTURE_MAX_OBJECT (1024U * 1024U * 1024U)
#define S1H_CAPTURE_MAX_HANDLES 100000U
#define S1H_CAPTURE_MAX_FILES 16U
#define S1H_PTP_OK 0x2001
#define S1H_PTP_UNSUPPORTED 0x2005
#define S1H_PTP_INVALID_HANDLE 0x2009
#define S1H_PTP_STORE_NOT_AVAILABLE 0x2013
#define S1H_PTP_DEVICE_BUSY 0x2019
#define S1H_PTP_INVALID_PARAMETER 0x201d

typedef void (^S1HCaptureProgress)(NSDictionary *update);

static NSDictionary *s1h_capture_busy(NSString *phase, NSString *message) {
    return @{@"status": @"busy", @"phase": phase, @"message": message};
}

static NSDictionary *s1h_capture_file_progress(NSUInteger fileIndex, uint32_t written, uint32_t total, BOOL verifying) {
    NSString *message = verifying ? @"Verifying the received photo before saving." :
        [NSString stringWithFormat:@"Downloading photo: %.1f / %.1f MB", written / 1e6, total / 1e6];
    return @{@"status": @"busy", @"phase": verifying ? @"verifying" : @"download", @"message": message,
        @"file_index": @(fileIndex), @"downloaded_bytes": @(written), @"total_bytes": @(total)};
}

static NSDictionary *s1h_capture_result(NSString *state, NSString *message, BOOL issued, NSArray *files) {
    BOOL complete = [state isEqualToString:@"ok"] && files.count > 0;
    return @{@"status": state ?: @"error", @"message": message ?: @"Capture did not complete.",
             @"capture_issued": @(issued), @"files": files ?: @[], @"camera_delete_called": @NO,
             @"capture_complete": @(complete),
             @"safe_to_resume": @(complete || [state isEqualToString:@"rejected"])};
}
static NSArray<NSNumber *> *s1h_capture_handles(NSData *payload) {
    if (payload.length < 4) return nil;
    const unsigned char *bytes = payload.bytes;
    uint32_t count = read32(bytes);
    if (count > S1H_CAPTURE_MAX_HANDLES || payload.length != 4 + (NSUInteger)count * 4) return nil;
    NSMutableArray *handles = [NSMutableArray arrayWithCapacity:count];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:count];
    for (uint32_t i = 0; i < count; ++i) {
        NSNumber *handle = @(read32(bytes + 4 + i * 4));
        if (handle.unsignedIntValue == 0 || handle.unsignedIntValue == UINT32_MAX || [seen containsObject:handle]) return nil;
        [seen addObject:handle]; [handles addObject:handle];
    }
    return handles;
}
static NSString *s1h_capture_ptp_string(NSData *data, NSUInteger *offset) {
    if (*offset >= data.length) return nil;
    const unsigned char *bytes = data.bytes;
    NSUInteger count = bytes[(*offset)++];
    if (count == 0) return @"";
    if (count > (data.length - *offset) / 2 || read16(bytes + *offset + (count - 1) * 2) != 0) return nil;
    NSString *value = [[NSString alloc] initWithBytes:bytes + *offset length:(count - 1) * 2 encoding:NSUTF16LittleEndianStringEncoding];
    *offset += count * 2;
    return value;
}
static BOOL s1h_capture_name_valid(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 || name.length > 240 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name rangeOfString:@"/"].location != NSNotFound || [name rangeOfString:@":"].location != NSNotFound ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![name.lastPathComponent isEqualToString:name]) return NO;
    return [@[@"rw2", @"jpg", @"jpeg"] containsObject:name.pathExtension.lowercaseString];
}
static NSDictionary *s1h_capture_object_info(NSData *data) {
    if (data.length < 53) return nil;
    const unsigned char *bytes = data.bytes;
    uint16_t format = read16(bytes + 4);
    if (format == 0x3001) return @{@"association": @YES};
    uint32_t size = read32(bytes + 8), width = read32(bytes + 26), height = read32(bytes + 30);
    NSUInteger offset = 52;
    NSString *filename = s1h_capture_ptp_string(data, &offset);
    if (!s1h_capture_name_valid(filename) || size == 0 || size > S1H_CAPTURE_MAX_OBJECT ||
        width > 100000 || height > 100000) return nil;
    return @{@"name": filename, @"bytes": @(size), @"width": @(width), @"height": @(height),
             @"object_format": @(format), @"storage_id": @(read32(bytes)), @"association": @NO};
}
static NSDictionary *s1h_capture_extended_object_info(NSData *data) {
    if (data.length < 61) return nil;
    const unsigned char *bytes = data.bytes;
    uint16_t format = read16(bytes + 8);
    if (format == 0x3001) return @{ @"association": @YES };
    uint64_t size = read32(bytes + 12) | ((uint64_t)read32(bytes + 16) << 32);
    uint32_t width = read32(bytes + 34), height = read32(bytes + 38);
    NSUInteger offset = 60;
    NSString *filename = s1h_capture_ptp_string(data, &offset);
    if (!s1h_capture_name_valid(filename) || size == 0 || size > S1H_CAPTURE_MAX_OBJECT ||
        width > 100000 || height > 100000) return nil;
    return @{ @"name": filename, @"bytes": @(size), @"width": @(width), @"height": @(height),
        @"object_format": @(format), @"association": @NO, @"extended_object": @YES };
}
static int s1h_capture_open_directory(NSString *path) {
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@"/"]) continue;
        if (fd < 0) break;
        int child = openat(fd, component.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd);
        fd = child;
    }
    return fd;
}
static BOOL s1h_capture_has_space(int directoryFD, uint64_t requiredBytes) {
    struct statvfs volume;
    if (fstatvfs(directoryFD, &volume) != 0 || volume.f_frsize == 0) return NO;
    uint64_t blocks = requiredBytes / volume.f_frsize + (requiredBytes % volume.f_frsize != 0);
    return volume.f_bavail >= blocks;
}
static int s1h_capture_directory(NSString *requested, NSString **resolved, NSString **error) {
    if (![requested isKindOfClass:NSString.class] || !requested.length) {
        if (error) *error = @"Select a photo download folder before capture.";
        return -1;
    }
    NSString *path = requested.stringByExpandingTildeInPath;
    int fd = path.isAbsolutePath && ![path.pathComponents containsObject:@".."] ? s1h_capture_open_directory(path) : -1;
    if (fd < 0) {
        if (error) *error = @"Choose an existing photo download folder without symbolic links.";
        return -1;
    }
    /* Exercise create/write/flush before any shutter command; remove only
     * this newly-created empty test file, never a user photograph. */
    NSString *probe = [NSString stringWithFormat:@".s1h-write-check-%@", NSUUID.UUID.UUIDString];
    int probeFD = openat(fd, probe.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL writable = probeFD >= 0;
    if (probeFD >= 0) {
        unsigned char byte = 0;
        writable = write(probeFD, &byte, 1) == 1 && fsync(probeFD) == 0;
        close(probeFD);
        if (unlinkat(fd, probe.fileSystemRepresentation, 0) != 0) writable = NO;
    }
    BOOL space = s1h_capture_has_space(fd, 64ULL * 1024 * 1024);
    if (!writable || !space) {
        close(fd);
        if (error) *error = writable ? @"At least 64 MiB of free space is required before capture." : @"Photo download folder is not writable.";
        return -1;
    }
    if (resolved) *resolved = path;
    return fd;
}
static BOOL s1h_capture_write_all(int fd, NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = write(fd, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count; remaining -= (NSUInteger)count;
    }
    return YES;
}
static NSString *s1h_capture_finalize(int directoryFD, NSString *temporary, NSString *cameraName) {
    NSString *stem = cameraName.stringByDeletingPathExtension, *extension = cameraName.pathExtension;
    for (unsigned collision = 0; collision < 10000; ++collision) {
        NSString *name = collision == 0 ? cameraName : [NSString stringWithFormat:@"%@-%u.%@", stem, collision + 1, extension];
        if (renameatx_np(directoryFD, temporary.fileSystemRepresentation, directoryFD, name.fileSystemRepresentation, RENAME_EXCL) == 0)
            return name;
        if (errno != EEXIST) return nil;
    }
    return nil;
}

@interface S1HCaptureNaming : NSObject
@property(nonatomic, copy) NSString *prefix;
@property(nonatomic) uint64_t nextNumber;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *numbersByCameraStem;
@end
@implementation S1HCaptureNaming
@end

static uint64_t s1h_capture_named_ordinal(NSString *name, NSString *prefix) {
    if (!s1h_capture_name_valid(name)) return 0;
    NSString *stem = name.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping;
    NSRange separator = [stem rangeOfString:@"_" options:NSBackwardsSearch];
    if (separator.location == NSNotFound ||
        [[stem substringToIndex:separator.location] caseInsensitiveCompare:prefix] != NSOrderedSame) return 0;
    NSUInteger start = NSMaxRange(separator);
    if (stem.length - start < 4) return 0;
    uint64_t number = 0;
    for (NSUInteger index = start; index < stem.length; ++index) {
        unichar character = [stem characterAtIndex:index];
        if (character < '0' || character > '9') return 0;
        uint64_t digit = character - '0';
        if (number > (UINT64_MAX - digit) / 10) return 0;
        number = number * 10 + digit;
    }
    return number;
}

static S1HCaptureNaming *s1h_capture_prepare_naming(int directoryFD, NSString *prefix) {
    if (!prefix.length) return nil;
    int scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (scanFD < 0) return nil;
    DIR *scan = fdopendir(scanFD);
    if (!scan) { close(scanFD); return nil; }
    NSString *normalized = prefix.precomposedStringWithCanonicalMapping;
    uint64_t highest = 0;
    int scanError = 0;
    while (!StopRequested) {
        errno = 0;
        const struct dirent *entry = readdir(scan);
        if (!entry) { scanError = errno; break; }
        @autoreleasepool {
            NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
            uint64_t ordinal = s1h_capture_named_ordinal(name, normalized);
            highest = MAX(highest, ordinal);
        }
    }
    closedir(scan);
    if (scanError || StopRequested || highest == UINT64_MAX) return nil;
    S1HCaptureNaming *naming = [S1HCaptureNaming new];
    naming.prefix = normalized;
    naming.nextNumber = highest + 1;
    naming.numbersByCameraStem = [NSMutableDictionary dictionary];
    return naming;
}

static NSString *s1h_capture_finalize_named(int directoryFD, NSString *temporary, NSString *cameraName, S1HCaptureNaming *naming) {
    if (!naming) return s1h_capture_finalize(directoryFD, temporary, cameraName);
    NSString *stem = cameraName.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping.lowercaseString;
    NSString *extension = cameraName.pathExtension;
    NSNumber *paired = naming.numbersByCameraStem[stem];
    uint64_t number = paired ? paired.unsignedLongLongValue : naming.nextNumber;
    for (unsigned collision = 0; number && collision < 10000; ++collision) {
        NSString *name = [NSString stringWithFormat:@"%@_%04llu.%@", naming.prefix, (unsigned long long)number, extension];
        if (renameatx_np(directoryFD, temporary.fileSystemRepresentation, directoryFD, name.fileSystemRepresentation, RENAME_EXCL) == 0) {
            naming.numbersByCameraStem[stem] = @(number);
            if (number >= naming.nextNumber) naming.nextNumber = number + 1;
            return name;
        }
        if (errno != EEXIST || number == UINT64_MAX) return nil;
        number = MAX(number + 1, naming.nextNumber);
    }
    return nil;
}
typedef BOOL (^S1HCaptureReadAt)(void *bytes, size_t size, uint64_t offset);

static BOOL s1h_capture_pread(int fd, void *buffer, size_t size, uint64_t offset) {
    unsigned char *bytes = buffer;
    while (size) {
        ssize_t count = pread(fd, bytes, size, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        size -= (size_t)count;
        offset += (uint64_t)count;
    }
    return YES;
}

/* Both observed DC-S1H layouts expose sensor/crop bounds and the RAW and
 * tail offsets in the first IFD. This verifies the container boundary,
 * not the contents of every compressed sensor block. */
static NSDictionary *s1h_capture_rw2_info(uint64_t size, S1HCaptureReadAt readAt) {
    enum { MaxEntries = 256, EntrySize = 12 };
    unsigned char header[8], countBytes[2], entries[MaxEntries * EntrySize];
    if (size < sizeof header || !readAt(header, sizeof header, 0) ||
        memcmp(header, "II\x55\x00", 4) != 0) return nil;
    uint32_t ifd = read32(header + 4);
    if (ifd < sizeof header || ifd > 4096 || (uint64_t)ifd + 2 > size ||
        !readAt(countBytes, sizeof countBytes, ifd)) return nil;
    uint16_t count = read16(countBytes);
    if (!count || count > MaxEntries) return nil;
    size_t length = (size_t)count * EntrySize;
    uint32_t ifdEnd = ifd + 2 + (uint32_t)length + 4;
    if (ifdEnd > size || !readAt(entries, length, ifd + 2)) return nil;

    enum { SensorWidth, SensorHeight, RawFormat, CropTop, CropLeft, CropBottom, CropRight,
        Model, PayloadBytes, PayloadOffset, ExtraBytes, TailOffset, FieldCount };
    static const struct { uint16_t tag, type; uint32_t count; } fields[FieldCount] = {
        [SensorWidth] = {0x0002, 3, 1}, [SensorHeight] = {0x0003, 3, 1},
        [RawFormat] = {0x002d, 3, 1}, [CropTop] = {0x002f, 3, 1}, [CropLeft] = {0x0030, 3, 1},
        [CropBottom] = {0x0031, 3, 1}, [CropRight] = {0x0032, 3, 1}, [Model] = {0x0110, 2, 7},
        [PayloadBytes] = {0x0117, 4, 1}, [PayloadOffset] = {0x0118, 4, 1},
        [ExtraBytes] = {0x0121, 4, 1}, [TailOffset] = {0x0122, 4, 1}
    };
    uint32_t values[FieldCount] = {0};
    uint32_t seen = 0;
    for (NSUInteger index = 0; index < count; ++index) {
        const unsigned char *entry = entries + index * EntrySize;
        for (NSUInteger field = 0; field < FieldCount; ++field) {
            if (read16(entry) != fields[field].tag) continue;
            uint32_t bit = 1U << field;
            uint16_t type = read16(entry + 2);
            if ((seen & bit) || type != fields[field].type || read32(entry + 4) != fields[field].count) return nil;
            seen |= bit;
            values[field] = type == 3 ? read16(entry + 8) : read32(entry + 8);
            break;
        }
    }
    if (seen != ((1U << FieldCount) - 1) || values[CropLeft] >= values[CropRight] ||
        values[CropTop] >= values[CropBottom] || values[CropRight] > values[SensorWidth] ||
        values[CropBottom] > values[SensorHeight] || !values[PayloadBytes] || values[PayloadOffset] < ifdEnd) return nil;
    if (!((values[RawFormat] == 6 && values[ExtraBytes] == 0) ||
          (values[RawFormat] == 7 && values[ExtraBytes] == 65536))) return nil;
    uint64_t rawEnd = (uint64_t)values[PayloadOffset] + values[PayloadBytes];
    if (rawEnd != values[TailOffset] || (uint64_t)values[TailOffset] + values[ExtraBytes] != size) return nil;
    unsigned char model[7];
    if (values[Model] < ifdEnd || (uint64_t)values[Model] + sizeof model > values[PayloadOffset] ||
        !readAt(model, sizeof model, values[Model]) || memcmp(model, "DC-S1H", sizeof model) != 0) return nil;
    return @{@"width": @(values[CropRight] - values[CropLeft]), @"height": @(values[CropBottom] - values[CropTop]),
             @"raw_format": @(values[RawFormat]), @"validation": @"rw2-structure"};
}

static NSUInteger jpeg_end(const unsigned char *bytes, NSUInteger count, NSUInteger start);

static NSDictionary *s1h_capture_jpeg_info(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (data.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8 ||
        jpeg_end(bytes, data.length, 0) != data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    CFStringRef type = CGImageSourceGetType(source);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    BOOL good = type && CFEqual(type, CFSTR("public.jpeg")) && width > 0 && height > 0 &&
        width <= 65535 && height <= 65535 && CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
    CFRelease(source);
    return good ? @{@"width": @(width), @"height": @(height), @"validation": @"jpeg-structure"} : nil;
}

static NSDictionary *s1h_capture_file_info(int fd, NSDictionary *info, uint32_t size) {
    if ([[info[@"name"] pathExtension].lowercaseString isEqualToString:@"rw2"])
        return s1h_capture_rw2_info(size, ^BOOL(void *bytes, size_t length, uint64_t offset) {
            return s1h_capture_pread(fd, bytes, length, offset);
        });
    if (size > 64U * 1024U * 1024U) return nil;
    NSMutableData *jpeg = [NSMutableData dataWithLength:size];
    return s1h_capture_pread(fd, jpeg.mutableBytes, size, 0) ? s1h_capture_jpeg_info(jpeg) : nil;
}

static PreviewReply *s1h_capture_read(NativePreviewTransport *transport, uint16_t opcode,
                                     NSArray<NSNumber *> *parameters, double deadline) {
    double remaining = deadline - monotonic_seconds();
    if (remaining <= 0.05 || StopRequested || !transport.synchronized) return nil;
    transport.transactionBudget = MIN(5.0, remaining);
    transport.error = nil;
    return [transport request:opcode parameters:parameters dataExpected:YES];
}

/* A matched DeviceBusy response leaves a safe transaction boundary. Waiting
 * for an object or retrying a read at that boundary does not repeat capture. */
static PreviewReply *s1h_capture_read_when_ready(NativePreviewTransport *transport, uint16_t opcode,
        NSArray<NSNumber *> *parameters, double deadline, BOOL allowPendingHandle) {
    PreviewReply *reply = nil;
    do {
        reply = s1h_capture_read(transport, opcode, parameters, deadline);
        if (!reply || (reply.code != S1H_PTP_DEVICE_BUSY &&
            !(allowPendingHandle && reply.code == S1H_PTP_INVALID_HANDLE))) break;
        usleep(100000);
    } while (!StopRequested && monotonic_seconds() < deadline);
    return reply;
}

static NSDictionary *s1h_capture_download(NativePreviewTransport *transport, uint32_t handle,
        NSDictionary *info, int directoryFD, NSString *directory, S1HCaptureNaming *naming, double deadline,
        NSUInteger fileIndex, S1HCaptureProgress progress, NSString **error) {
    uint32_t expected = [info[@"bytes"] unsignedIntValue];
    if (!s1h_capture_has_space(directoryFD, (uint64_t)expected + 1024 * 1024)) {
        if (error) *error = @"Insufficient space to save the captured photo. Check the camera and free space in the download folder.";
        return nil;
    }
    NSString *temporary = [NSString stringWithFormat:@".s1h-%@.part", NSUUID.UUID.UUIDString];
    int fd = openat(directoryFD, temporary.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { if (error) *error = @"Could not create a new photo download file."; return nil; }
    BOOL complete = YES;
    uint32_t offset = 0;
    BOOL extended = [info[@"extended_object"] boolValue];
    if (progress) progress(s1h_capture_file_progress(fileIndex, offset, expected, NO));
    double started = monotonic_seconds();
    double lastProgress = started;
    NSString *chunkError = nil;
    while (offset < expected && !StopRequested) {
        /* Release the PTP buffers after each chunk, including during XL transfers. */
        @autoreleasepool {
            uint32_t count = MIN(S1H_CAPTURE_CHUNK, expected - offset);
            NSArray *arguments = extended ? @[@(handle), @(offset), @0, @(count)] : @[@(handle), @(offset), @(count)];
            PreviewReply *reply = s1h_capture_read_when_ready(transport, extended ? 0x9112 : 0x101b, arguments,
                                                            MIN(deadline, monotonic_seconds() + 8.0), NO);
            BOOL countConfirmed = reply.parameters.count == 1 && reply.parameters.firstObject.unsignedIntValue == count;
            if (extended && !reply.parameters.count) countConfirmed = YES;
            if (!reply || reply.code != S1H_PTP_OK || reply.data.length != count ||
                !countConfirmed) {
                complete = NO;
                chunkError = transport.error ?: @"Photo chunk did not arrive with the requested byte count before its deadline; .part retained.";
                break;
            }
            if (!s1h_capture_write_all(fd, reply.data)) {
                complete = NO;
                chunkError = @"Photo file write failed; incomplete .part file retained.";
                break;
            }
            offset += count;
            double now = monotonic_seconds();
            if (progress && (offset == expected || now - lastProgress >= 0.25)) {
                lastProgress = now;
                progress(s1h_capture_file_progress(fileIndex, offset, expected, NO));
            }
        }
    }
    if (chunkError && error) *error = chunkError;
    if (complete && !StopRequested && progress) progress(s1h_capture_file_progress(fileIndex, offset, expected, YES));
    if (StopRequested) complete = NO;
    struct stat written;
    NSDictionary *fileInfo = nil;
    if (complete) {
        phase_deadline(8);
        if (fstat(fd, &written) == 0 && (uint64_t)written.st_size == expected)
            fileInfo = s1h_capture_file_info(fd, info, expected);
        if (!fileInfo || fsync(fd) != 0) {
            complete = NO;
            if (error) *error = @"Downloaded photo did not pass its length, structure or flush check; .part file retained.";
        }
    }
    close(fd);
    if (StopRequested) {
        if (error) *error = @"Photo download cancelled. The .part file was retained.";
        return nil;
    }
    if (!complete) return nil;
    NSString *final = s1h_capture_finalize_named(directoryFD, temporary, info[@"name"], naming);
    if (!final) { if (error) *error = @"Could not finalize the new photo without overwriting an existing file; .part retained."; return nil; }
    NSMutableDictionary *saved = [info mutableCopy];
    [saved addEntriesFromDictionary:fileInfo];
    saved[@"name"] = final; saved[@"path"] = [directory stringByAppendingPathComponent:final];
    saved[@"object_handle"] = @(handle);
    saved[@"download_seconds"] = @(MAX(0, monotonic_seconds() - started));
    if (fsync(directoryFD) != 0 && error)
        *error = @"Photo was saved, but the folder flush failed. Check the download folder before taking another photo.";
    return saved;
}

static NSArray *s1h_capture_read_handles(NativePreviewTransport *transport, double deadline,
                                         BOOL *unsupported, NSString **error) {
    if (error) *error = nil;
    if (unsupported) *unsupported = NO;
    PreviewReply *reply = s1h_capture_read(transport, 0x1007, @[@(UINT32_MAX), @0, @0], deadline);
    if (reply && reply.code == S1H_PTP_DEVICE_BUSY) return nil;
    if (unsupported && reply && (reply.code == S1H_PTP_INVALID_PARAMETER || reply.code == S1H_PTP_UNSUPPORTED)) {
        *unsupported = YES;
        return nil;
    }
    NSArray *handles = reply && reply.code == S1H_PTP_OK ? s1h_capture_handles(reply.data) : nil;
    if (!handles && error) *error = transport.error ?: @"Camera object inventory did not return a valid handle list.";
    return handles;
}

static NSNumber *s1h_capture_event_handle(NSDictionary *event, uint32_t captureTransaction, BOOL eventOnly) {
    uint32_t code = [event[@"code"] unsignedIntValue];
    NSNumber *transaction = event[@"transaction"];
    if (!transaction || (code != 0xc108 && code != 0xc109 && code != 0x4002)) return nil;
    /* USB PTP events may omit a transaction association. Complete events
     * explicitly tied to a different capture may not select its object. */
    uint32_t tx = transaction.unsignedIntValue;
    if (tx != captureTransaction && tx != 0 && tx != UINT32_MAX) return nil;
    if (eventOnly && code == 0x4002 && tx != captureTransaction) return nil;
    NSNumber *handle = [event[@"parameters"] firstObject];
    return handle.unsignedIntValue != 0 && handle.unsignedIntValue != UINT32_MAX ? handle : nil;
}

static BOOL s1h_capture_event_uint32(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= UINT32_MAX && floor(number) == number;
}

static BOOL s1h_camera_event_starts_transfer(NSDictionary *event) {
    if (![event isKindOfClass:NSDictionary.class] || !s1h_capture_event_uint32(event[@"code"]) ||
        !s1h_capture_event_uint32(event[@"transaction"])) return NO;
    uint32_t code = [event[@"code"] unsignedIntValue];
    if (code != 0xc108 && code != 0xc109) return NO;
    NSArray *parameters = event[@"parameters"];
    if (![parameters isKindOfClass:NSArray.class] || parameters.count != 1 ||
        !s1h_capture_event_uint32(parameters.firstObject)) return NO;
    return s1h_capture_event_handle(event, [event[@"transaction"] unsignedIntValue], YES) != nil;
}

static NSNumber *s1h_capture_event_detail(NSDictionary *event, uint32_t captureTransaction) {
    if ([event[@"code"] unsignedIntValue] != 0xc101 || !event[@"transaction"]) return nil;
    uint32_t tx = [event[@"transaction"] unsignedIntValue];
    if (tx != captureTransaction && tx != 0 && tx != UINT32_MAX) return nil;
    return [event[@"parameters"] firstObject];
}

static BOOL s1h_capture_volatile_object_released(uint16_t response, BOOL extended, BOOL volatileObject) {
    /* After a verified PC-only download, the S1H can discard the temporary
     * handle and return InvalidParameter to the same extended info request. */
    return volatileObject && (response == S1H_PTP_INVALID_HANDLE ||
                              (extended && response == S1H_PTP_INVALID_PARAMETER));
}

static BOOL s1h_capture_queue_handles(NSArray<NSNumber *> *handles, NSMutableSet<NSNumber *> *seen,
                                      NSMutableArray<NSNumber *> *pending, NSUInteger baselineCount) {
    for (NSNumber *handle in handles) {
        if ([seen containsObject:handle]) continue;
        if (seen.count - baselineCount >= S1H_CAPTURE_MAX_FILES) return NO;
        [seen addObject:handle];
        [pending addObject:handle];
    }
    return YES;
}

static NSDictionary *s1h_capture_receive(NativePreviewTransport *transport, int directoryFD, NSString *directory,
        NSArray<NSNumber *> *before, BOOL eventOnly, uint32_t captureTransaction, NSDictionary *firstEvent,
        S1HCaptureNaming *naming, S1HCaptureProgress progress) {
    NSMutableArray *files = [NSMutableArray array];
    NSString *error = nil;
    BOOL hostShutter = firstEvent == nil;
    /* Handles are deduplicated for one receive group. The S1H can allocate
     * the same SDRAM handle to a later photograph. */
    NSMutableSet<NSNumber *> *seen = [NSMutableSet setWithArray:before ?: @[]];
    if (progress) progress(s1h_capture_busy(@"waiting", hostShutter ? @"Waiting for the camera to finish the capture." :
        @"Receiving a photograph taken on the camera."));
    double started = monotonic_seconds();
    double objectDeadline = started + 120.0, deadline = started + 240.0;
    double quietDeadline = 0, nextInventory = started + 0.75;
    NSMutableArray<NSNumber *> *pending = [NSMutableArray array];
    NSMutableSet<NSNumber *> *volatileHandles = [NSMutableSet set];
    NSNumber *savedHandle = nil;
    NSDictionary *savedObjectInfo = nil;
    BOOL complete = NO;
    NSUInteger eventDetailReads = 0;
    while (!StopRequested && monotonic_seconds() < deadline) {
        if (!files.count && !pending.count && monotonic_seconds() >= objectDeadline) break;
        if (pending.count == 0) {
            NSDictionary *event = firstEvent ?: [transport readCaptureEvent:0.15 error:&error];
            firstEvent = nil;
            if (error) break;
            if (event) printf("Capture event code=0x%04x tx=%u\n", [event[@"code"] unsignedIntValue],
                              [event[@"transaction"] unsignedIntValue]);
            if (transport.verbose && event) {
                printf("Capture event parameter_count=%lu first=0x%08x\n", (unsigned long)[event[@"parameters"] count],
                    [[event[@"parameters"] firstObject] unsignedIntValue]);
            }
            NSNumber *eventDetail = s1h_capture_event_detail(event, captureTransaction);
            if (eventDetail && eventDetailReads < 24) {
                ++eventDetailReads;
                /* Panasonic's capture event-detail exchange uses the first
                 * C101 argument, as observed in the upstream PTP client. */
                s1h_capture_read(transport, 0x9401, @[eventDetail], deadline);
                if (!transport.synchronized) {
                    error = transport.error ?: @"The camera's capture event detail could not be read.";
                    break;
                }
            }
            NSNumber *handle = hostShutter || s1h_camera_event_starts_transfer(event) ?
                s1h_capture_event_handle(event, captureTransaction, eventOnly) : nil;
            if (handle && !s1h_capture_queue_handles(@[handle], seen, pending, before.count)) {
                error = @"Capture has too many new objects; only verified saved files are reported.";
                break;
            }
            if (handle && [event[@"code"] unsignedIntValue] == 0xc109)
                [volatileHandles addObject:handle];
            double now = monotonic_seconds();
            if (pending.count == 0 && eventOnly && !event && savedHandle && now >= quietDeadline && now >= nextInventory) {
                /* The event path has no pre-capture inventory. Confirm
                 * that a read against the exact verified object
                 * can complete after transfer. A volatile SDRAM object may
                 * expire after being consumed; its matched InvalidHandle
                 * also leaves a synchronized read boundary. */
                BOOL extended = [savedObjectInfo[@"extended_object"] boolValue];
                PreviewReply *check = s1h_capture_read(transport, extended ? 0x9110 : 0x1008, @[savedHandle], deadline);
                if (check && check.code == S1H_PTP_DEVICE_BUSY) {
                    nextInventory = monotonic_seconds() + 0.75;
                    continue;
                }
                NSDictionary *observed = check.code == S1H_PTP_OK ?
                    (extended ? s1h_capture_extended_object_info(check.data) : s1h_capture_object_info(check.data)) : nil;
                complete = ([observed[@"name"] isEqual:savedObjectInfo[@"name"]] &&
                            [observed[@"bytes"] isEqual:savedObjectInfo[@"bytes"]]) ||
                    (check && s1h_capture_volatile_object_released(check.code, extended,
                                                                  [volatileHandles containsObject:savedHandle]));
                if (!complete) error = transport.error ?: @"Photo was saved, but the camera did not confirm the captured object's final state.";
                break;
            }
            if (pending.count == 0 && !eventOnly && now >= nextInventory) {
                /* Read-only fallback also catches a companion RAW/JPEG when
                 * a camera omits its event. An OK inventory after the quiet
                 * period is required; DeviceBusy cannot count as completion. */
                NSArray *after = s1h_capture_read_handles(transport, deadline, NULL, &error);
                if (error) break;
                if (!s1h_capture_queue_handles(after, seen, pending, before.count)) {
                    error = @"Capture has too many new objects; only verified saved files are reported.";
                    break;
                }
                now = monotonic_seconds();
                if (after && !event && files.count && pending.count == 0 && now >= quietDeadline) {
                    complete = YES;
                    break;
                }
                nextInventory = now + 0.75;
            }
        }
        while (pending.count && !StopRequested) {
            NSNumber *handle = pending.firstObject;
            [pending removeObjectAtIndex:0];
            double metadataDeadline = MIN(deadline, monotonic_seconds() + 12.0);
            BOOL extended = [volatileHandles containsObject:handle];
            PreviewReply *reply = s1h_capture_read_when_ready(transport, extended ? 0x9110 : 0x1008, @[handle], metadataDeadline, YES);
            if (extended && (reply.code == S1H_PTP_UNSUPPORTED || reply.code == S1H_PTP_INVALID_PARAMETER)) {
                extended = NO;
                reply = s1h_capture_read_when_ready(transport, 0x1008, @[handle], metadataDeadline, YES);
            }
            NSDictionary *info = reply.code == S1H_PTP_OK ?
                (extended ? s1h_capture_extended_object_info(reply.data) : s1h_capture_object_info(reply.data)) : nil;
            if (!info) {
                error = transport.error ?: @"New captured object did not provide supported photo metadata before its deadline.";
                break;
            }
            if (![info[@"association"] boolValue]) {
                NSDictionary *saved = s1h_capture_download(transport, handle.unsignedIntValue, info, directoryFD,
                                                          directory, naming, deadline, files.count + 1, progress, &error);
                if (saved) [files addObject:saved];
                if (!saved || error) break;
                savedHandle = handle;
                savedObjectInfo = info;
            }
            quietDeadline = monotonic_seconds() + 2.0;
        }
        if (error) break;
    }
    if (StopRequested) return s1h_capture_result(@"error", @"Capture/download cancelled. Check the camera and download folder before taking another photo.", hostShutter, files);
    if (error) return s1h_capture_result(@"error", error, hostShutter, files);
    if (!files.count) return s1h_capture_result(@"outcome_unknown", @"No new photo object arrived before the capture deadline. A photo may exist on the camera; no retry was made.", hostShutter, files);
    if (!complete) return s1h_capture_result(@"outcome_unknown",
        @"Photo files were saved, but the camera session did not settle. Check the camera before another capture.", hostShutter, files);
    return s1h_capture_result(@"ok", [NSString stringWithFormat:@"Saved %lu photo file(s) to the Mac.", (unsigned long)files.count], hostShutter, files);
}

static NSDictionary *s1h_capture_once(NativePreviewTransport *transport, NSString *requestedDirectory,
        NSString *prefix, S1HCaptureProgress progress) {
    NSString *error = nil, *directory = nil;
    if (!transport.synchronized) return s1h_capture_result(@"rejected", @"Camera session is not synchronized; no photo was requested.", NO, @[]);
    phase_deadline(8);
    int directoryFD = s1h_capture_directory(requestedDirectory, &directory, &error);
    if (directoryFD < 0) return s1h_capture_result(@"rejected", error, NO, @[]);
    S1HCaptureNaming *naming = s1h_capture_prepare_naming(directoryFD, prefix);
    if (prefix.length && !naming) {
        close(directoryFD);
        return s1h_capture_result(@"rejected", @"Could not start photo numbering in the destination. No photo requested.", NO, @[]);
    }
    double previousBudget = transport.transactionBudget;
    if (progress) progress(s1h_capture_busy(@"preparing", @"Checking the camera before capture."));
    /* A body shutter can arrive after the preview loop's last event poll.
     * Receive it before allowing another shutter, especially for PC-only RAW. */
    BOOL drained = NO;
    for (unsigned i = 0; i < 64 && !StopRequested; ++i) {
        NSDictionary *event = [transport readCaptureEvent:0.05 error:&error];
        if (!event) { drained = error == nil; break; }
        if (s1h_camera_event_starts_transfer(event)) {
            NSDictionary *result = s1h_capture_receive(transport, directoryFD, directory, nil, YES,
                [event[@"transaction"] unsignedIntValue], event, naming, progress);
            close(directoryFD); transport.transactionBudget = previousBudget;
            return result;
        }
    }
    if (!drained || StopRequested) {
        close(directoryFD); transport.transactionBudget = previousBudget;
        return s1h_capture_result(@"rejected", error ?: @"Could not clear old capture events; no photograph requested.", NO, @[]);
    }
    BOOL eventOnly = NO;
    NSArray *before = s1h_capture_read_handles(transport, monotonic_seconds() + 5.0, &eventOnly, &error);
    if ((!before && !eventOnly) || StopRequested) {
        close(directoryFD); transport.transactionBudget = previousBudget;
        NSString *message = StopRequested ? @"Cancelled before requesting a photograph." :
            error ?: @"The camera is busy; no photograph was requested.";
        return s1h_capture_result(@"rejected", message, NO, @[]);
    }
    if (progress) progress(s1h_capture_busy(@"shutter", @"Taking one photograph."));
    if (StopRequested) {
        close(directoryFD); transport.transactionBudget = previousBudget;
        return s1h_capture_result(@"rejected", @"Cancelled before requesting a photograph.", NO, @[]);
    }
    uint32_t captureTransaction = transport.nextTransaction;
    double previousResponseTimeout = transport.responseTimeout;
    transport.transactionBudget = 9.0;
    transport.responseTimeout = 8.0;
    PreviewReply *capture = [transport request:0x9404 parameters:@[@0x03000011] dataExpected:NO];
    transport.responseTimeout = previousResponseTimeout;
    NSDictionary *result;
    if (capture && capture.code == S1H_PTP_OK) {
        result = s1h_capture_receive(transport, directoryFD, directory, before, eventOnly, captureTransaction, nil, naming, progress);
    } else if (capture && capture.code == S1H_PTP_STORE_NOT_AVAILABLE) {
        result = s1h_capture_result(@"rejected", @"The camera reported its photo storage is unavailable (0x2013). Check the camera's capture destination and storage card.", YES, @[]);
    } else if (capture && (capture.code == S1H_PTP_DEVICE_BUSY || capture.code == S1H_PTP_UNSUPPORTED)) {
        NSString *message = [NSString stringWithFormat:@"The camera declined the shutter request (0x%04x).", capture.code];
        result = s1h_capture_result(@"rejected", message, YES, @[]);
    } else {
        NSString *message = capture ? [NSString stringWithFormat:@"Capture returned 0x%04x; no automatic retry will be made.", capture.code] :
            @"Capture response was lost; a photograph may exist on the camera. No automatic retry will be made.";
        result = s1h_capture_result(@"outcome_unknown", message, YES, @[]);
    }
    close(directoryFD); transport.transactionBudget = previousBudget;
    return result;
}

static NSDictionary *s1h_capture_from_camera_event(NativePreviewTransport *transport, NSString *requestedDirectory,
        NSString *prefix, NSDictionary *event, S1HCaptureProgress progress) {
    if (!s1h_camera_event_starts_transfer(event))
        return s1h_capture_result(@"rejected", @"The event did not identify a captured photo.", NO, @[]);
    if (!transport.synchronized || StopRequested)
        return s1h_capture_result(@"outcome_unknown", @"The camera reported a photo while the session was unavailable. Check the camera before reconnecting.", NO, @[]);
    NSString *directory = nil, *error = nil;
    phase_deadline(8);
    int directoryFD = s1h_capture_directory(requestedDirectory, &directory, &error);
    if (directoryFD < 0) return s1h_capture_result(@"error", error, NO, @[]);
    S1HCaptureNaming *naming = s1h_capture_prepare_naming(directoryFD, prefix);
    if (prefix.length && !naming) {
        close(directoryFD);
        return s1h_capture_result(@"error", @"Could not start photo numbering in the destination. Check the camera and save folder.", NO, @[]);
    }
    double previousBudget = transport.transactionBudget;
    NSDictionary *result = s1h_capture_receive(transport, directoryFD, directory, nil, YES,
        [event[@"transaction"] unsignedIntValue], event, naming, progress);
    close(directoryFD); transport.transactionBudget = previousBudget;
    return result;
}

@interface S1HCaptureEventFixtureTransport : NativePreviewTransport
@property(nonatomic, strong) NSMutableArray<NSArray *> *fixtureRequests;
@property(nonatomic) NSUInteger fixtureEventReads;
@end

@implementation S1HCaptureEventFixtureTransport
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters dataExpected:(BOOL)expected {
    [self.fixtureRequests addObject:@[@(opcode), parameters, @(expected)]];
    PreviewReply *reply = [PreviewReply new];
    reply.code = 0x2002;
    return reply;
}
- (NSDictionary *)readCaptureEvent:(NSTimeInterval)timeout error:(NSString **)error {
    (void)timeout;
    ++self.fixtureEventReads;
    if (error) *error = @"Unexpected interrupt read before consuming the first event.";
    return nil;
}
@end

/* Pure packet/path checks: no device, filesystem creation, or shutter. */
static BOOL s1h_capture_self_test(void) {
    unsigned checks = 0, failures = 0;
#define CAPTURE_CHECK(condition, label) do { ++checks; if (!(condition)) { ++failures; fprintf(stderr, "FAIL capture: %s\n", label); } } while (0)
    unsigned char handleBytes[12] = {0}; write32(handleBytes, 2); write32(handleBytes + 4, 1); write32(handleBytes + 8, 2);
    NSData *handles = [NSData dataWithBytes:handleBytes length:sizeof handleBytes];
    CAPTURE_CHECK(([s1h_capture_handles(handles) isEqual:@[@1, @2]]), "Object handles parse a complete bounded dataset");
    CAPTURE_CHECK(s1h_capture_handles([handles subdataWithRange:NSMakeRange(0, 11)]) == nil, "Truncated handle dataset is rejected");
    write32(handleBytes + 8, 1);
    CAPTURE_CHECK(s1h_capture_handles([NSData dataWithBytes:handleBytes length:sizeof handleBytes]) == nil, "Duplicate handles cannot disguise the pre-capture set");
    write32(handleBytes, UINT32_MAX);
    CAPTURE_CHECK(s1h_capture_handles([NSData dataWithBytes:handleBytes length:sizeof handleBytes]) == nil, "Excessive handle count is rejected before allocation");
    CAPTURE_CHECK(s1h_capture_name_valid(@"_1234567.RW2") && s1h_capture_name_valid(@"photo.jpg"), "RAW and JPEG filenames are accepted");
    CAPTURE_CHECK(!s1h_capture_name_valid(@"../photo.RW2") && !s1h_capture_name_valid(@"folder/photo.RW2") &&
                  !s1h_capture_name_valid(@"photo:1.RW2") && !s1h_capture_name_valid(@"photo\n.RW2") &&
                  !s1h_capture_name_valid(@"video.MOV"), "Path traversal, control characters and unsupported media are rejected");
    CAPTURE_CHECK(s1h_photo_prefix_valid(@"") && s1h_photo_prefix_valid(@"底片 2026") && s1h_photo_prefix_valid(@"Series_1") &&
                  !s1h_photo_prefix_valid(@"../escape") && !s1h_photo_prefix_valid(@"My:Photo") &&
                  !s1h_photo_prefix_valid(@"My\\Photo") && !s1h_photo_prefix_valid(@"My\nPhoto") &&
                  !s1h_photo_prefix_valid(@"My\u2028Photo") && !s1h_photo_prefix_valid(@"My\u2029Photo") &&
                  !s1h_photo_prefix_valid(@"Leading. ") && !s1h_photo_prefix_valid(@".hidden") &&
                  !s1h_photo_prefix_valid([@"" stringByPaddingToLength:121 withString:@"X" startingAtIndex:0]),
                  "Optional user prefix accepts Unicode and rejects unsafe or oversized names");
    CAPTURE_CHECK(s1h_capture_named_ordinal(@"Film_A_0012.RW2", @"film_a") == 12 &&
                  s1h_capture_named_ordinal(@"底片_10000.jpeg", @"底片") == 10000 &&
                  s1h_capture_named_ordinal(@"Cafe\u0301_0002.JPG", @"Café") == 2 &&
                  s1h_capture_named_ordinal(@"Film_A_0013.MOV", @"film_a") == 0 &&
                  s1h_capture_named_ordinal(@"Film_A_001x.JPG", @"film_a") == 0 &&
                  s1h_capture_named_ordinal(@"Other_Film_A_0012.RW2", @"film_a") == 0 &&
                  s1h_capture_named_ordinal(@"Film_A_18446744073709551616.JPG", @"film_a") == 0,
                  "Numbering scans matching RAW and JPEG names with exact prefixes, case folding and overflow checks");
    NSMutableData *info = [NSMutableData dataWithLength:52];
    unsigned char *bytes = info.mutableBytes;
    write32(bytes, 0x10001); write16(bytes + 4, 0xb103); write32(bytes + 8, 36093440);
    write32(bytes + 26, 6000); write32(bytes + 30, 4000);
    NSString *filename = @"_1234567.RW2";
    uint8_t count = (uint8_t)filename.length + 1;
    [info appendBytes:&count length:1]; [info appendData:[filename dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    uint16_t zero = 0; [info appendBytes:&zero length:2];
    NSDictionary *parsed = s1h_capture_object_info(info);
    CAPTURE_CHECK([parsed[@"bytes"] unsignedIntValue] == 36093440 && [parsed[@"width"] unsignedIntValue] == 6000 &&
                  [parsed[@"height"] unsignedIntValue] == 4000 && [parsed[@"name"] isEqual:filename], "Object info retains exact full-photo size and dimensions");
    CAPTURE_CHECK(s1h_capture_object_info([info subdataWithRange:NSMakeRange(0, info.length - 1)]) == nil, "Incomplete UTF-16 filename is rejected");
    NSMutableData *extended = [NSMutableData dataWithLength:60];
    unsigned char *ex = extended.mutableBytes;
    write16(ex + 8, 0xb103);
    write32(ex + 12, 162000000);
    write32(ex + 34, 12000);
    write32(ex + 38, 8000);
    [extended appendData:[info subdataWithRange:NSMakeRange(52, info.length - 52)]];
    NSDictionary *extendedInfo = s1h_capture_extended_object_info(extended);
    CAPTURE_CHECK([extendedInfo[@"bytes"] unsignedLongLongValue] == 162000000 &&
        [extendedInfo[@"width"] unsignedIntValue] == 12000 && [extendedInfo[@"height"] unsignedIntValue] == 8000 &&
        [extendedInfo[@"name"] isEqual:filename], "Extended metadata keeps the 64-bit length and XL dimensions");
    write32((unsigned char *)extended.mutableBytes + 16, 1);
    CAPTURE_CHECK(!s1h_capture_extended_object_info(extended), "Extended oversized object cannot bypass the download bound");
    bytes = info.mutableBytes; write32(bytes + 8, UINT32_MAX);
    CAPTURE_CHECK(s1h_capture_object_info(info) == nil, "Unsupported object length is rejected");
    write16(bytes + 4, 0x3001);
    CAPTURE_CHECK([s1h_capture_object_info(info)[@"association"] boolValue], "Directory objects are separated from photographs");
    NSNumber *handle = s1h_capture_event_handle(@{@"code":@0xc109, @"transaction":@4, @"parameters":@[@8]}, 4, YES);
    CAPTURE_CHECK([handle isEqual:@8], "A matching SDRAM capture event selects its photo handle");
    CAPTURE_CHECK(s1h_capture_volatile_object_released(S1H_PTP_INVALID_PARAMETER, YES, YES) &&
        !s1h_capture_volatile_object_released(S1H_PTP_INVALID_PARAMETER, NO, YES) &&
        !s1h_capture_volatile_object_released(S1H_PTP_INVALID_PARAMETER, YES, NO) &&
        !s1h_capture_volatile_object_released(S1H_PTP_DEVICE_BUSY, YES, YES),
        "Only the confirmed transient extended object may expire with InvalidParameter after transfer");
    CAPTURE_CHECK([s1h_capture_event_detail(@{@"code":@0xc101, @"transaction":@(UINT32_MAX), @"parameters":@[@0x01000011]}, 4) isEqual:@0x01000011] &&
        !s1h_capture_event_detail(@{@"code":@0xc104, @"transaction":@(UINT32_MAX), @"parameters":@[@0x08000011]}, 4),
        "Only the observed detail event selects the fixed event-detail read");
    CAPTURE_CHECK(!s1h_capture_event_handle(@{@"code":@0xc109, @"transaction":@3, @"parameters":@[@8]}, 4, YES) &&
        !s1h_capture_event_handle(@{@"code":@0xc101, @"transaction":@4, @"parameters":@[@8]}, 4, YES),
        "Events from another capture and unrelated vendor events never select a photo");
    CAPTURE_CHECK(!s1h_capture_event_handle(@{@"code":@0x4002, @"transaction":@0, @"parameters":@[@8]}, 4, YES) &&
        s1h_capture_event_handle(@{@"code":@0xc108, @"transaction":@0, @"parameters":@[@8]}, 4, YES),
        "With no inventory, a transactionless vendor capture event can select a photo but a generic unmatched event cannot");
    CAPTURE_CHECK(s1h_camera_event_starts_transfer(@{@"code":@0xc108, @"transaction":@0, @"parameters":@[@8]}) &&
        s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@(UINT32_MAX), @"parameters":@[@0x12345678]}),
        "Camera-initiated transfer accepts the Panasonic card and observed SDRAM object events");
    CAPTURE_CHECK(!s1h_camera_event_starts_transfer(@{@"code":@0x4002, @"transaction":@0, @"parameters":@[@8]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc101, @"transaction":@0, @"parameters":@[@8]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"parameters":@[@8]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@0, @"parameters":@[@0]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@0, @"parameters":@[@(UINT32_MAX)]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@0, @"parameters":@[@(UINT32_MAX + 9ULL)]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@0, @"parameters":@[@"8"]}) &&
        !s1h_camera_event_starts_transfer(@{@"code":@0xc109, @"transaction":@0, @"parameters":@[@8, @9]}),
        "Generic, detail and malformed interrupt events cannot start an unsolicited download");
    S1HCaptureEventFixtureTransport *eventTransport = [S1HCaptureEventFixtureTransport new];
    eventTransport.synchronized = YES;
    eventTransport.fixtureRequests = [NSMutableArray array];
    NSDictionary *eventResult = s1h_capture_receive(eventTransport, -1, @"", nil, YES, UINT32_MAX,
        @{@"code":@0xc109, @"transaction":@(UINT32_MAX), @"parameters":@[@0x12345678]}, nil, nil);
    CAPTURE_CHECK((eventTransport.fixtureEventReads == 0 &&
        [eventTransport.fixtureRequests isEqual:@[@[@0x9110, @[@0x12345678], @YES]]] &&
        [eventResult[@"status"] isEqual:@"error"] && ![eventResult[@"capture_issued"] boolValue] &&
        ![eventResult[@"safe_to_resume"] boolValue] && [eventResult[@"files"] count] == 0),
        "An already-read SDRAM event requests exact metadata, issues no shutter, and holds on transfer failure");
    NSMutableSet *seen = [NSMutableSet setWithArray:@[@1, @2]];
    NSMutableArray *pending = [NSMutableArray array];
    CAPTURE_CHECK((s1h_capture_queue_handles(@[@2, @8, @8], seen, pending, 2) && [pending isEqual:@[@8]]),
        "Inventory and event duplicates never enqueue old or already queued objects");
    NSMutableArray *nextGroup = [NSMutableArray array];
    CAPTURE_CHECK((s1h_capture_queue_handles(@[@8, @8], [NSMutableSet set], nextGroup, 0) && [nextGroup isEqual:@[@8]]),
        "A later receive group can use the same volatile handle once");
    NSMutableArray *overflow = [NSMutableArray array];
    for (uint32_t i = 100; i <= 100 + S1H_CAPTURE_MAX_FILES; ++i) [overflow addObject:@(i)];
    CAPTURE_CHECK(!s1h_capture_queue_handles(overflow, seen, pending, 2) && pending.count == S1H_CAPTURE_MAX_FILES,
        "New object inventory is bounded before metadata or download I/O");

    /* Small IFD fixtures represent large declared payloads without allocating
     * an image or writing a file. Their crop values match both observed layouts. */
    NSMutableData *rw2 = [NSMutableData dataWithLength:256];
    S1HCaptureReadAt readFixture = ^BOOL(void *output, size_t length, uint64_t offset) {
        if (offset > rw2.length || length > rw2.length - offset) return NO;
        memcpy(output, (const unsigned char *)rw2.bytes + offset, length);
        return YES;
    };
    unsigned char *raw = rw2.mutableBytes;
    memcpy(raw, "II\x55\x00", 4);
    write32(raw + 4, 24);
    write16(raw + 24, 12);
    const uint16_t tags[] = {0x0002, 0x0003, 0x002d, 0x002f, 0x0030, 0x0031, 0x0032, 0x0110,
                            0x0117, 0x0118, 0x0121, 0x0122};
    uint32_t values[] = {6072, 4016, 6, 8, 12, 4008, 6012, 192, 35469312, 256, 0, 35469568};
    memcpy(raw + 192, "DC-S1H", 7);
    for (NSUInteger i = 0; i < sizeof tags / sizeof tags[0]; ++i) {
        unsigned char *entry = raw + 26 + i * 12;
        write16(entry, tags[i]);
        write16(entry + 2, i < 7 ? 3 : i == 7 ? 2 : 4);
        write32(entry + 4, i == 7 ? 7 : 1);
        write32(entry + 8, values[i]);
    }
    NSDictionary *normalRAW = s1h_capture_rw2_info(values[11], readFixture);
    CAPTURE_CHECK([normalRAW[@"width"] isEqual:@6000] && [normalRAW[@"height"] isEqual:@4000] &&
        [normalRAW[@"raw_format"] isEqual:@6], "Ordinary RW2 C6 validates crop, model and full RAW boundary");
    CAPTURE_CHECK(!s1h_capture_rw2_info(values[11] - 1, readFixture), "A size matching only a truncated C6 object is rejected");
    values[0] = 12096; values[1] = 8018; values[2] = 7; values[4] = 16; values[5] = 8008; values[6] = 12016;
    values[8] = 172419072; values[10] = 65536; values[11] = values[8] + values[9];
    for (NSUInteger i = 0; i < sizeof tags / sizeof tags[0]; ++i) write32(raw + 26 + i * 12 + 8, values[i]);
    NSDictionary *xlRAW = s1h_capture_rw2_info((uint64_t)values[11] + values[10], readFixture);
    CAPTURE_CHECK([xlRAW[@"width"] isEqual:@12000] && [xlRAW[@"height"] isEqual:@8000] && [xlRAW[@"raw_format"] isEqual:@7],
        "XL RW2 C7 reports 12000 × 8000 only with a full RAW payload and tail");
    CAPTURE_CHECK(!s1h_capture_rw2_info(values[11], readFixture), "A C7 file missing the multishot tail is rejected");
    raw[192] = 'X';
    CAPTURE_CHECK(!s1h_capture_rw2_info((uint64_t)values[11] + values[10], readFixture), "RW2 metadata for another camera is rejected");

    NSDictionary *unknown = s1h_capture_result(@"outcome_unknown", @"test", YES, @[]);
    CAPTURE_CHECK(![unknown[@"safe_to_resume"] boolValue] && ![unknown[@"capture_complete"] boolValue], "Unknown shutter result cannot imply completion or safe resume");
    NSDictionary *refused = s1h_capture_result(@"rejected", @"test", YES, @[]);
    CAPTURE_CHECK([refused[@"safe_to_resume"] boolValue] && ![refused[@"capture_complete"] boolValue],
        "Explicit matched shutter refusal can be followed by preview without implying a saved photograph");
    NSDictionary *ok = s1h_capture_result(@"ok", @"test", YES, @[@{}]);
    CAPTURE_CHECK([ok[@"safe_to_resume"] boolValue] && [ok[@"capture_complete"] boolValue] && ![ok[@"camera_delete_called"] boolValue], "Only completed capture advertises completion without camera deletion");
    CAPTURE_CHECK(![s1h_capture_result(@"ok", @"test", YES, @[])[@"capture_complete"] boolValue], "An empty result cannot advertise capture completion");
    printf("Capture packet self-test: %u checks, %u failures; no hardware or filesystem output.\n", checks, failures);
#undef CAPTURE_CHECK
    return failures == 0;
}
