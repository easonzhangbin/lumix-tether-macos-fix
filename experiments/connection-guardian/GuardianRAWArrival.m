#import "GuardianRAWArrival.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger MaximumDirectoryEntries = 8192;
static const uint32_t S1HRawPayloadSize = 172419072;
static const uint32_t S1HRawTailSize = 65536;
enum { MaximumIFDEntries = 256, IFDEntrySize = 12 };

@interface GuardianRAWArrivalResult ()
- (instancetype)initWithRelativePath:(NSString *)relativePath fileSize:(uint64_t)fileSize;
@end

@implementation GuardianRAWArrivalResult
- (instancetype)initWithRelativePath:(NSString *)relativePath fileSize:(uint64_t)fileSize {
    if ((self = [super init])) {
        _relativePath = [relativePath copy];
        _fileSize = fileSize;
    }
    return self;
}
@end

/* A stable size and nanosecond timestamps distinguish a changed file from
 * a file already present at arm time and from one being written during read. */
static NSData *FileStamp(const struct stat *status) {
    uint64_t stamp[] = {
        (uint64_t)status->st_dev, status->st_ino, (uint64_t)status->st_size,
        (uint64_t)status->st_mtimespec.tv_sec, (uint64_t)status->st_mtimespec.tv_nsec,
        (uint64_t)status->st_ctimespec.tv_sec, (uint64_t)status->st_ctimespec.tv_nsec
    };
    return [NSData dataWithBytes:stamp length:sizeof stamp];
}

static uint16_t ReadLE16(const uint8_t *data) {
    return (uint16_t)(data[0] | ((uint16_t)data[1] << 8));
}

static uint32_t ReadLE32(const uint8_t *data) {
    return (uint32_t)data[0] | ((uint32_t)data[1] << 8) |
        ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

static BOOL ReadExactly(int file, uint8_t *bytes, size_t length, off_t offset, off_t fileSize) {
    if (offset < 0 || offset > fileSize || (uint64_t)length > (uint64_t)(fileSize - offset)) return NO;
    while (length) {
        ssize_t count = pread(file, bytes, length, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        length -= (size_t)count;
        offset += count;
    }
    return YES;
}

static BOOL IsCompleteS1HPixelShift(int file, off_t fileSize) {
    uint8_t header[8], countBytes[2], entries[MaximumIFDEntries * IFDEntrySize];
    if (!ReadExactly(file, header, sizeof header, 0, fileSize) ||
        memcmp(header, "II\x55\x00", 4) != 0) return NO;
    uint32_t ifdOffset = ReadLE32(header + 4);
    if (ifdOffset < sizeof header || ifdOffset > 4096 ||
        !ReadExactly(file, countBytes, sizeof countBytes, ifdOffset, fileSize)) return NO;
    uint16_t entryCount = ReadLE16(countBytes);
    if (entryCount == 0 || entryCount > MaximumIFDEntries) return NO;
    size_t entriesLength = (size_t)entryCount * IFDEntrySize;
    if (!ReadExactly(file, entries, entriesLength, ifdOffset + sizeof countBytes, fileSize)) return NO;

    enum {
        SensorWidth, SensorHeight, RawFormat, CropTop, CropLeft, CropBottom, CropRight,
        CameraModel, RawPayload, RawOffset, Multishot, TailOffset, FieldCount
    };
    static const struct { uint16_t tag, type; uint32_t count; } fields[FieldCount] = {
        [SensorWidth] = {0x0002, 3, 1}, [SensorHeight] = {0x0003, 3, 1},
        [RawFormat] = {0x002d, 3, 1}, [CropTop] = {0x002f, 3, 1},
        [CropLeft] = {0x0030, 3, 1}, [CropBottom] = {0x0031, 3, 1}, [CropRight] = {0x0032, 3, 1},
        [CameraModel] = {0x0110, 2, 7}, [RawPayload] = {0x0117, 4, 1}, [RawOffset] = {0x0118, 4, 1},
        [Multishot] = {0x0121, 4, 1}, [TailOffset] = {0x0122, 4, 1}
    };
    uint32_t values[FieldCount] = {0};
    uint32_t seen = 0;
    for (size_t index = 0; index < entryCount; ++index) {
        const uint8_t *entry = entries + index * IFDEntrySize;
        uint16_t tag = ReadLE16(entry);
        for (NSUInteger field = 0; field < FieldCount; ++field) {
            if (fields[field].tag != tag) continue;
            uint32_t bit = 1U << field;
            uint16_t type = ReadLE16(entry + 2);
            if ((seen & bit) || type != fields[field].type || ReadLE32(entry + 4) != fields[field].count) return NO;
            seen |= bit;
            values[field] = type == 3 ? ReadLE16(entry + 8) : ReadLE32(entry + 8);
            break;
        }
    }
    if (seen != ((1U << FieldCount) - 1) ||
        values[SensorWidth] != 12096 || values[SensorHeight] != 8018 ||
        values[RawFormat] != 7 || values[Multishot] != 65536 ||
        values[CropRight] > values[SensorWidth] || values[CropBottom] > values[SensorHeight] ||
        values[CropLeft] + 12000 != values[CropRight] ||
        values[CropTop] + 8000 != values[CropBottom] ||
        values[RawPayload] != S1HRawPayloadSize ||
        values[RawOffset] < ifdOffset + sizeof countBytes + entriesLength + 4) return NO;

    uint8_t model[7];
    if (values[CameraModel] > values[RawOffset] || sizeof model > values[RawOffset] - values[CameraModel] ||
        !ReadExactly(file, model, sizeof model, values[CameraModel], fileSize) ||
        memcmp(model, "DC-S1H", sizeof model) != 0) return NO;
    uint64_t rawEnd = (uint64_t)values[RawOffset] + values[RawPayload];
    return rawEnd == values[TailOffset] && (uint64_t)fileSize == rawEnd + S1HRawTailSize;
}

static BOOL ReadCompleteFile(int parent, const char *name, const struct stat *listed, NSData *listedStamp) {
    int file = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (file < 0) return NO;
    struct stat status;
    BOOL complete =
        fstat(file, &status) == 0 && S_ISREG(status.st_mode) && [listedStamp isEqualToData:FileStamp(&status)] &&
        IsCompleteS1HPixelShift(file, listed->st_size) &&
        fstat(file, &status) == 0 && [listedStamp isEqualToData:FileStamp(&status)] &&
        fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(status.st_mode) &&
        [listedStamp isEqualToData:FileStamp(&status)];
    close(file);
    return complete;
}

static BOOL IsDateDirectoryName(const char *name, size_t length) {
    if (length != 8) return NO;
    for (size_t index = 0; index < length; ++index) {
        if (name[index] < '0' || name[index] > '9') return NO;
    }
    int month = (name[4] - '0') * 10 + name[5] - '0';
    int day = (name[6] - '0') * 10 + name[7] - '0';
    return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

typedef BOOL (^RAWFileVisitor)(int parent, const char *name, NSString *relativePath, const struct stat *status);

/* Takes ownership of directoryFD. A visitor return of YES ends the scan
 * successfully. Date subfolders share the entry budget with the root. */
static int ScanRAWFiles(int directoryFD, NSString *dateFolder, NSUInteger *remaining,
                        RAWFileVisitor visitor, BOOL *found) {
    DIR *stream = fdopendir(directoryFD);
    if (!stream) {
        int error = errno;
        close(directoryFD);
        return error;
    }
    int error = 0;
    while (!*found) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { error = errno; break; }
        const char *name = entry->d_name;
        size_t length = entry->d_namlen;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        if (*remaining == 0) { error = E2BIG; break; }
        --*remaining;
        if (entry->d_type == DT_LNK) continue;

        if (!dateFolder && IsDateDirectoryName(name, length)) {
            int child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
            if (child < 0) {
                if (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) continue;
                error = errno;
                break;
            }
            NSString *folder = [[NSString alloc] initWithBytes:name length:length encoding:NSASCIIStringEncoding];
            error = ScanRAWFiles(child, folder, remaining, visitor, found);
            if (error) break;
        } else if (length > 4 && strcasecmp(name + length - 4, ".rw2") == 0) {
            struct stat status;
            if (fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) < 0) {
                if (errno == ENOENT) continue;
                error = errno;
                break;
            }
            if (!S_ISREG(status.st_mode)) continue;
            @autoreleasepool {
                NSString *basename = [[NSString alloc] initWithBytes:name length:length encoding:NSUTF8StringEncoding];
                if (!basename) continue;
                NSString *relativePath = dateFolder ? [dateFolder stringByAppendingPathComponent:basename] : basename;
                *found = visitor(directoryFD, name, relativePath, &status);
            }
        }
    }
    closedir(stream);
    return error;
}

static int OpenFolder(NSURL *directory) {
    const char *path = directory.isFileURL ? directory.fileSystemRepresentation : NULL;
    if (!path) { errno = EINVAL; return -1; }
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
}

static void ReportError(NSError **error, int code) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

@implementation GuardianRAWArrival {
    NSURL *_directory;
    dev_t _directoryDevice;
    ino_t _directoryInode;
    NSDictionary<NSString *, NSData *> *_baseline;
}

- (instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error {
    if (error) *error = nil;
    if (!(self = [super init])) return nil;
    int folder = OpenFolder(directory);
    if (folder < 0) { ReportError(error, errno); return nil; }
    struct stat identity;
    if (fstat(folder, &identity) < 0) {
        int code = errno;
        close(folder);
        ReportError(error, code);
        return nil;
    }
    NSMutableDictionary<NSString *, NSData *> *baseline = [NSMutableDictionary dictionary];
    NSUInteger budget = MaximumDirectoryEntries;
    BOOL found = NO;
    int code = ScanRAWFiles(folder, nil, &budget, ^BOOL(int parent, const char *name, NSString *path, const struct stat *status) {
        (void)parent;
        (void)name;
        baseline[path] = FileStamp(status);
        return NO;
    }, &found);
    if (code) { ReportError(error, code); return nil; }
    _directory = [directory copy];
    _directoryDevice = identity.st_dev;
    _directoryInode = identity.st_ino;
    _baseline = [baseline copy];
    return self;
}

- (GuardianRAWArrivalResult *)checkForArrivalWithError:(NSError **)error {
    if (error) *error = nil;
    int folder = OpenFolder(_directory);
    if (folder < 0) { ReportError(error, errno); return nil; }
    struct stat identity;
    int identityError = fstat(folder, &identity) < 0 ? errno : 0;
    if (!identityError && (identity.st_dev != _directoryDevice || identity.st_ino != _directoryInode))
        identityError = ESTALE;
    if (identityError) {
        close(folder);
        ReportError(error, identityError);
        return nil;
    }
    NSDictionary<NSString *, NSData *> *baseline = _baseline;
    __block GuardianRAWArrivalResult *arrival = nil;
    NSUInteger budget = MaximumDirectoryEntries;
    BOOL found = NO;
    int code = ScanRAWFiles(folder, nil, &budget, ^BOOL(int parent, const char *name, NSString *path, const struct stat *status) {
        if (status->st_size < (off_t)(S1HRawPayloadSize + S1HRawTailSize)) return NO;
        NSData *stamp = FileStamp(status);
        if ([stamp isEqualToData:baseline[path]] || !ReadCompleteFile(parent, name, status, stamp)) return NO;
        arrival = [[GuardianRAWArrivalResult alloc] initWithRelativePath:path fileSize:(uint64_t)status->st_size];
        return YES;
    }, &found);
    if (code) { ReportError(error, code); return nil; }
    return arrival;
}
@end
