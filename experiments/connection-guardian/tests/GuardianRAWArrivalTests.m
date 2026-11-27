#import "../GuardianRAWArrival.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const uint32_t RawOffset = 4096;
static const uint32_t RawPayloadSize = 172419072;
static const uint32_t TailSize = 65536;
static unsigned checks, failures;

static void Check(BOOL passed, const char *label) {
    ++checks;
    if (!passed) {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", label);
    }
}

static void WriteLE16(uint8_t *bytes, uint16_t value) {
    for (unsigned offset = 0; offset < 2; ++offset) bytes[offset] = (uint8_t)(value >> (8 * offset));
}

static void WriteLE32(uint8_t *bytes, uint32_t value) {
    for (unsigned offset = 0; offset < 4; ++offset) bytes[offset] = (uint8_t)(value >> (8 * offset));
}

/* Sparse fixture for testing the known file layout. It intentionally contains
 * no real photos or pixel data, which the watcher does not decode. */
static BOOL WriteFixture(NSString *path, uint16_t rawFormat, uint32_t ifdOffset, off_t fileSize) {
    enum { IFDOffset = 24, ModelOffset = 256 };
    const struct { uint16_t tag, type; uint32_t count, value; } fields[] = {
        {0x0002, 3, 1, 12096}, {0x0003, 3, 1, 8018}, {0x002d, 3, 1, rawFormat},
        {0x002f, 3, 1, 8}, {0x0030, 3, 1, 16}, {0x0031, 3, 1, 8008}, {0x0032, 3, 1, 12016},
        {0x0110, 2, 7, ModelOffset}, {0x0117, 4, 1, RawPayloadSize}, {0x0118, 4, 1, RawOffset},
        {0x0121, 4, 1, 65536}, {0x0122, 4, 1, RawOffset + RawPayloadSize}
    };
    size_t count = sizeof fields / sizeof fields[0];
    uint8_t bytes[512] = {'I', 'I', 0x55};
    WriteLE32(bytes + 4, ifdOffset);
    WriteLE16(bytes + IFDOffset, (uint16_t)count);
    for (size_t index = 0; index < count; ++index) {
        uint8_t *entry = bytes + IFDOffset + 2 + index * 12;
        WriteLE16(entry, fields[index].tag);
        WriteLE16(entry + 2, fields[index].type);
        WriteLE32(entry + 4, fields[index].count);
        WriteLE32(entry + 8, fields[index].value);
    }
    memcpy(bytes + ModelOffset, "DC-S1H", 7);
    int file = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (file < 0) return NO;
    BOOL written = write(file, bytes, sizeof bytes) == sizeof bytes && ftruncate(file, fileSize) == 0;
    return close(file) == 0 && written;
}

static void CheckWaiting(GuardianRAWArrival *watcher, const char *label) {
    NSError *error = nil;
    GuardianRAWArrivalResult *arrival = [watcher checkForArrivalWithError:&error];
    Check(watcher && !arrival && !error, label);
}

static void RunTest(NSString *root) {
    off_t completeSize = (off_t)RawOffset + RawPayloadSize + TailSize;
    NSString *folder = [root stringByAppendingPathComponent:@"capture"];
    NSFileManager *files = NSFileManager.defaultManager;
    Check([files createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:NULL],
          "Create isolated capture folder");
    NSString *oldFile = [folder stringByAppendingPathComponent:@"old.rw2"];
    Check(WriteFixture(oldFile, 7, 24, completeSize), "Create baseline image");
    NSError *error = nil;
    NSURL *directory = [NSURL fileURLWithPath:folder isDirectory:YES];
    GuardianRAWArrival *watcher = [[GuardianRAWArrival alloc] initWithDirectory:directory error:&error];
    Check(watcher && !error, "Arm observer with the selected directory");
    CheckWaiting(watcher, "An existing complete image cannot satisfy the observer");

    Check(WriteFixture([folder stringByAppendingPathComponent:@"ordinary.rw2"], 6, 24, 35900000),
          "Create ordinary RAW fixture");
    Check(WriteFixture([folder stringByAppendingPathComponent:@"wrong-format.rw2"], 6, 24, completeSize),
          "Create an exact-sized fixture with the wrong RAW format");
    Check(WriteFixture([folder stringByAppendingPathComponent:@"invalid-offset.rw2"], 7, UINT32_MAX, completeSize),
          "Create invalid IFD offset fixture");
    Check(WriteFixture([folder stringByAppendingPathComponent:@"short.rw2"], 7, 24, completeSize - 1),
          "Create RAW missing the end of its tail");
    CheckWaiting(watcher, "Ordinary, malformed or short RAW stays pending");

    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    Check([files createDirectoryAtPath:outside withIntermediateDirectories:NO attributes:nil error:NULL],
          "Create an outside folder");
    NSString *outsideFile = [outside stringByAppendingPathComponent:@"external.rw2"];
    Check(WriteFixture(outsideFile, 7, 24, completeSize), "Create the target of a symbolic link");
    Check([files createSymbolicLinkAtPath:[folder stringByAppendingPathComponent:@"linked.rw2"]
                    withDestinationPath:outsideFile error:NULL], "Link a file inside the monitored folder");
    Check([files createSymbolicLinkAtPath:[folder stringByAppendingPathComponent:@"20261124"]
                    withDestinationPath:outside error:NULL], "Link a date subfolder to the outside folder");
    CheckWaiting(watcher, "Neither linked files nor linked date folders are followed");

    NSString *dateFolder = [folder stringByAppendingPathComponent:@"20261125"];
    Check([files createDirectoryAtPath:dateFolder withIntermediateDirectories:NO attributes:nil error:NULL],
          "Create a date folder after arming");
    NSString *relative = @"20261125/new.RW2";
    Check(WriteFixture([folder stringByAppendingPathComponent:relative], 7, 24, completeSize),
          "Create a new high-resolution RAW in the date folder");
    GuardianRAWArrivalResult *arrival = [watcher checkForArrivalWithError:&error];
    Check(!error && [arrival.relativePath isEqualToString:relative] && arrival.fileSize == (uint64_t)completeSize,
          "Find a newly complete RAW in a date folder regardless of extension case");

    watcher = [[GuardianRAWArrival alloc] initWithDirectory:directory error:&error];
    Check(watcher && !error, "Rearm after the arrival");
    CheckWaiting(watcher, "Rearming makes that arrival part of the baseline");
    NSString *growing = [folder stringByAppendingPathComponent:@"growing.rw2"];
    Check(WriteFixture(growing, 7, 24, completeSize - TailSize), "Create an in-progress RAW");
    CheckWaiting(watcher, "The full RAW payload is insufficient until its tail arrives");
    Check(truncate(growing.fileSystemRepresentation, completeSize) == 0, "Complete the same file");
    arrival = [watcher checkForArrivalWithError:&error];
    Check(!error && [arrival.relativePath isEqualToString:@"growing.rw2"],
          "The writer can complete a file between polls without renaming it");

    NSString *relocated = [root stringByAppendingPathComponent:@"relocated"];
    Check([files moveItemAtPath:folder toPath:relocated error:NULL] &&
          [files createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:NULL],
          "Replace the monitored directory");
    arrival = [watcher checkForArrivalWithError:&error];
    Check(!arrival && [error.domain isEqualToString:NSPOSIXErrorDomain],
          "A directory replacement makes the observer unavailable");
}

int main(void) {
    @autoreleasepool {
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"guardian-raw-test.XXXXXXXX"];
        char *path = strdup(pattern.fileSystemRepresentation);
        if (!path || !mkdtemp(path)) { free(path); return 1; }
        NSString *root = [[NSString alloc] initWithUTF8String:path];
        free(path);
        RunTest(root);
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
        printf("RAW arrival self-test: %u checks, %u failures.\n", checks, failures);
        return failures ? 1 : 0;
    }
}
