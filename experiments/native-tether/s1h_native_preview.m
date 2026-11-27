/*
 * Experimental S1H native continuous preview CLI. Independently implemented;
 * no ImageCaptureCore, libusb, gphoto runtime, or copied gphoto implementation.
 * Transport/drain primitives reused from this workspace's own MIT probe.
 * Protocol facts reference libgphoto2 commit
 * 31a2f4089f19aec6caca7920b03e3eb7a251c5b6:
 *   camlibs/ptp2/ptp.h: Panasonic Liveview/LiveviewImage definitions;
 *   camlibs/ptp2/ptp.c: ptp_panasonic_liveview_image has zero parameters;
 *   camlibs/ptp2/library.c: Panasonic camera_capture_preview branch.
 *
 * Only 1002/1001/1003 and preview 9412(start/stop)/9706 are allowed by default.
 * Explicit --preview-format additionally uses 9414 format queries and a
 * bounded, independently packed 9415 preview-format data phase. Every
 * explicit selection requires --keep-preview-format acknowledgement and
 * verifies the retained tuple. This alpha does not restore formats.
 * One sequential PTP session serves preview and explicit capture/control
 * actions. No further command is sent on an unknown transaction boundary.
 *
 * --self-test and --help do not access hardware. All actual hardware tests
 * must be coordinated by the operator with other camera clients closed.
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <stdatomic.h>
#include <math.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

#define IO_TIMEOUT 2.0
#define READ_CAPACITY 65536U
#define MAX_CONTAINER_LENGTH (16U * 1024U * 1024U)
static volatile sig_atomic_t StopRequested = 0;
static _Atomic(uint64_t) PhaseDeadlineNS = 0;
static pid_t ExpectedParentPID = 0;
static dispatch_source_t Watchdog;
static void stop_signal(int number) { (void)number; StopRequested = 1; }

static BOOL parse_parent_pid(const char *text, pid_t *result) {
    if (!text || !*text) return NO;
    unsigned int value = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p < '0' || *p > '9') return NO;
        unsigned int digit = *p - '0';
        if (value > ((unsigned int)INT_MAX - digit) / 10) return NO;
        value = value * 10 + digit;
    }
    if (value < 2) return NO;
    if (result) *result = (pid_t)value;
    return YES;
}
static BOOL parent_changed(pid_t expected, pid_t actual) {
    return expected >= 2 && actual != expected;
}

static uint16_t read16(const unsigned char *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static uint32_t read32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void write16(unsigned char *p, uint16_t n) {
    p[0] = n; p[1] = n >> 8;
}
static void write32(unsigned char *p, uint32_t n) {
    p[0] = n; p[1] = n >> 8; p[2] = n >> 16; p[3] = n >> 24;
}
static void show_error(const char *stage, NSError *error) {
    printf("%s: NSError domain=%s code=%ld (0x%08x)\n", stage,
           error ? error.domain.UTF8String : "none",
           (long)(error ? error.code : 0),
           (unsigned int)(error ? error.code : 0));
}

static NSMutableData *make_buffer(IOUSBHostInterface *interface,
                                  NSUInteger length, BOOL ioBuffer) {
    if (!ioBuffer) return [NSMutableData dataWithLength:length];
    NSError *error = nil;
    NSMutableData *data = [interface ioDataWithCapacity:length error:&error];
    if (!data) {
        show_error("Allocate native kernel DMA buffer", error);
        return nil;
    }
    if (data.length != length) {
        printf("Kernel DMA buffer length differs: requested=%lu returned=%lu; will not resize or submit it.\n",
               (unsigned long)length, (unsigned long)data.length);
        return nil;
    }
    return data;
}

/* enqueueIORequest is the actual native async API. The calling thread waits
 * on a semaphore while callbacks execute on the interface's serial queue.
 * No synchronous sendIORequest or legacy IOUSBLib entry point is used.
 */
static BOOL transfer_timed(IOUSBHostPipe *pipe, NSMutableData *data,
                           const char *label, NSUInteger *actual, BOOL *callbackReceived,
                           NSTimeInterval completionTimeout, NSTimeInterval waitTimeout,
                           IOReturn *completionStatus, BOOL logSuccess) {
    if (callbackReceived) *callbackReceived = NO;
    if (completionStatus) *completionStatus = kIOReturnError;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block IOReturn status = kIOReturnError;
    __block NSUInteger count = 0;
    NSError *error = nil;
    BOOL enqueued = [pipe enqueueIORequestWithData:data
                              completionTimeout:completionTimeout
                                          error:&error
                              completionHandler:^(IOReturn result, NSUInteger bytes) {
        /* Explicit strong reference keeps the transfer buffer alive until
         * completion even if the local caller's deadline expires. */
        (void)data.length;
        status = result;
        count = bytes;
        dispatch_semaphore_signal(completed);
    }];
    if (!enqueued) {
        show_error(label, error);
        return NO;
    }
    if (dispatch_semaphore_wait(completed,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTimeout * NSEC_PER_SEC))) != 0) {
        printf("%s: no callback within %.3f seconds; aborting pending I/O\n", label, waitTimeout);
        NSError *abortError = nil;
        if (![pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:&abortError])
            show_error("abort", abortError);
        return NO;
    }
    if (logSuccess || status != kIOReturnSuccess || count > data.length)
        printf("%s: completion=0x%08x API-reported-bytes=%lu requested=%lu\n", label,
               (unsigned int)status, (unsigned long)count, (unsigned long)data.length);
    if (actual) *actual = count;
    if (callbackReceived) *callbackReceived = YES;
    if (completionStatus) *completionStatus = status;
    return status == kIOReturnSuccess && count <= data.length;
}

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

/* Parse and discard only pre-existing complete containers, keeping payload
 * boundaries across short/multiple USB completions. No PTP command is sent.
 * An error or partial-container timeout cannot certify that the queue is
 * empty, so the caller must stop before issuing OpenSession in those cases.
 */
static BOOL drain_input(IOUSBHostInterface *interface, IOUSBHostPipe *in,
                        BOOL ioBuffer) {
    const double deadline = monotonic_seconds() + 3.0;
    unsigned char header[12];
    NSUInteger headerHave = 0;
    uint32_t payloadRemaining = 0;
    unsigned completeContainers = 0;
    printf("Draining pre-existing bulk IN: 500ms reads, 3-second total budget, at most 5 complete containers.\n");
    while (monotonic_seconds() < deadline) {
        NSMutableData *data = make_buffer(interface, READ_CAPACITY, ioBuffer);
        if (!data) return NO;
        double remainingTime = deadline - monotonic_seconds();
        if (remainingTime <= 0) break;
        NSTimeInterval ioTimeout = MIN(0.5, remainingTime);
        NSTimeInterval waitTimeout = MIN(0.75, remainingTime);
        NSUInteger count = 0;
        BOOL callbackReceived = NO;
        IOReturn status = kIOReturnError;
        BOOL ok = transfer_timed(in, data, "drain bulk IN 0x82", &count,
                                  &callbackReceived, ioTimeout, waitTimeout, &status, YES);
        if (!ok) {
            /* 0xe0004051 is the legacy USB transaction timeout value; modern
             * IOUSBHost normally returns kIOReturnTimeout (0xe00002d6). */
            BOOL timeout = status == kIOReturnTimeout || (uint32_t)status == 0xe0004051U;
            if (callbackReceived && timeout && count == 0 &&
                headerHave == 0 && payloadRemaining == 0) {
                printf("Drain complete: zero-byte timeout on PTP container boundary after %u complete containers.\n",
                       completeContainers);
                return YES;
            }
            printf("Drain not certified: error, nonzero error byte count, or incomplete container (header=%lu payloadRemaining=%u). No OUT will be sent.\n",
                   (unsigned long)headerHave, payloadRemaining);
            return NO;
        }
        if (count == 0) {
            printf("Drain saw successful zero-length packet; continuing until a bounded timeout.\n");
            continue;
        }
        const unsigned char *bytes = data.bytes;
        NSUInteger offset = 0;
        while (offset < count) {
            if (payloadRemaining) {
                NSUInteger consumed = MIN((NSUInteger)payloadRemaining, count - offset);
                offset += consumed;
                payloadRemaining -= (uint32_t)consumed;
                if (payloadRemaining == 0) {
                    ++completeContainers;
                    headerHave = 0;
                }
            } else {
                NSUInteger copied = MIN(sizeof header - headerHave, count - offset);
                memcpy(header + headerHave, bytes + offset, copied);
                headerHave += copied;
                offset += copied;
                if (headerHave == sizeof header) {
                    uint32_t length = read32(header), tx = read32(header + 8);
                    uint16_t type = read16(header + 4), code = read16(header + 6);
                    printf("Drain container: type=%u length=%u code=0x%04x tx=%u; payload discarded.\n",
                           type, length, code, tx);
                    if (length < sizeof header || length > MAX_CONTAINER_LENGTH ||
                        (type != 2 && type != 3 && type != 4)) {
                        printf("Drain encountered invalid/unexpected container header. No OUT will be sent.\n");
                        return NO;
                    }
                    payloadRemaining = length - (uint32_t)sizeof header;
                    if (payloadRemaining == 0) {
                        ++completeContainers;
                        headerHave = 0;
                    }
                }
            }
            if (completeContainers >= 5) {
                printf("Drain reached five-container limit before verifying empty input. No OUT will be sent.\n");
                return NO;
            }
        }
    }
    printf("Drain reached 3-second limit before verifying empty input. No OUT will be sent.\n");
    return NO;
}

static void phase_deadline(double seconds) {
    atomic_store(&PhaseDeadlineNS, (uint64_t)((monotonic_seconds() + seconds) * 1e9));
}
static void begin_watchdog(void) {
    Watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(Watchdog, dispatch_time(DISPATCH_TIME_NOW, 200000000),
                              200000000, 20000000);
    __block uint64_t cancellationDeadline = 0;
    dispatch_source_set_event_handler(Watchdog, ^{
        uint64_t now = (uint64_t)(monotonic_seconds() * 1e9);
        if (!StopRequested && parent_changed(ExpectedParentPID, getppid())) {
            fprintf(stderr, "Launching parent exited; requesting cancellation in this worker only.\n");
            raise(SIGTERM); /* Signals this process, never the supplied PID. */
        }
        if (StopRequested && !cancellationDeadline) cancellationDeadline = now + 10000000000ULL;
        uint64_t deadline = atomic_load(&PhaseDeadlineNS);
        if ((deadline && now >= deadline) || (cancellationDeadline && now >= cancellationDeadline)) {
            fprintf(stderr, "Worker watchdog deadline exceeded; exiting this worker only.\n");
            _exit(124);
        }
    });
    dispatch_resume(Watchdog);
}

@interface PreviewOptions : NSObject
@property(nonatomic) NSUInteger frames;
@property(nonatomic) double duration;
@property(nonatomic) double fps;
@property(nonatomic, copy) NSString *output;
@property(nonatomic, copy) NSString *previewFormat;
@property(nonatomic) BOOL keepPreviewFormat;
@property(nonatomic) BOOL inspectControls;
@property(nonatomic) BOOL interactive;
@property(nonatomic) BOOL closeStaleSession;
@property(nonatomic, strong) NSNumber *explicitStorageTarget;
@property(nonatomic, copy) NSString *cameraSaveDirectory;
@property(nonatomic, copy) NSString *photoNamePrefix;
@property(nonatomic) BOOL verbose;
@end
@implementation PreviewOptions
@end

@interface PreviewStatus : NSObject
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) double previewStart;
@property(nonatomic, copy) NSString *writeError;
@property(nonatomic, strong) NSMutableDictionary *formatMetadata;
@property(nonatomic, strong) NSDictionary *deviceCapabilities;
@property(nonatomic, strong) NSNumber *usbLinkSpeed;
@property(nonatomic, copy) NSString *usbInterfaceOwner;
@property(nonatomic, strong) NSNumber *batteryPercent;
@property(nonatomic, strong) NSDictionary *controls;
@property(nonatomic, strong) NSDictionary *actionStatus;
@property(nonatomic, strong) NSDictionary *captureStorage;
@property(nonatomic, strong) NSDictionary *cameraTransfer;
@property(nonatomic) BOOL captureAvailable;
@property(nonatomic) BOOL requiresReview;
@property(nonatomic) BOOL staleSession;
@property(nonatomic) double lastStatusWrite;
@property(nonatomic) BOOL lastReportedCaptureAvailable;
- (BOOL)update:(NSString *)state message:(NSString *)message;
- (BOOL)publish:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height;
@end
@implementation PreviewStatus
- (BOOL)update:(NSString *)state message:(NSString *)message {
    double elapsed = _previewStart > 0 ? MAX(0, monotonic_seconds() - _previewStart) : 0;
    BOOL captureAvailable = _captureAvailable && !_requiresReview && [state isEqualToString:@"previewing"];
    NSMutableDictionary *status = [@{@"schema_version": @1, @"status": state, @"frames": @(_frames),
                            @"width": @(_width), @"height": @(_height),
                            @"elapsed_seconds": @(elapsed),
                            @"fps": @(elapsed > 0 ? (double)_frames / elapsed : 0),
                            @"cancelled": @((BOOL)(StopRequested != 0)), @"message": message ?: @""} mutableCopy];
    if (_formatMetadata) status[@"preview_format"] = _formatMetadata;
    if (_deviceCapabilities) status[@"device_capabilities"] = _deviceCapabilities;
    if (_usbLinkSpeed) status[@"usb_link_bps"] = _usbLinkSpeed;
    if (_usbInterfaceOwner && [state isEqualToString:@"error"]) status[@"usb_interface_owner"] = _usbInterfaceOwner;
    if (_batteryPercent) status[@"battery_percent"] = _batteryPercent;
    if (_controls) status[@"controls"] = _controls;
    if (_actionStatus) status[@"action_status"] = _actionStatus;
    if (_captureStorage) status[@"capture_storage"] = _captureStorage;
    if (_cameraTransfer) status[@"camera_transfer"] = _cameraTransfer;
    status[@"requires_review"] = @(_requiresReview);
    status[@"stale_session"] = @(_staleSession);
    status[@"capture_available"] = @(captureAvailable);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || ![data writeToURL:[_directory URLByAppendingPathComponent:@"status.json"]
                           options:NSDataWritingAtomic error:&error]) {
        _writeError = @"Could not write status.json.";
        return NO;
    }
    _lastStatusWrite = monotonic_seconds();
    _lastReportedCaptureAvailable = captureAvailable;
    return YES;
}
- (BOOL)publish:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height {
    NSError *error = nil;
    if (![jpeg writeToURL:[_directory URLByAppendingPathComponent:@"latest.jpg"]
                   options:NSDataWritingAtomic error:&error]) {
        _writeError = @"Could not write latest.jpg.";
        return NO;
    }
    BOOL dimensionsChanged = _width != width || _height != height;
    ++_frames;
    _width = width;
    _height = height;
    // JPEG delivery and capture state changes should remain immediate. The
    // frame counters alone can be sampled without rewriting JSON per frame.
    BOOL captureAvailable = _captureAvailable && !_requiresReview;
    if (_frames > 1 && !dimensionsChanged && captureAvailable == _lastReportedCaptureAvailable &&
        monotonic_seconds() - _lastStatusWrite < 0.25) return YES;
    return [self update:@"previewing" message:@"Native USB preview is running."];
}
@end

@interface PreviewContainer : NSObject
@property(nonatomic) uint16_t type;
@property(nonatomic) uint16_t code;
@property(nonatomic) uint32_t transaction;
@property(nonatomic, strong) NSData *payload;
@end
@implementation PreviewContainer
@end

@interface PreviewReader : NSObject
@property(nonatomic, copy) NSData *(^readChunk)(void);
@property(nonatomic, strong) NSData *pending;
@property(nonatomic) NSUInteger offset;
@property(nonatomic, copy) NSString *error;
- (BOOL)take:(NSUInteger)length destination:(void *)destination;
- (PreviewContainer *)container;
@end
@implementation PreviewReader
- (BOOL)take:(NSUInteger)length destination:(void *)destination {
    unsigned char *out = destination;
    while (length) {
        if (!_pending || _offset == _pending.length) {
            _pending = _readChunk ? _readChunk() : nil;
            _offset = 0;
            if (!_pending.length) { _error = @"Bulk IN did not provide complete container bytes."; return NO; }
        }
        NSUInteger count = MIN(length, _pending.length - _offset);
        if (out) { memcpy(out, (const unsigned char *)_pending.bytes + _offset, count); out += count; }
        _offset += count;
        length -= count;
    }
    return YES;
}
- (PreviewContainer *)container {
    unsigned char header[12];
    if (![self take:sizeof header destination:header]) return nil;
    uint32_t length = read32(header);
    uint16_t type = read16(header + 4);
    if (length < 12 || length > MAX_CONTAINER_LENGTH || (type != 2 && type != 3 && type != 4) ||
        (type == 3 && length > 32) || (type == 4 && length > 24)) {
        _error = @"Invalid PTP container header or size.";
        return nil;
    }
    NSMutableData *payload = [NSMutableData dataWithLength:length - 12];
    if (![self take:payload.length destination:payload.mutableBytes]) return nil;
    PreviewContainer *container = [PreviewContainer new];
    container.type = type;
    container.code = read16(header + 6);
    container.transaction = read32(header + 8);
    container.payload = payload;
    return container;
}
@end

static BOOL format_record_valid(NSDictionary *format) {
    for (NSString *key in @[@"height", @"width", @"x_raw", @"frequency_raw"]) {
        id value = format[key];
        if (![value isKindOfClass:NSNumber.class]) return NO;
        double number = [value doubleValue];
        if (!isfinite(number) || floor(number) != number || number < 0 || number > UINT16_MAX) return NO;
    }
    return [format[@"height"] unsignedIntValue] > 0 && [format[@"width"] unsignedIntValue] > 0;
}
static NSDictionary *format_record(const unsigned char *bytes) {
    return @{@"height": @(read16(bytes)), @"width": @(read16(bytes + 2)),
             @"x_raw": @(read16(bytes + 4)), @"frequency_raw": @(read16(bytes + 6))};
}
static NSArray<NSDictionary *> *parse_available_formats(NSData *data, NSString **error) {
#define FORMAT_ERROR(message) do { if (error) *error = (message); return nil; } while (0)
    if (data.length < 12) FORMAT_ERROR(@"Available preview formats have an incomplete header.");
    const unsigned char *bytes = data.bytes;
    uint32_t blob = read32(bytes + 4);
    if (read32(bytes) != 0x0d800012 || blob < 4 || blob != data.length - 8)
        FORMAT_ERROR(@"Available preview formats have an unsupported tag or blob length.");
    uint16_t count = read16(bytes + 8), recordSize = read16(bytes + 10);
    if (recordSize != 8 || count > 1024 || count > (blob - 4) / recordSize || blob != 4 + (NSUInteger)count * recordSize)
        FORMAT_ERROR(@"Available preview formats have an invalid count or record size.");
    NSMutableArray *formats = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; ++i) {
        NSDictionary *format = format_record(bytes + 12 + i * recordSize);
        if (!format_record_valid(format)) FORMAT_ERROR(@"A reported preview format has invalid dimensions.");
        [formats addObject:format];
    }
    return formats;
#undef FORMAT_ERROR
}
static NSDictionary *parse_current_format(NSData *data, NSString **error) {
    /* Accept only the fully understood four-field format for comparisons. */
    if (data.length != 16 || read32(data.bytes) != 0x0d800011 ||
        read32((const unsigned char *)data.bytes + 4) != 8) {
        if (error) *error = @"Current preview format has an unsupported payload shape.";
        return nil;
    }
    NSDictionary *format = format_record((const unsigned char *)data.bytes + 8);
    if (!format_record_valid(format)) { if (error) *error = @"Current preview format has invalid dimensions."; return nil; }
    return format;
}
static BOOL parse_format_index(NSString *text, NSUInteger *index) {
    const unsigned char *bytes = (const unsigned char *)text.UTF8String;
    if (!bytes || !*bytes) return NO;
    NSUInteger value = 0;
    for (const unsigned char *p = bytes; *p; ++p) {
        if (*p < '0' || *p > '9') return NO;
        NSUInteger digit = *p - '0';
        if (value > (UINT16_MAX - digit) / 10) return NO;
        value = value * 10 + digit;
    }
    if (index) *index = value;
    return YES;
}
static BOOL keep_preview_format_valid(BOOL keep, NSString *mode) {
    if ([mode isEqualToString:@"auto"]) return !keep;
    return keep && ([mode isEqualToString:@"max"] || parse_format_index(mode, NULL));
}
static NSDictionary *select_preview_format(NSArray<NSDictionary *> *formats, NSString *mode, NSString **error) {
    if (!formats.count) { if (error) *error = @"The camera reported no selectable preview formats."; return nil; }
    for (NSDictionary *format in formats)
        if (!format_record_valid(format)) { if (error) *error = @"A selectable preview format is invalid."; return nil; }
    if ([mode isEqualToString:@"max"]) {
        NSDictionary *selected = nil;
        uint64_t largest = 0;
        for (NSDictionary *format in formats) {
            uint64_t area = (uint64_t)[format[@"width"] unsignedIntValue] * [format[@"height"] unsignedIntValue];
            if (area > largest) { largest = area; selected = format; }
        }
        return selected; /* Equal areas retain the first camera-reported entry. */
    }
    NSUInteger index = 0;
    if (!parse_format_index(mode, &index) || index >= formats.count) {
        if (error) *error = @"Preview format index is outside the camera-reported list.";
        return nil;
    }
    return formats[index];
}
static BOOL same_preview_format(NSDictionary *a, NSDictionary *b) {
    if (!format_record_valid(a) || !format_record_valid(b)) return NO;
    for (NSString *key in @[@"height", @"width", @"x_raw", @"frequency_raw"])
        if (![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static NSData *pack_preview_format(NSDictionary *format) {
    if (!format_record_valid(format)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:16];
    unsigned char *bytes = data.mutableBytes;
    write32(bytes, 0x0d800011); write32(bytes + 4, 8);
    write16(bytes + 8, [format[@"height"] unsignedShortValue]);
    write16(bytes + 10, [format[@"width"] unsignedShortValue]);
    write16(bytes + 12, [format[@"x_raw"] unsignedShortValue]);
    write16(bytes + 14, [format[@"frequency_raw"] unsignedShortValue]);
    return data;
}
static BOOL format_data_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters, NSData *data) {
    return opcode == 0x9415 && parameters.count == 1 && parameters.firstObject.unsignedIntValue == 0x0d800011 &&
        parse_current_format(data, NULL) != nil;
}
static BOOL write_data_container(NSMutableData *buffer, NSData *payload, uint16_t opcode, uint32_t transaction) {
    if (!payload.length || payload.length > MAX_CONTAINER_LENGTH - 12 || buffer.length != 12 + payload.length) return NO;
    unsigned char *bytes = buffer.mutableBytes;
    write32(bytes, (uint32_t)buffer.length);
    write16(bytes + 4, 2);
    write16(bytes + 6, opcode);
    write32(bytes + 8, transaction);
    memcpy(bytes + 12, payload.bytes, payload.length);
    return YES;
}

static BOOL opcode_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    if (opcode == 0x1001 || opcode == 0x1003 || opcode == 0x9706) return parameters.count == 0;
    if (opcode == 0x1002) return parameters.count == 1 && parameters.firstObject.unsignedIntValue == 1;
    if (opcode == 0x9414) return parameters.count == 1 &&
        (parameters.firstObject.unsignedIntValue == 0x0d800011 || parameters.firstObject.unsignedIntValue == 0x0d800012);
    return opcode == 0x9412 && parameters.count == 1 &&
           (parameters.firstObject.unsignedIntValue == 0x0d000010 || parameters.firstObject.unsignedIntValue == 0x0d000011);
}

@interface PreviewReply : NSObject
@property(nonatomic) uint16_t code;
@property(nonatomic, strong) NSData *data;
@property(nonatomic, strong) NSArray<NSNumber *> *parameters;
@end
@implementation PreviewReply
@end

@interface PreviewInterruptRead : NSObject
@property(nonatomic, strong) dispatch_semaphore_t complete;
@property(nonatomic, strong) NSMutableData *buffer;
@property(nonatomic) IOReturn result;
@property(nonatomic) NSUInteger count;
@end
@implementation PreviewInterruptRead
@end

static const double CaptureEventFragmentTimeout = 2.0;

static NSString *append_capture_events(NSMutableData *pending, NSMutableArray<NSDictionary *> *queue,
                                       NSData *buffer, NSUInteger length, double now, double *fragmentDeadline) {
    if (length > buffer.length) return @"Capture interrupt I/O exceeded its buffer.";
    if (length) [pending appendBytes:buffer.bytes length:length];
    while (pending.length >= 12) {
        const unsigned char *bytes = pending.bytes;
        uint32_t size = read32(bytes);
        if (size < 12 || size > 24 || (size - 12) % 4 || read16(bytes + 4) != 4)
            return @"Capture interrupt event has an invalid container header.";
        if (pending.length < size) break;
        if (queue.count >= 32) return @"Capture event queue exceeded its bound.";
        NSMutableArray *parameters = [NSMutableArray array];
        for (NSUInteger offset = 12; offset < size; offset += 4) [parameters addObject:@(read32(bytes + offset))];
        [queue addObject:@{@"code":@(read16(bytes + 6)), @"transaction":@(read32(bytes + 8)), @"parameters":parameters}];
        [pending replaceBytesInRange:NSMakeRange(0, size) withBytes:NULL length:0];
        *fragmentDeadline = 0;
    }
    if (pending.length && !*fragmentDeadline) *fragmentDeadline = now + CaptureEventFragmentTimeout;
    return nil;
}

@interface NativePreviewTransport : NSObject
@property(nonatomic, strong) IOUSBHostInterface *interface;
@property(nonatomic, strong) IOUSBHostPipe *input;
@property(nonatomic, strong) IOUSBHostPipe *output;
@property(nonatomic, strong) IOUSBHostPipe *events;
@property(nonatomic, strong) NSNumber *usbLinkSpeed;
@property(nonatomic, copy) NSString *usbInterfaceOwner;
@property(nonatomic, strong) NSMutableData *eventPending;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *eventQueue;
@property(nonatomic) double eventFragmentDeadline;
@property(nonatomic, strong) PreviewInterruptRead *eventRead;
@property(nonatomic, strong) PreviewReader *reader;
@property(nonatomic) uint32_t nextTransaction;
@property(nonatomic) BOOL synchronized;
@property(nonatomic) double transactionDeadline;
@property(nonatomic) double transactionBudget;
@property(nonatomic) double responseTimeout;
@property(nonatomic) BOOL controlReadEnabled;
@property(nonatomic) BOOL interactiveEnabled;
@property(nonatomic) BOOL verbose;
@property(nonatomic, copy) NSString *error;
- (BOOL)openInterface;
- (BOOL)drain;
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters dataExpected:(BOOL)expected;
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters dataExpected:(BOOL)expected dataOut:(NSData *)dataOut;
- (PreviewReply *)setPreviewFormat:(NSDictionary *)format;
- (NSDictionary *)readCaptureEvent:(NSTimeInterval)timeout error:(NSString **)error;
- (void)closeInterface;
@end

#include "S1HNativeControl.inc"
#include "S1HNativeFocus.inc"

static BOOL s1h_capture_request_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    if (opcode == 0x9404) return parameters.count == 1 && parameters[0].unsignedIntValue == 0x03000011;
    if (opcode == 0x9401) return parameters.count == 1;
    if (opcode == 0x1007) return parameters.count == 3 && parameters[0].unsignedIntValue == UINT32_MAX &&
        parameters[1].unsignedIntValue == 0 && parameters[2].unsignedIntValue == 0;
    if (opcode == 0x1008 || opcode == 0x9110) return parameters.count == 1 && parameters[0].unsignedIntValue != 0 && parameters[0].unsignedIntValue != UINT32_MAX;
    if (opcode == 0x101b) return parameters.count == 3 && parameters[0].unsignedIntValue != 0 &&
        parameters[0].unsignedIntValue != UINT32_MAX && parameters[2].unsignedIntValue > 0 && parameters[2].unsignedIntValue <= 1024 * 1024;
    if (opcode == 0x9112) return parameters.count == 4 && parameters[0].unsignedIntValue != 0 &&
        parameters[0].unsignedIntValue != UINT32_MAX && parameters[2].unsignedIntValue == 0 &&
        parameters[3].unsignedIntValue > 0 && parameters[3].unsignedIntValue <= 1024 * 1024;
    return NO;
}

static BOOL s1h_vendor_session_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    return (opcode == 0x9102 && parameters.count == 1 && parameters[0].unsignedIntValue == 0x00010001) ||
        (opcode == 0x9103 && parameters.count == 0);
}

static BOOL s1h_storage_inspection_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    return (opcode == 0x1004 && parameters.count == 0) ||
        (opcode == 0x940a && parameters.count == 1 && parameters[0].unsignedIntValue == 0x08000090);
}

enum { S1HBatteryDescriptorOpcode = 0x1014, S1HBatteryValueOpcode = 0x1015, S1HBatteryProperty = 0x5001 };

static BOOL s1h_battery_read_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    return (opcode == S1HBatteryDescriptorOpcode || opcode == S1HBatteryValueOpcode) &&
        parameters.count == 1 && parameters.firstObject.unsignedIntValue == S1HBatteryProperty;
}

static BOOL s1h_capture_target_data_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters, NSData *payload) {
    if (opcode != 0x940b || parameters.count != 1 || payload.length != 10) return NO;
    uint32_t selector = parameters[0].unsignedIntValue;
    if (selector != 0x08000091 && selector != 0) return NO;
    const unsigned char *bytes = payload.bytes;
    return read32(bytes) == 0x08000091 && read32(bytes + 4) == 2 && read16(bytes + 8) <= 2;
}

static NSString *parent_product(io_registry_entry_t entry, CFStringRef key) {
    id property = CFBridgingRelease(IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key,
        kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents));
    return [property isKindOfClass:NSString.class] ? property : @"";
}

static NSString *interface_owner_name(id property) {
    if (![property isKindOfClass:NSString.class]) return nil;
    NSString *label = property;
    if (label.length > 256 || ![label hasPrefix:@"pid "]) return nil;
    NSRange separator = [label rangeOfString:@", "];
    if (separator.location == NSNotFound || separator.location <= 4) return nil;
    unsigned int pid = 0;
    for (NSUInteger i = 4; i < separator.location; ++i) {
        unichar digit = [label characterAtIndex:i];
        if (digit < '0' || digit > '9' || pid > ((unsigned int)INT_MAX - (digit - '0')) / 10) return nil;
        pid = pid * 10 + (digit - '0');
    }
    if (!pid) return nil;
    NSString *name = [label substringFromIndex:NSMaxRange(separator)];
    if ([name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return name.length ? name : nil;
}

@implementation NativePreviewTransport
- (BOOL)openInterface {
    _usbInterfaceOwner = nil;
    phase_deadline(5);
    CFMutableDictionaryRef match = [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x04da
        productID:@0x2382 bcdDevice:nil interfaceNumber:@0 configurationValue:@1 interfaceClass:@6
        interfaceSubclass:@1 interfaceProtocol:@1 speed:nil productIDArray:nil];
    if (!match) { _error = @"Could not create the camera interface match."; return NO; }
    io_iterator_t iterator = IO_OBJECT_NULL;
    // IOUSBHostInterface.h documents a caller-owned dictionary. IOKit
    // consumes this reference whether or not the matching request succeeds.
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (status != KERN_SUCCESS) { _error = @"Could not inspect the camera interface."; return NO; }
    io_service_t selected = IO_OBJECT_NULL, entry;
    NSUInteger count = 0;
    while ((entry = IOIteratorNext(iterator))) {
        NSString *name = parent_product(entry, CFSTR("USB Product Name"));
        NSString *alternate = parent_product(entry, CFSTR("kUSBProductString"));
        BOOL modelOK = (name.length || alternate.length) &&
            (!name.length || [name isEqualToString:@"DC-S1H"]) &&
            (!alternate.length || [alternate isEqualToString:@"DC-S1H"]);
        if (modelOK) { ++count; if (selected) IOObjectRelease(selected); selected = entry; }
        else IOObjectRelease(entry);
    }
    BOOL valid = IOIteratorIsValid(iterator);
    IOObjectRelease(iterator);
    if (!valid || count != 1) {
        if (selected) IOObjectRelease(selected);
        _error = @"Connect exactly one DC-S1H in PC(Tether) mode; its registry identity must be readable.";
        return NO;
    }
    NSError *error = nil;
    dispatch_queue_t queue = dispatch_queue_create("local.s1h.experimental-preview.io", DISPATCH_QUEUE_SERIAL);
    id speed = CFBridgingRelease(IORegistryEntrySearchCFProperty(selected, kIOServicePlane, CFSTR("UsbLinkSpeed"),
        kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents));
    if ([speed isKindOfClass:NSNumber.class] && [speed longLongValue] > 0) _usbLinkSpeed = speed;
    _interface = [[IOUSBHostInterface alloc] initWithIOService:selected options:IOUSBHostObjectInitOptionsNone
        queue:queue error:&error interestHandler:nil];
    if (!_interface) {
        // Only this exact PTP interface's exclusive owner can explain the
        // failure. A parent device client does not imply interface ownership.
        id owner = CFBridgingRelease(IORegistryEntryCreateCFProperty(selected, CFSTR("UsbExclusiveOwner"),
            kCFAllocatorDefault, 0));
        _usbInterfaceOwner = interface_owner_name(owner);
    }
    IOObjectRelease(selected);
    if (!_interface) {
        show_error("Open S1H interface without seizure", error);
        _error = @"Camera interface unavailable. Close other camera/import software first.";
        return NO;
    }
    _output = [_interface copyPipeWithAddress:0x01 error:&error];
    _input = [_interface copyPipeWithAddress:0x82 error:&error];
    if (!_input || !_output) {
        show_error("Open native bulk pipes", error);
        _error = @"Camera bulk endpoints are unavailable.";
        return NO;
    }
    _reader = [PreviewReader new];
    __weak NativePreviewTransport *weakSelf = self;
    _reader.readChunk = ^NSData *{
        NativePreviewTransport *transport = weakSelf;
        if (!transport) return nil;
        /* A completed transfer's trailing USB zero-length packet can be
         * delivered separately. Skip only successful ZLPs, with a small
         * count bound and without extending the transaction deadline. */
        for (unsigned zlp = 0; zlp < 4; ++zlp) {
            double remaining = transport.transactionDeadline - monotonic_seconds();
            if (remaining <= 0) { transport.error = @"PTP transaction deadline exceeded."; return nil; }
            NSMutableData *buffer = make_buffer(transport.interface, READ_CAPACITY, YES);
            if (!buffer) { transport.error = @"Native DMA input allocation failed."; return nil; }
            NSUInteger actual = 0;
            double responseTimeout = transport.responseTimeout > 0 ? transport.responseTimeout : IO_TIMEOUT;
            BOOL ok = transfer_timed(transport.input, buffer, "PTP bulk IN", &actual, NULL,
                MIN(responseTimeout, remaining), MIN(responseTimeout + 0.5, remaining), NULL, transport.verbose);
            if (!ok) { transport.error = @"Native bulk IN failed or timed out."; return nil; }
            if (actual) return [NSData dataWithBytes:buffer.bytes length:actual];
            printf("Skipping successful bulk IN zero-length packet within the existing transaction deadline.\n");
        }
        transport.error = @"Native bulk IN exceeded its zero-length-packet limit.";
        return nil;
    };
    _synchronized = YES;
    return YES;
}
- (BOOL)drain {
    phase_deadline(4);
    if (!drain_input(_interface, _input, YES)) { _error = @"Pending input could not be safely drained."; return NO; }
    return YES;
}
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters dataExpected:(BOOL)expected {
    return [self request:opcode parameters:parameters dataExpected:expected dataOut:nil];
}
- (PreviewReply *)setPreviewFormat:(NSDictionary *)format {
    NSData *payload = pack_preview_format(format);
    if (!payload) { _error = @"Refused an invalid preview format record."; return nil; }
    return [self request:0x9415 parameters:@[@0x0d800011] dataExpected:NO dataOut:payload];
}
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters dataExpected:(BOOL)expected dataOut:(NSData *)dataOut {
    BOOL allowed = dataOut ? (!expected && (format_data_allowed(opcode, parameters, dataOut) ||
        (_interactiveEnabled && (s1h_control_data_allowed(opcode, parameters, dataOut) ||
                                 s1h_focus_data_allowed(opcode, parameters, dataOut))) ||
         (_controlReadEnabled && s1h_capture_target_data_allowed(opcode, parameters, dataOut)))) :
        (opcode_allowed(opcode, parameters) || (_controlReadEnabled && expected &&
         (s1h_control_read_allowed(opcode, parameters) || s1h_storage_inspection_allowed(opcode, parameters) ||
          s1h_battery_read_allowed(opcode, parameters))) ||
         (_interactiveEnabled && (expected == (opcode != 0x9404) && s1h_capture_request_allowed(opcode, parameters))) ||
         (_interactiveEnabled && !expected && s1h_vendor_session_allowed(opcode, parameters)));
    if (!_synchronized || !allowed) {
        _error = @"Refused an unsafe opcode or an unsynchronized transaction.";
        return nil;
    }
    _error = nil;
    double budget = _transactionBudget > 0 ? _transactionBudget : 5.0;
    _transactionDeadline = monotonic_seconds() + budget;
    phase_deadline(budget + 1.0);
    uint32_t transaction = _nextTransaction++;
    NSMutableData *command = make_buffer(_interface, 12 + parameters.count * 4, YES);
    if (!command) { _error = @"Native DMA command allocation failed."; return nil; }
    unsigned char *bytes = command.mutableBytes;
    write32(bytes, (uint32_t)command.length);
    write16(bytes + 4, 1); write16(bytes + 6, opcode); write32(bytes + 8, transaction);
    for (NSUInteger i = 0; i < parameters.count; ++i) write32(bytes + 12 + i * 4, parameters[i].unsignedIntValue);
    NSMutableData *outBuffer = nil;
    if (dataOut) {
        outBuffer = make_buffer(_interface, 12 + dataOut.length, YES);
        if (!write_data_container(outBuffer, dataOut, opcode, transaction)) {
            _error = @"Could not encode the PTP data container into a native DMA buffer.";
            return nil;
        }
    }
    if (_verbose || opcode != 0x9706) printf("PTP request opcode=0x%04x tx=%u\n", opcode, transaction);
    _synchronized = NO;
    NSUInteger actual = 0;
    double remaining = _transactionDeadline - monotonic_seconds();
    if (remaining <= 0 || !transfer_timed(_output, command, "preview bulk OUT", &actual, NULL,
            MIN(IO_TIMEOUT, remaining), MIN(IO_TIMEOUT + 0.5, remaining), NULL, _verbose) || actual != command.length) {
        _error = @"Native bulk OUT failed or timed out; no further PTP command will be sent.";
        return nil;
    }
    if (outBuffer) {
        actual = 0;
        remaining = _transactionDeadline - monotonic_seconds();
        if (remaining <= 0 || !transfer_timed(_output, outBuffer, "PTP data OUT", &actual, NULL,
                MIN(IO_TIMEOUT, remaining), MIN(IO_TIMEOUT + 0.5, remaining), NULL, _verbose) || actual != outBuffer.length) {
            _error = @"PTP data OUT failed or timed out; the outcome is unknown.";
            return nil;
        }
    }
    NSData *data = nil;
    for (unsigned containers = 0; containers < 6; ++containers) {
        PreviewContainer *container = [_reader container];
        if (!container) { _error = _error ?: _reader.error; return nil; }
        if (container.type == 4) continue; /* Complete unsolicited event consumed without logging payload. */
        if (container.transaction != transaction) {
            _error = @"Received a stale or mismatched PTP transaction; refusing a false match.";
            return nil;
        }
        if (container.type == 2) {
            if (!expected || data || container.code != opcode) { _error = @"Unexpected PTP data container."; return nil; }
            data = container.payload;
            continue;
        }
        if (container.type != 3 || container.payload.length % 4) { _error = @"Unexpected PTP response container or parameter width."; return nil; }
        _synchronized = YES;
        PreviewReply *reply = [PreviewReply new]; reply.code = container.code; reply.data = data;
        NSMutableArray *responseParameters = [NSMutableArray array];
        for (NSUInteger offset = 0; offset < container.payload.length; offset += 4)
            [responseParameters addObject:@(read32((const unsigned char *)container.payload.bytes + offset))];
        reply.parameters = responseParameters;
        if (container.code == 0x2001 && expected && !data) {
            _error = @"Camera returned OK without the required data phase.";
            return nil;
        }
        if (_verbose || opcode != 0x9706 || reply.code != 0x2001)
            printf("PTP response tx=%u code=0x%04x data_bytes=%lu\n", transaction, reply.code, (unsigned long)data.length);
        return reply;
    }
    _error = @"PTP response container limit exceeded.";
    return nil;
}
- (NSDictionary *)readCaptureEvent:(NSTimeInterval)timeout error:(NSString **)error {
    if (error) *error = nil;
    if (!_interactiveEnabled || !_synchronized || timeout <= 0 || timeout > 2) {
        if (error) *error = @"Capture event read is unavailable outside a synchronized interactive session.";
        return nil;
    }
    if (!_events) {
        NSError *pipeError = nil;
        _events = [_interface copyPipeWithAddress:0x83 error:&pipeError];
        if (!_events) { if (error) *error = @"Camera interrupt event endpoint is unavailable."; return nil; }
        _eventPending = [NSMutableData data]; _eventQueue = [NSMutableArray array];
    }
    double deadline = monotonic_seconds() + timeout;
    phase_deadline(timeout + 1.0);
    while (YES) {
        if (StopRequested) return nil;
        if (_eventQueue.count) { NSDictionary *event = _eventQueue.firstObject; [_eventQueue removeObjectAtIndex:0]; return event; }
        double now = monotonic_seconds();
        if (_eventFragmentDeadline && now >= _eventFragmentDeadline) {
            if (error) *error = @"A fragmented capture event did not complete before its deadline.";
            return nil;
        }
        double remaining = (_eventFragmentDeadline ? MIN(deadline, _eventFragmentDeadline) : deadline) - now;
        if (remaining <= 0) return nil;
        if (!_eventRead) {
            PreviewInterruptRead *read = [PreviewInterruptRead new];
            read.buffer = make_buffer(_interface, 64, YES);
            read.complete = dispatch_semaphore_create(0);
            if (!read.buffer) { if (error) *error = @"Capture event DMA allocation failed."; return nil; }
            NSError *enqueueError = nil;
            /* IOUSBHost requires a zero device timeout for an interrupt pipe.
             * Keep one request pending across locally timed waits. */
            BOOL queued = [_events enqueueIORequestWithData:read.buffer completionTimeout:0 error:&enqueueError
                completionHandler:^(IOReturn result, NSUInteger count) {
                    read.result = result;
                    read.count = count;
                    dispatch_semaphore_signal(read.complete);
                }];
            if (!queued) {
                show_error("capture event IN", enqueueError);
                if (error) *error = @"Could not queue the camera interrupt read.";
                return nil;
            }
            _eventRead = read;
        }
        PreviewInterruptRead *read = _eventRead;
        // A local poll can end before the interrupt has supplied a complete
        // event. Keep both the in-flight read and the fragment across polls.
        if (dispatch_semaphore_wait(read.complete, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)))) continue;
        _eventRead = nil;
        if (read.result != kIOReturnSuccess) {
            if (error) *error = @"Capture interrupt I/O did not complete successfully.";
            return nil;
        }
        NSString *parseError = append_capture_events(_eventPending, _eventQueue, read.buffer, read.count,
                                                     monotonic_seconds(), &_eventFragmentDeadline);
        if (parseError) {
            if (error) *error = parseError;
            return nil;
        }
    }
}
- (void)closeInterface {
    phase_deadline(3);
    [_input abortWithOption:IOUSBHostAbortOptionAsynchronous error:NULL];
    [_output abortWithOption:IOUSBHostAbortOptionAsynchronous error:NULL];
    [_events abortWithOption:IOUSBHostAbortOptionAsynchronous error:NULL];
    [_interface destroy];
    _reader = nil; _input = nil; _output = nil; _events = nil; _eventRead = nil;
    _eventPending = nil; _eventQueue = nil; _interface = nil;
    _eventFragmentDeadline = 0;
}
@end

#include "S1HNativeCapture.inc"

static BOOL skip_bytes(NSData *data, NSUInteger *offset, NSUInteger length) {
    if (*offset > data.length || length > data.length - *offset) return NO;
    *offset += length; return YES;
}
static NSString *ptp_string(NSData *data, NSUInteger *offset) {
    if (*offset >= data.length) return nil;
    const unsigned char *bytes = data.bytes;
    NSUInteger count = bytes[(*offset)++];
    if (!count) return @"";
    NSUInteger start = *offset;
    if (!skip_bytes(data, offset, count * 2) || read16(bytes + *offset - 2) != 0) return nil;
    return [[NSString alloc] initWithBytes:bytes + start length:(count - 1) * 2 encoding:NSUTF16LittleEndianStringEncoding];
}
static NSDictionary *parse_device_capabilities(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (data.length < 8 || read32(bytes + 2) != 0x1c) return nil;
    NSUInteger offset = 8;
    if (!ptp_string(data, &offset) || !skip_bytes(data, &offset, 2)) return nil;
    NSArray<NSString *> *inventoryKeys = @[@"operations", @"events", @"properties"];
    NSMutableDictionary *capabilities = [NSMutableDictionary dictionary];
    for (unsigned list = 0; list < 5; ++list) {
        NSUInteger countOffset = offset;
        if (!skip_bytes(data, &offset, 4)) return nil;
        uint32_t count = read32(bytes + countOffset);
        NSUInteger valuesOffset = offset;
        if (count > 4096 || !skip_bytes(data, &offset, (NSUInteger)count * 2)) return nil;
        if (list < inventoryKeys.count) {
            NSMutableArray<NSNumber *> *codes = [NSMutableArray arrayWithCapacity:count];
            for (uint32_t index = 0; index < count; ++index)
                [codes addObject:@(read16(bytes + valuesOffset + (NSUInteger)index * 2))];
            capabilities[inventoryKeys[list]] = codes;
        }
    }
    if (!ptp_string(data, &offset)) return nil; /* manufacturer; not stored */
    NSString *model = ptp_string(data, &offset);
    /* Never parse the device version or serial fields. */
    if (![model isEqualToString:@"DC-S1H"]) return nil;
    capabilities[@"model"] = model;
    return capabilities;
}

static BOOL s1h_is_percent_battery_descriptor(NSData *data) {
    // ISO 15740 §13.5.1 permits a device-defined UINT8 scale. Display a
    // percentage only when the descriptor explicitly spans 0 to 100.
    if (data.length < 8) return NO;
    const unsigned char *bytes = data.bytes;
    if (read16(bytes) != S1HBatteryProperty || read16(bytes + 2) != 0x0002 ||
        bytes[4] != 0 || bytes[5] > 100 || bytes[6] > 100) return NO;
    if (bytes[7] == 1)
        return data.length == 11 && bytes[8] == 0 && bytes[9] == 100 && bytes[10] > 0 && bytes[10] <= 100;
    if (bytes[7] != 2 || data.length < 10) return NO;
    uint16_t count = read16(bytes + 8);
    if (count < 2 || count > 101 || data.length != (NSUInteger)count + 10) return NO;
    BOOL present[101] = {NO};
    for (uint16_t index = 0; index < count; ++index) {
        unsigned char value = bytes[10 + index];
        if (value > 100 || present[value]) return NO;
        present[value] = YES;
    }
    return present[0] && present[100];
}

static NSNumber *s1h_read_battery_percent(NativePreviewTransport *transport, NSDictionary *capabilities) {
    NSArray *operations = capabilities[@"operations"];
    if (StopRequested || !transport.synchronized ||
        ![operations containsObject:@(S1HBatteryDescriptorOpcode)] || ![operations containsObject:@(S1HBatteryValueOpcode)] ||
        ![capabilities[@"properties"] containsObject:@(S1HBatteryProperty)]) return nil;
    NSArray<NSNumber *> *parameters = @[@(S1HBatteryProperty)];
    double previousBudget = transport.transactionBudget;
    transport.transactionBudget = 1.0;
    PreviewReply *descriptor = [transport request:S1HBatteryDescriptorOpcode parameters:parameters dataExpected:YES];
    PreviewReply *value = nil;
    if (descriptor.code == 0x2001 && s1h_is_percent_battery_descriptor(descriptor.data) &&
        transport.synchronized && !StopRequested)
        value = [transport request:S1HBatteryValueOpcode parameters:parameters dataExpected:YES];
    transport.transactionBudget = previousBudget;
    if (value.code != 0x2001 || value.data.length != 1) return nil;
    const unsigned char *bytes = value.data.bytes;
    return bytes[0] <= 100 ? @(bytes[0]) : nil;
}

static NSArray<NSDictionary *> *read_available_formats(NativePreviewTransport *transport, NSString **error) {
    PreviewReply *reply = [transport request:0x9414 parameters:@[@0x0d800012] dataExpected:YES];
    if (!reply || reply.code != 0x2001) {
        if (error) *error = transport.error ?: @"Camera did not return its preview format list.";
        return nil;
    }
    return parse_available_formats(reply.data, error);
}
static NSDictionary *read_current_preview_format(NativePreviewTransport *transport, NSString **error) {
    PreviewReply *reply = [transport request:0x9414 parameters:@[@0x0d800011] dataExpected:YES];
    if (!reply || reply.code != 0x2001) {
        if (error) *error = transport.error ?: @"Camera did not return its current preview format.";
        return nil;
    }
    return parse_current_format(reply.data, error);
}
static void prepare_format_cleanup_transaction(NativePreviewTransport *transport) {
    /* At most one pre-cancellation five-second transaction can be in flight.
     * Four subsequent cleanup transactions get <=0.9s each, keeping the
     * existing ten-second cancellation watchdog and GUI deadline meaningful. */
    transport.transactionBudget = StopRequested ? 0.9 : 5.0;
}

/* Independent JPEG marker walker. Skip metadata segments by their lengths;
 * entropy byte stuffing and restart markers cannot terminate the JPEG early. */
static NSUInteger jpeg_end(const unsigned char *b, NSUInteger n, NSUInteger start) {
    NSUInteger p = start + 2;
    BOOL entropy = NO;
    while (p < n) {
        if (entropy) {
            while (p < n && b[p] != 0xff) ++p;
            if (p + 1 >= n) return NSNotFound;
            NSUInteger q = p + 1;
            while (q < n && b[q] == 0xff) ++q;
            if (q == n) return NSNotFound;
            unsigned char m = b[q];
            if (m == 0 || (m >= 0xd0 && m <= 0xd7)) { p = q + 1; continue; }
            entropy = NO;
        }
        if (p >= n || b[p] != 0xff) return NSNotFound;
        while (p < n && b[p] == 0xff) ++p;
        if (p >= n) return NSNotFound;
        unsigned char marker = b[p++];
        if (marker == 0xd9) return p;
        if (marker == 0xd8 || marker == 0) return NSNotFound;
        if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (p + 2 > n) return NSNotFound;
        NSUInteger length = ((NSUInteger)b[p] << 8) | b[p + 1];
        if (length < 2 || length > n - p) return NSNotFound;
        p += length;
        if (marker == 0xda) entropy = YES;
    }
    return NSNotFound;
}
static NSData *validated_preview_jpeg(NSData *payload, NSUInteger *widthOut, NSUInteger *heightOut) {
    const unsigned char *bytes = payload.bytes;
    NSData *best = nil;
    NSUInteger bestWidth = 0, bestHeight = 0, candidates = 0;
    for (NSUInteger i = 0; i + 1 < payload.length && candidates < 32; ++i) {
        if (bytes[i] != 0xff || bytes[i + 1] != 0xd8) continue;
        ++candidates;
        NSUInteger end = jpeg_end(bytes, payload.length, i);
        if (end == NSNotFound) continue;
        NSData *jpeg = [payload subdataWithRange:NSMakeRange(i, end - i)];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
        if (!source) continue;
        CFStringRef type = CGImageSourceGetType(source);
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        BOOL plausible = type && CFEqual(type, CFSTR("public.jpeg")) && width > 0 && height > 0 &&
            width <= 8192 && height <= 8192 && width * height <= 32000000 &&
            CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
        CGImageRef image = plausible ? CGImageSourceCreateImageAtIndex(source, 0,
            (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @YES,
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES}) : NULL;
        if (image && width * height > bestWidth * bestHeight) { best = jpeg; bestWidth = width; bestHeight = height; }
        if (image) CGImageRelease(image);
        CFRelease(source);
    }
    if (best) { if (widthOut) *widthOut = bestWidth; if (heightOut) *heightOut = bestHeight; }
    return best;
}

static void bounded_pause(double seconds) {
    /* An intentional low-frame-rate pause is bounded too, but is not an
     * I/O stall. Cancellation retains its separate ten-second watchdog. */
    phase_deadline(MAX(1.0, seconds + 1.0));
    double end = monotonic_seconds() + seconds;
    while (!StopRequested && monotonic_seconds() < end) {
        double delay = MIN(0.01, end - monotonic_seconds());
        if (delay > 0) usleep((useconds_t)(delay * 1e6));
    }
}

enum { ActionLineLimit = 4096, ActionSessionLimit = 4096 };

static NSNumber *parse_capture_target(NSData *data) {
    if (data.length != 10) return nil;
    const unsigned char *bytes = data.bytes;
    uint16_t target = read16(bytes + 8);
    return read32(bytes) == 0x08000091 && read32(bytes + 4) == 2 && target <= 2 ? @(target) : nil;
}

static NSNumber *read_capture_target(NativePreviewTransport *transport) {
    PreviewReply *reply = [transport request:0x940a parameters:@[@0x08000090] dataExpected:YES];
    return reply.code == 0x2001 ? parse_capture_target(reply.data) : nil;
}

static NSArray<NSNumber *> *read_capture_storage_ids(NativePreviewTransport *transport) {
    PreviewReply *reply = [transport request:0x1004 parameters:@[] dataExpected:YES];
    return reply.code == 0x2001 ? s1h_capture_handles(reply.data) : nil;
}

static BOOL has_logical_capture_storage(NSArray<NSNumber *> *ids) {
    for (NSNumber *storageID in ids)
        if (storageID.unsignedIntValue & 0xffff) return YES;
    return NO;
}

static NSData *capture_target_data(NSNumber *target) {
    unsigned char bytes[10];
    write32(bytes, 0x08000091);
    write32(bytes + 4, 2);
    write16(bytes + 8, target.unsignedShortValue);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

static BOOL set_capture_target(NativePreviewTransport *transport, NSNumber *target) {
    NSData *data = capture_target_data(target);
    PreviewReply *reply = [transport request:0x940b parameters:@[@0x08000091] dataExpected:NO dataOut:data];
    if (reply.code == 0x201d && !StopRequested)
        reply = [transport request:0x940b parameters:@[@0] dataExpected:NO dataOut:data];
    return reply.code == 0x2001 && [read_capture_target(transport) isEqual:target];
}

static NSDictionary *inspect_capture_storage(NativePreviewTransport *transport) {
    NSMutableDictionary *storage = [NSMutableDictionary dictionary];
    if (!transport.synchronized || StopRequested) return storage;
    PreviewReply *target = [transport request:0x940a parameters:@[@0x08000090] dataExpected:YES];
    if (target) storage[@"target_response"] = @(target.code);
    if (target.code == 0x2001) {
        NSNumber *value = parse_capture_target(target.data);
        if (value) storage[@"target"] = value;
    }
    if (!transport.synchronized || StopRequested) return storage;
    PreviewReply *ids = [transport request:0x1004 parameters:@[] dataExpected:YES];
    if (ids) storage[@"ids_response"] = @(ids.code);
    if (ids.code == 0x2001) {
        NSArray *handles = s1h_capture_handles(ids.data);
        if (handles) {
            storage[@"storage_count"] = @(handles.count);
            storage[@"storage_ids"] = handles;
            storage[@"logical_card_available"] = @(has_logical_capture_storage(handles));
        }
    }
    return storage;
}

static NSDictionary *change_body_capture_target(NativePreviewTransport *transport, NSNumber *target,
                                               NSDictionary **storage) {
    NSDictionary *before = inspect_capture_storage(transport);
    *storage = before;
    NSNumber *current = before[@"target"];
    if (!current || StopRequested || !transport.synchronized)
        return @{@"status":@"rejected", @"message":@"Could not confirm the camera's current storage target."};
    if (![target isEqual:@1] && ![before[@"logical_card_available"] boolValue])
        return @{@"status":@"rejected", @"message":@"The camera did not report an active memory card."};
    if ([current isEqual:target])
        return @{@"status":@"ok", @"message":@"The camera storage target already matches the selection."};

    // The explicit setting never retries the write. Show only a read-back
    // confirmation even if the camera's write response was successful.
    PreviewReply *reply = [transport request:0x940b parameters:@[@0x08000091]
                                 dataExpected:NO dataOut:capture_target_data(target)];
    NSMutableDictionary *after = [before mutableCopy];
    [after removeObjectForKey:@"target"];
    [after removeObjectForKey:@"target_response"];
    *storage = after;
    NSNumber *observed = reply && transport.synchronized && !StopRequested ? read_capture_target(transport) : nil;
    if (!observed)
        return @{@"status":@"outcome_unknown", @"message":@"The camera storage target could not be confirmed after the write."};
    after[@"target"] = observed;
    after[@"target_response"] = @0x2001;
    if (reply.code != 0x2001)
        return @{@"status":@"error", @"message":[NSString stringWithFormat:@"Camera declined the storage target with response 0x%04X.", reply.code]};
    if (![observed isEqual:target])
        return @{@"status":@"error", @"message":@"The camera reported a different storage target after the write."};
    return @{@"status":@"ok", @"message":@"Camera storage target changed and verified."};
}

/* Only this worker thread reads requests or touches the PTP session. */
static NSDictionary *next_interactive_action(NSMutableData *pending, BOOL *ended, NSString **error) {
    const unsigned char *newline = pending.length ? memchr(pending.bytes, '\n', pending.length) : NULL;
    if (!newline && !*ended && pending.length <= ActionLineLimit) {
        unsigned char chunk[ActionLineLimit];
        ssize_t bytes = read(STDIN_FILENO, chunk, sizeof chunk);
        if (bytes > 0) {
            [pending appendBytes:chunk length:(NSUInteger)bytes];
            newline = memchr(pending.bytes, '\n', pending.length);
        } else if (bytes == 0) {
            *ended = YES;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            *error = @"The camera action pipe could not be read.";
            return nil;
        }
    }
    NSUInteger length = newline ? (NSUInteger)(newline - (const unsigned char *)pending.bytes) : pending.length;
    if (length > ActionLineLimit || (*ended && !newline && length)) {
        *error = @"A camera action exceeded its line limit or was interrupted.";
        return nil;
    }
    if (!newline) return nil;
    NSData *line = [pending subdataWithRange:NSMakeRange(0, length)];
    [pending replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
    id json = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"id"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:json[@"id"]]) {
        *error = @"The camera action pipe received an invalid request.";
        return nil;
    }
    return json;
}

static BOOL publish_action(PreviewStatus *status, NSString *actionID, NSDictionary *result) {
    NSMutableDictionary *actionStatus = [result mutableCopy];
    actionStatus[@"id"] = actionID;
    status.actionStatus = actionStatus;
    return [status update:@"previewing" message:@"Native USB preview is running."];
}

static NSString *perform_interactive_action(NSDictionary *action, PreviewStatus *status,
        NativePreviewTransport *transport, PreviewOptions *options, NSMutableSet<NSUUID *> *completedActions) {
    NSString *actionID = action[@"id"];
    NSUUID *request = [[NSUUID alloc] initWithUUIDString:actionID];
    if ([completedActions containsObject:request]) return nil;
    if (completedActions.count >= ActionSessionLimit) return @"The camera session has reached its action limit. Reconnect before sending more actions.";
    [completedActions addObject:request];

    NSString *kind = [action[@"action"] isKindOfClass:NSString.class] ? action[@"action"] : @"";
    NSString *directory = [action[@"directory"] isKindOfClass:NSString.class] ? action[@"directory"] : nil;
    NSString *target = action[@"target"] ?: @"current";
    NSString *property = [action[@"property"] isKindOfClass:NSString.class] ? action[@"property"] : nil;
    NSNumber *value = [action[@"value"] isKindOfClass:NSNumber.class] ? action[@"value"] : nil;
    BOOL capture = [kind isEqualToString:@"capture"];
    BOOL set = [kind isEqualToString:@"set"];
    BOOL refresh = [kind isEqualToString:@"refresh"];
    BOOL setDirectory = [kind isEqualToString:@"set_camera_save_dir"];
    BOOL setPrefix = [kind isEqualToString:@"set_photo_name_prefix"];
    BOOL setBodyTarget = [kind isEqualToString:@"set_body_capture_target"];
    BOOL focus = [kind isEqualToString:@"focus_step"];
    NSNumber *bodyTarget = setBodyTarget && [target isKindOfClass:NSString.class] ?
        @{@"card":@0, @"mac":@1, @"card_and_mac":@2}[target] : nil;
    NSString *prefix = [action[@"prefix"] isKindOfClass:NSString.class] ? action[@"prefix"] : nil;
    if ((capture && (!status.captureAvailable || !directory.isAbsolutePath ||
                     ![@[@"current", @"mac", @"card_and_mac"] containsObject:target])) ||
        (set && (!property || !value || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())) ||
        (setDirectory && !directory.isAbsolutePath) || (setPrefix && !s1h_photo_prefix_valid(prefix)) ||
        (setBodyTarget && !bodyTarget) || (focus && ![@[@"a", @"b"] containsObject:action[@"direction"] ?: NSNull.null]) ||
        (!capture && !set && !refresh && !setDirectory && !setPrefix && !setBodyTarget && !focus)) {
        BOOL published = publish_action(status, actionID,
            @{@"status": @"rejected", @"message": @"The requested action, photo directory or name prefix is unavailable."});
        return published ? nil : status.writeError;
    }

    status.captureAvailable = NO;
    NSDictionary *preparing = capture ? s1h_capture_busy(@"preparing", @"Preparing camera action.") :
        @{@"status": @"busy", @"message": @"Preparing camera action."};
    if (!publish_action(status, actionID, preparing)) return status.writeError;
    NSDictionary *result;
    if (capture) {
        NSNumber *requestedTarget = @{@"mac": @1, @"card_and_mac": @2}[target];
        NSNumber *originalTarget = !StopRequested ? read_capture_target(transport) : nil;
        NSNumber *effectiveTarget = requestedTarget ?: originalTarget;
        BOOL usesCard = [effectiveTarget isEqual:@0] || [effectiveTarget isEqual:@2];
        NSArray<NSNumber *> *storageIDs = nil;
        if (!StopRequested && transport.synchronized && usesCard)
            storageIDs = read_capture_storage_ids(transport);
        BOOL targetChange = NO;
        if ((requestedTarget && !originalTarget) || StopRequested || !transport.synchronized) {
            result = s1h_capture_result(@"rejected", @"Could not confirm the camera's original storage destination. No photo requested.", NO, @[]);
        } else if (usesCard && !storageIDs) {
            result = s1h_capture_result(@"rejected", @"Could not confirm card storage. No photo requested.", NO, @[]);
        } else if (usesCard && !has_logical_capture_storage(storageIDs)) {
            result = s1h_capture_result(@"rejected", @"The camera reported no active card storage. No photo requested.", NO, @[]);
        } else {
            targetChange = requestedTarget && ![originalTarget isEqual:requestedTarget];
            if (targetChange && !set_capture_target(transport, requestedTarget)) {
                result = s1h_capture_result(@"rejected", @"Camera did not confirm the selected storage destination. No photo requested.", NO, @[]);
            } else {
                /* Quiesce preview requests during still capture. Keep the
                 * camera's live mode enabled for the shutter command. */
                result = s1h_capture_once(transport, directory, options.photoNamePrefix, ^(NSDictionary *update) {
                    if (!publish_action(status, actionID, update)) StopRequested = 1;
                });
            }
        }
        status.requiresReview = ![result[@"safe_to_resume"] boolValue];
        if (targetChange) {
            NSNumber *current = !status.requiresReview && !StopRequested && transport.synchronized ? read_capture_target(transport) : nil;
            BOOL restored = current && ([current isEqual:originalTarget] || set_capture_target(transport, originalTarget));
            NSMutableDictionary *withTarget = [result mutableCopy];
            withTarget[@"original_target_restored"] = @(restored);
            if (!restored) {
                status.requiresReview = YES;
                withTarget[@"status"] = @"outcome_unknown";
                withTarget[@"message"] = [result[@"message"] stringByAppendingString:@" The original camera storage destination could not be confirmed; reconnect only after checking the camera."];
            }
            result = withTarget;
        }
    } else if (focus) {
        result = s1h_focus_jog(transport, action[@"direction"]);
        if ([result[@"status"] isEqual:@"outcome_unknown"]) status.requiresReview = YES;
    } else if (setDirectory) {
        options.cameraSaveDirectory = directory;
        result = @{@"status": @"ok", @"message": @"Camera photo save folder updated."};
    } else if (setPrefix) {
        options.photoNamePrefix = prefix;
        result = @{@"status": @"ok", @"message": @"Photo filename prefix updated."};
    } else if (setBodyTarget) {
        NSString *directoryError = nil;
        BOOL needsMacFolder = ![bodyTarget isEqual:@0];
        int saveDirectoryFD = needsMacFolder ? s1h_capture_directory(options.cameraSaveDirectory, NULL, &directoryError) : -1;
        if (saveDirectoryFD >= 0) close(saveDirectoryFD);
        if (needsMacFolder && saveDirectoryFD < 0) {
            result = @{@"status":@"rejected", @"message":directoryError ?: @"The photo save folder is unavailable."};
        } else {
            NSDictionary *observedStorage = nil;
            result = change_body_capture_target(transport, bodyTarget, &observedStorage);
            status.captureStorage = observedStorage;
            if ([result[@"status"] isEqual:@"outcome_unknown"]) status.requiresReview = YES;
        }
    } else if (set) {
        NSDictionary *updatedControls = nil;
        result = s1h_control_set(transport, property, value, &updatedControls);
        NSMutableDictionary *controls = [status.controls mutableCopy] ?: [NSMutableDictionary dictionary];
        [controls addEntriesFromDictionary:updatedControls ?: @{}];
        status.controls = controls;
    } else {
        status.controls = s1h_controls_refresh(transport);
        status.captureStorage = inspect_capture_storage(transport);
        status.batteryPercent = s1h_read_battery_percent(transport, status.deviceCapabilities);
        result = transport.synchronized ? @{@"status": @"ok", @"message": @"Camera settings refreshed."} :
            @{@"status": @"error", @"message": @"The camera settings could not be read completely."};
    }
    if (!publish_action(status, actionID, result)) return status.writeError;
    if (status.requiresReview) return @"Check the camera and saved files before reconnecting.";
    if (!transport.synchronized) return transport.error ?: @"The camera session lost its transaction boundary.";
    return nil;
}

static BOOL publish_camera_transfer(PreviewStatus *status, NSString *identifier, NSString *directory, NSDictionary *result) {
    NSMutableDictionary *transfer = [result mutableCopy];
    transfer[@"id"] = identifier;
    transfer[@"directory"] = directory;
    status.cameraTransfer = transfer;
    return [status update:@"previewing" message:@"Native USB preview is running."];
}

static NSString *poll_camera_transfer(PreviewStatus *status, NativePreviewTransport *transport, PreviewOptions *options) {
    NSString *directory = options.cameraSaveDirectory;
    if (!directory || StopRequested) return nil;
    NSString *eventError = nil;
    NSDictionary *event = [transport readCaptureEvent:0.002 error:&eventError];
    if (eventError) return eventError;
    if (!s1h_camera_event_starts_transfer(event)) return nil;
    // A card object already has its chosen destination. Still recover any
    // reported SDRAM object, which may have no other copy.
    if ([status.captureStorage[@"target"] isEqual:@0] && [event[@"code"] isEqual:@0xc108]) return nil;

    NSString *identifier = NSUUID.UUID.UUIDString;
    status.captureAvailable = NO;
    if (!publish_camera_transfer(status, identifier, directory, s1h_capture_busy(@"preparing", @"Receiving photo from camera shutter.")))
        return status.writeError;
    NSDictionary *result = s1h_capture_from_camera_event(transport, directory, options.photoNamePrefix, event, ^(NSDictionary *update) {
        if (!publish_camera_transfer(status, identifier, directory, update)) StopRequested = 1;
    });
    status.requiresReview = ![result[@"safe_to_resume"] boolValue];
    if (!publish_camera_transfer(status, identifier, directory, result)) return status.writeError;
    if (status.requiresReview) return @"Check the camera and saved files before reconnecting.";
    return transport.synchronized ? nil : transport.error ?: @"The camera session lost its transaction boundary.";
}

static int run_preview(PreviewOptions *options) {
    if (!keep_preview_format_valid(options.keepPreviewFormat, options.previewFormat)) {
        fprintf(stderr, "Explicit preview-format selection requires --keep-preview-format; auto forbids it.\n");
        return 2;
    }
    if (options.inspectControls && (![options.previewFormat isEqualToString:@"auto"] || options.keepPreviewFormat)) return 2;
    if (options.interactive) {
        struct stat inputStatus;
        int flags = fcntl(STDIN_FILENO, F_GETFL);
        if (fstat(STDIN_FILENO, &inputStatus) != 0 || !S_ISFIFO(inputStatus.st_mode) ||
            flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0) {
            fprintf(stderr, "Interactive camera actions require a readable stdin pipe.\n"); return 2;
        }
    }
    phase_deadline(5);
    NSError *error = nil;
    NSURL *directory = [NSURL fileURLWithPath:options.output isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        fprintf(stderr, "Cannot create the output directory.\n"); return 1;
    }
    PreviewStatus *status = [PreviewStatus new]; status.directory = directory;
    if (![status update:@"starting" message:@"Starting experimental native USB preview."]) return 1;
    NativePreviewTransport *transport = [NativePreviewTransport new]; transport.verbose = options.verbose;
    transport.controlReadEnabled = options.inspectControls || options.interactive;
    transport.interactiveEnabled = options.interactive;
    BOOL sessionOpen = NO, vendorSessionOpen = NO, liveStarted = NO, clean = YES;
    BOOL formatRequested = options.previewFormat && ![options.previewFormat isEqualToString:@"auto"];
    BOOL formatWriteAttempted = NO, previewStartAttempted = NO, keptFormatConfirmed = NO;
    NSDictionary *originalFormat = nil, *selectedFormat = nil;
    if (formatRequested) status.formatMetadata = [@{@"requested_mode": options.previewFormat,
        @"keep_requested": @(options.keepPreviewFormat),
        @"restore_status": @"not_changed"} mutableCopy];
    NSString *failure = nil;
    [status update:@"connecting" message:@"Connecting to DC-S1H."];
    if (![transport openInterface]) {
        failure = transport.error;
        status.usbInterfaceOwner = transport.usbInterfaceOwner;
    }
    if (!failure) {
        status.usbLinkSpeed = transport.usbLinkSpeed;
        [status update:@"draining" message:@"Preparing the camera connection."];
        if (![transport drain]) failure = transport.error;
    }
    if (!failure && !StopRequested) {
        PreviewReply *reply = [transport request:0x1002 parameters:@[@1] dataExpected:NO];
        status.staleSession = reply.code == 0x201e;
        if (status.staleSession && options.closeStaleSession && !StopRequested) {
            PreviewReply *device = [transport request:0x1001 parameters:@[] dataExpected:YES];
            if (device.code == 0x2001 && parse_device_capabilities(device.data) && !StopRequested) {
                PreviewReply *closed = [transport request:0x1003 parameters:@[] dataExpected:NO];
                if (closed.code == 0x2001 && !StopRequested) {
                    transport.nextTransaction = 0;
                    reply = [transport request:0x1002 parameters:@[@1] dataExpected:NO];
                }
            }
        }
        sessionOpen = reply && reply.code == 0x2001;
        if (sessionOpen) status.staleSession = NO;
        if (!sessionOpen) failure = transport.error ?: (status.staleSession ?
            @"A PTP session remains open. Confirm the camera is idle before closing it." : @"Camera did not open a new standard PTP session.");
    }
    if (!failure && !StopRequested) {
        PreviewReply *reply = [transport request:0x1001 parameters:@[] dataExpected:YES];
        status.deviceCapabilities = reply.code == 0x2001 ? parse_device_capabilities(reply.data) : nil;
        if (!status.deviceCapabilities)
            failure = transport.error ?: @"DeviceInfo did not confirm a Panasonic DC-S1H.";
        else [status update:@"session_open" message:@"Connected to Panasonic DC-S1H."];
    }
    if (!failure && !StopRequested && options.interactive) {
        NSArray<NSNumber *> *storageIDs = read_capture_storage_ids(transport);
        if (storageIDs && !StopRequested) {
            /* DC-S1H accepts this session argument even when it reports
             * only physical slots. Card readiness is checked at capture. */
            PreviewReply *reply = [transport request:0x9102 parameters:@[@0x00010001] dataExpected:NO];
            vendorSessionOpen = reply.code == 0x2001;
            if (!vendorSessionOpen && transport.synchronized)
                printf("Camera refused Panasonic session setup; continuing with standard PTP.\n");
        }
        if (!transport.synchronized) failure = transport.error ?: @"The Panasonic tether session setup was interrupted.";
    }
    if (!failure && !StopRequested && (options.inspectControls || options.interactive)) {
        [status update:@"connecting" message:@"Reading camera-reported controls."];
        status.controls = s1h_controls_refresh(transport);
        if (!transport.synchronized) failure = transport.error ?: @"Control inspection lost its complete transaction boundary.";
        [status update:@"session_open" message:failure ?: @"Camera control inspection completed."];
    }
    if (!failure && !StopRequested && (options.inspectControls || options.interactive)) {
        if (options.inspectControls && options.explicitStorageTarget) {
            NSNumber *before = read_capture_target(transport);
            if (!before || (![before isEqual:options.explicitStorageTarget] &&
                            !set_capture_target(transport, options.explicitStorageTarget)))
                failure = transport.error ?: @"The requested camera storage destination could not be confirmed.";
        }
        status.captureStorage = inspect_capture_storage(transport);
        if (!transport.synchronized) failure = transport.error ?: @"Capture storage inspection was interrupted.";
        // The GUI runs the optional battery probe only on an explicit Refresh.
        // A transport failure here must not repeat on every automatic reconnect.
        if (!failure && !StopRequested && options.inspectControls) {
            status.batteryPercent = s1h_read_battery_percent(transport, status.deviceCapabilities);
            if (!transport.synchronized) failure = transport.error ?: @"Battery telemetry inspection was interrupted.";
        }
    }
    if (!failure && !StopRequested && formatRequested) {
        NSArray *formats = read_available_formats(transport, &failure);
        if (formats && !StopRequested) originalFormat = read_current_preview_format(transport, &failure);
        if (originalFormat && !StopRequested) selectedFormat = select_preview_format(formats, options.previewFormat, &failure);
        if (selectedFormat) {
            status.formatMetadata[@"original"] = originalFormat;
            status.formatMetadata[@"selected"] = selectedFormat;
            if (!StopRequested && !same_preview_format(originalFormat, selectedFormat)) {
                /* Set before any OUT submission: even a non-OK response does
                 * not prove that a requested setting remained unchanged. */
                formatWriteAttempted = YES;
                status.formatMetadata[@"restore_status"] = @"unknown";
                PreviewReply *reply = [transport setPreviewFormat:selectedFormat];
                if (!reply || reply.code != 0x2001)
                    failure = transport.error ?: @"Camera did not accept the selected preview format.";
            }
            if (!failure &&
                (formatWriteAttempted || same_preview_format(originalFormat, selectedFormat))) {
                NSDictionary *observed = originalFormat;
                if (formatWriteAttempted) {
                    if (StopRequested) prepare_format_cleanup_transaction(transport);
                    observed = read_current_preview_format(transport, &failure);
                }
                if (observed) status.formatMetadata[@"selected_readback"] = observed;
                keptFormatConfirmed = same_preview_format(selectedFormat, observed);
                if (!keptFormatConfirmed)
                    failure = failure ?: @"The requested retained preview format was not verified by read-back.";
                status.formatMetadata[@"restore_status"] = keptFormatConfirmed ? @"kept_by_request" : @"unknown";
            }
            printf("Requested preview format=%lux%lu x_raw=%lu frequency_raw=%lu; actual JPEG dimensions will be decoded separately.\n",
                (unsigned long)[selectedFormat[@"width"] unsignedIntegerValue],
                (unsigned long)[selectedFormat[@"height"] unsignedIntegerValue],
                (unsigned long)[selectedFormat[@"x_raw"] unsignedIntegerValue],
                (unsigned long)[selectedFormat[@"frequency_raw"] unsignedIntegerValue]);
            [status update:@"session_open" message:failure ?: @"Preparing the selected preview format."];
        }
    }
    if (!failure && !StopRequested && !options.inspectControls) {
        previewStartAttempted = YES;
        PreviewReply *reply = [transport request:0x9412 parameters:@[@0x0d000010] dataExpected:NO];
        liveStarted = reply && reply.code == 0x2001;
        if (!liveStarted) failure = transport.error ?: @"Camera did not enable preview mode.";
        else { status.previewStart = monotonic_seconds(); bounded_pause(0.1); }
    }
    NSMutableData *actionInput = options.interactive ? [NSMutableData data] : nil;
    NSMutableSet<NSUUID *> *completedActions = options.interactive ? [NSMutableSet set] : nil;
    BOOL actionInputEnded = NO;
    while (!failure && liveStarted && !StopRequested && status.frames < options.frames &&
           (options.duration <= 0 || monotonic_seconds() - status.previewStart < options.duration)) {
        @autoreleasepool {
            double frameStart = monotonic_seconds();
            if (options.interactive) failure = poll_camera_transfer(status, transport, options);
            if (failure || StopRequested) break;
            if (options.interactive && status.frames) {
                NSDictionary *action = next_interactive_action(actionInput, &actionInputEnded, &failure);
                if (action) failure = perform_interactive_action(action, status, transport, options, completedActions);
                if (failure || StopRequested || (actionInputEnded && !action)) break;
            }
            PreviewReply *reply = nil;
            unsigned busy = 0;
            double busyDeadline = monotonic_seconds() + (options.cameraSaveDirectory ? 120.0 : 0);
            do {
                reply = [transport request:0x9706 parameters:@[] dataExpected:YES];
                if (!reply || reply.code != 0x2019) break;
                if (options.cameraSaveDirectory) {
                    failure = poll_camera_transfer(status, transport, options);
                    if (failure || monotonic_seconds() >= busyDeadline) break;
                } else if (++busy >= 25) break;
                bounded_pause(0.04);
            } while (!StopRequested && (options.duration <= 0 || monotonic_seconds() - status.previewStart < options.duration));
            if (failure || StopRequested) break;
            /* A fully consumed DeviceBusy reply at the requested time limit
             * is a normal duration stop, not a failed preview frame. */
            if (reply && reply.code == 0x2019 && options.duration > 0 &&
                monotonic_seconds() - status.previewStart >= options.duration) break;
            if (!reply || reply.code != 0x2001) { failure = transport.error ?: @"Preview frame request failed or stayed busy."; break; }
            NSUInteger width = 0, height = 0;
            phase_deadline(5);
            NSData *jpeg = validated_preview_jpeg(reply.data, &width, &height);
            if (!jpeg) { failure = @"Preview response did not contain a complete decodable JPEG."; break; }
            status.captureAvailable = options.interactive;
            if (![status publish:jpeg width:width height:height]) { failure = status.writeError; break; }
            if (status.frames == 1 || status.frames % 10 == 0)
                printf("Preview frames=%lu dimensions=%lux%lu JPEG_bytes=%lu\n", (unsigned long)status.frames,
                    (unsigned long)width, (unsigned long)height, (unsigned long)jpeg.length);
            double wait = 1.0 / options.fps - (monotonic_seconds() - frameStart);
            if (options.duration > 0)
                wait = MIN(wait, MAX(0, options.duration - (monotonic_seconds() - status.previewStart)));
            if (wait > 0) bounded_pause(wait);
        }
    }
    [status update:@"stopping" message:@"Stopping native preview."];
    /* An interrupted/failed data phase must not be followed by blind OUT
     * requests. Clean shutdown sends preview-stop and close only when the
     * complete previous response was consumed on a known protocol boundary. */
    if (sessionOpen && transport.synchronized && !status.requiresReview) {
        if (liveStarted || (formatRequested && previewStartAttempted)) {
            prepare_format_cleanup_transaction(transport);
            PreviewReply *reply = [transport request:0x9412 parameters:@[@0x0d000011] dataExpected:NO];
            if (reply.code != 0x2001) clean = NO;
        }
        if (vendorSessionOpen && transport.synchronized) {
            prepare_format_cleanup_transaction(transport);
            PreviewReply *vendor = [transport request:0x9103 parameters:@[] dataExpected:NO];
            if (vendor.code != 0x2001) clean = NO;
        }
        if (transport.synchronized) {
            prepare_format_cleanup_transaction(transport);
            PreviewReply *reply = [transport request:0x1003 parameters:@[] dataExpected:NO];
            if (reply.code != 0x2001) clean = NO;
        } else clean = NO;
        if (formatWriteAttempted || keptFormatConfirmed) {
            if (!clean || !keptFormatConfirmed) {
                status.formatMetadata[@"restore_status"] = @"unknown";
                clean = NO;
            } else {
                printf("Verified preview format retained by explicit request; no restoration command sent.\n");
            }
        }
    } else if (sessionOpen || !transport.synchronized) {
        /* An incomplete OpenSession can have reached the camera even if its
         * reply was not consumed. Do not claim a clean shutdown or send a
         * speculative CloseSession while that state remains unknown. */
        clean = NO;
        if (formatWriteAttempted || keptFormatConfirmed)
            status.formatMetadata[@"restore_status"] = @"unknown";
    }
    [transport closeInterface];
    phase_deadline(4);
    if (!clean && !failure) failure = @"The native session could not be closed cleanly.";
    if (failure) {
        fprintf(stderr, "Native preview failed: %s\n", failure.UTF8String);
        [status update:@"error" message:failure];
    } else {
        [status update:@"stopped" message:StopRequested ? @"Preview cancelled and stopped." : @"Preview completed and stopped."];
    }
    printf("Native preview finished frames=%lu clean_shutdown=%s cancelled=%s\n", (unsigned long)status.frames,
           clean ? "yes" : "no", StopRequested ? "yes" : "no");
    return failure ? 1 : 0;
}

static void append16(NSMutableData *data, uint16_t value) { unsigned char b[2]; write16(b, value); [data appendBytes:b length:2]; }
static void append32(NSMutableData *data, uint32_t value) { unsigned char b[4]; write32(b, value); [data appendBytes:b length:4]; }
static void append_ptp_string(NSMutableData *data, NSString *value) {
    NSData *utf = [value dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    unsigned char count = (unsigned char)(utf.length / 2 + 1); [data appendBytes:&count length:1];
    [data appendData:utf]; append16(data, 0);
}
static BOOL body_capture_target_self_test(void) {
    NSMutableData *physicalSlots = [NSMutableData data];
    append32(physicalSlots, 1); append32(physicalSlots, 0x00010000);
    NSMutableData *withCard = [NSMutableData data];
    append32(withCard, 1); append32(withCard, 0x00010001);
    PreviewReply *noCard = s1h_control_fixture_reply(0x2001, physicalSlots);
    PreviewReply *card = s1h_control_fixture_reply(0x2001, withCard);
    PreviewReply *cardTarget = s1h_control_fixture_reply(0x2001, capture_target_data(@0));
    PreviewReply *macTarget = s1h_control_fixture_reply(0x2001, capture_target_data(@1));
    PreviewReply *bothTarget = s1h_control_fixture_reply(0x2001, capture_target_data(@2));
    PreviewReply *acknowledged = s1h_control_fixture_reply(0x2001, nil);
    PreviewReply *declined = s1h_control_fixture_reply(0x201d, nil);
    NSArray *readTarget = @[@0x940a, @[@0x08000090], @YES, NSNull.null];
    NSArray *readStorage = @[@0x1004, @[], @YES, NSNull.null];
    S1HControlFixtureTransport *transport = [S1HControlFixtureTransport new];
    transport.fixtureRequests = [NSMutableArray array];
    transport.synchronized = YES;
    NSDictionary *storage = nil;
    BOOL ok = YES;
    for (NSNumber *target in @[@0, @2]) {
        transport.fixtureReplies = @[macTarget, noCard];
        NSDictionary *rejected = change_body_capture_target(transport, target, &storage);
        ok = ok && [rejected[@"status"] isEqual:@"rejected"] && [storage[@"target"] isEqual:@1] &&
            [storage[@"logical_card_available"] isEqual:@NO] &&
            [transport.fixtureRequests isEqual:@[readTarget, readStorage]];
        [transport.fixtureRequests removeAllObjects];
    }

    transport.fixtureReplies = @[macTarget, card, acknowledged, cardTarget];
    NSDictionary *saved = change_body_capture_target(transport, @0, &storage);
    NSArray *writeCard = @[@0x940b, @[@0x08000091], @NO, capture_target_data(@0)];
    ok = ok && [saved[@"status"] isEqual:@"ok"] && [storage[@"target"] isEqual:@0] &&
        [storage[@"logical_card_available"] isEqual:@YES] &&
        [transport.fixtureRequests isEqual:@[readTarget, readStorage, writeCard, readTarget]] &&
        s1h_capture_target_data_allowed(0x940b, writeCard[1], writeCard[3]);
    [transport.fixtureRequests removeAllObjects];

    transport.fixtureReplies = @[bothTarget, noCard, acknowledged, macTarget];
    saved = change_body_capture_target(transport, @1, &storage);
    NSArray *writeMac = @[@0x940b, @[@0x08000091], @NO, capture_target_data(@1)];
    ok = ok && [saved[@"status"] isEqual:@"ok"] && [storage[@"target"] isEqual:@1] &&
        [transport.fixtureRequests isEqual:@[readTarget, readStorage, writeMac, readTarget]];
    [transport.fixtureRequests removeAllObjects];

    NSArray *writeBoth = @[@0x940b, @[@0x08000091], @NO, capture_target_data(@2)];
    for (PreviewReply *writeReply in @[acknowledged, declined]) {
        transport.fixtureReplies = @[macTarget, card, writeReply, macTarget];
        NSDictionary *failure = change_body_capture_target(transport, @2, &storage);
        ok = ok && [failure[@"status"] isEqual:@"error"] && [storage[@"target"] isEqual:@1] &&
            [transport.fixtureRequests isEqual:@[readTarget, readStorage, writeBoth, readTarget]];
        [transport.fixtureRequests removeAllObjects];
    }

    transport.fixtureReplies = @[macTarget, card, NSNull.null];
    NSDictionary *unknown = change_body_capture_target(transport, @2, &storage);
    return ok && [unknown[@"status"] isEqual:@"outcome_unknown"] && !storage[@"target"] &&
        [transport.fixtureRequests isEqual:@[readTarget, readStorage, writeBoth]];
}

static BOOL battery_telemetry_self_test(void) {
    const unsigned char rangeBytes[] = {0x01, 0x50, 2, 0, 0, 100, 62, 1, 0, 100, 10};
    NSData *range = [NSData dataWithBytes:rangeBytes length:sizeof rangeBytes];
    const unsigned char enumBytes[] = {0x01, 0x50, 2, 0, 0, 100, 62, 2, 3, 0, 0, 50, 100};
    NSData *enumeration = [NSData dataWithBytes:enumBytes length:sizeof enumBytes];
    NSMutableData *foreignScale = [range mutableCopy];
    ((unsigned char *)foreignScale.mutableBytes)[9] = 5;
    NSDictionary *capabilities = @{@"operations":@[@0x1014, @0x1015], @"properties":@[@0x5001]};
    NSArray *descriptorRequest = @[@0x1014, @[@0x5001], @YES, NSNull.null];
    NSArray *valueRequest = @[@0x1015, @[@0x5001], @YES, NSNull.null];
    S1HControlFixtureTransport *transport = [S1HControlFixtureTransport new];
    transport.synchronized = YES;
    transport.transactionBudget = 3.5;
    transport.fixtureRequests = [NSMutableArray array];
    BOOL ok = s1h_is_percent_battery_descriptor(range) && s1h_is_percent_battery_descriptor(enumeration) &&
        !s1h_is_percent_battery_descriptor(foreignScale) &&
        !s1h_is_percent_battery_descriptor([enumeration subdataWithRange:NSMakeRange(0, enumeration.length - 1)]) &&
        !s1h_read_battery_percent(transport, @{@"operations":@[@0x1014], @"properties":@[@0x5001]}) &&
        transport.fixtureRequests.count == 0;

    PreviewReply *descriptor = s1h_control_fixture_reply(0x2001, range);
    const unsigned char values[] = {0, 62, 100, 101};
    for (NSUInteger index = 0; index < sizeof values; ++index) {
        NSData *value = [NSData dataWithBytes:&values[index] length:1];
        transport.fixtureReplies = @[descriptor, s1h_control_fixture_reply(0x2001, value)];
        NSNumber *observed = s1h_read_battery_percent(transport, capabilities);
        ok = ok && (values[index] <= 100 ? [observed isEqual:@(values[index])] : observed == nil) &&
            [transport.fixtureRequests isEqual:@[descriptorRequest, valueRequest]] && transport.transactionBudget == 3.5;
        [transport.fixtureRequests removeAllObjects];
    }
    transport.fixtureReplies = @[s1h_control_fixture_reply(0x2005, nil)];
    ok = ok && !s1h_read_battery_percent(transport, capabilities) && transport.synchronized &&
        [transport.fixtureRequests isEqual:@[descriptorRequest]];
    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[descriptor, s1h_control_fixture_reply(0x2001, range)];
    return ok && !s1h_read_battery_percent(transport, capabilities) &&
        [transport.fixtureRequests isEqual:@[descriptorRequest, valueRequest]] && transport.synchronized &&
        s1h_battery_read_allowed(0x1014, @[@0x5001]) && s1h_battery_read_allowed(0x1015, @[@0x5001]) &&
        !s1h_battery_read_allowed(0x1015, @[@0x5002]) && !s1h_battery_read_allowed(0x1016, @[@0x5001]) &&
        !s1h_battery_read_allowed(0x1014, @[@0x5001, @0]);
}

static int self_test(void) {
    unsigned failures = 0, checks = 0;
#define CHECK(condition, label) do { ++checks; BOOL passed = (condition); if (!passed) ++failures; printf("%s %s\n", passed ? "PASS" : "FAIL", label); } while (0)
    pid_t fixtureParent = 0;
    CHECK(parse_parent_pid("2", &fixtureParent) && fixtureParent == 2 &&
          parse_parent_pid("2147483647", &fixtureParent) && fixtureParent == INT_MAX,
          "Parent PID accepts bounded positive integer identities");
    CHECK(!parse_parent_pid("1", NULL) && !parse_parent_pid("0", NULL) &&
          !parse_parent_pid("-2", NULL) && !parse_parent_pid("+2", NULL) &&
          !parse_parent_pid("2.0", NULL) && !parse_parent_pid(" 2", NULL) &&
          !parse_parent_pid("2147483648", NULL) && !parse_parent_pid("", NULL),
          "Parent PID rejects invalid, fractional, and overflowing input");
    CHECK([interface_owner_name(@"pid 21863, ptpcamerad") isEqual:@"ptpcamerad"] &&
          [interface_owner_name(@"pid 1, A Camera App") isEqual:@"A Camera App"] &&
          !interface_owner_name(@"pid 0, owner") && !interface_owner_name(@"pid -1, owner") &&
          !interface_owner_name(@"pid +1, owner") && !interface_owner_name(@"pid 2147483648, owner") &&
          !interface_owner_name(@"pid 1, ") && !interface_owner_name(@"pid 1,owner") &&
          !interface_owner_name(@"pid 1, owner\nname") && !interface_owner_name(@1),
          "Exclusive owner status only exposes a display name from a valid registry label");
    CHECK(!parent_changed(42, 42) && parent_changed(42, 1) && parent_changed(42, 43),
          "Parent identity change requests cancellation only after a change");
    CHECK(!parent_changed(0, 1) && !parent_changed(0, 42),
          "Omitting parent PID leaves standalone behavior unchanged");
    CHECK(opcode_allowed(0x9412, @[@0x0d000010]) && opcode_allowed(0x9706, @[]), "Preview-only opcodes are allowed");
    CHECK(!opcode_allowed(0x9404, @[]) && !opcode_allowed(0x9403, @[]) && !opcode_allowed(0x940c, @[]), "Shutter, property writes, and recording opcodes are rejected");
    CHECK(!opcode_allowed(0x9412, @[@0x12345678]) && !opcode_allowed(0x1002, @[@2]), "Unexpected control/session parameters are rejected");
    CHECK(body_capture_target_self_test(), "Body shutter storage changes enforce card readiness, exactly one write and verified read-back");
    CHECK(battery_telemetry_self_test(), "Battery telemetry uses only advertised reads and confirmed 0-100 UINT8 data");
    NSDictionary *small = @{@"width": @640, @"height": @480, @"x_raw": @32, @"frequency_raw": @30};
    NSDictionary *original = @{@"width": @640, @"height": @480, @"x_raw": @0, @"frequency_raw": @30};
    NSDictionary *large = @{@"width": @1600, @"height": @1200, @"x_raw": @700, @"frequency_raw": @15};
    NSData *originalPayload = pack_preview_format(original);
    const unsigned char expectedPayload[16] = {0x11,0x00,0x80,0x0d,8,0,0,0,0xe0,1,0x80,2,0,0,30,0};
    CHECK(originalPayload.length == sizeof expectedPayload && !memcmp(originalPayload.bytes, expectedPayload, sizeof expectedPayload),
          "Preview format packs exact little-endian fields including original x zero");
    CHECK(same_preview_format(parse_current_format(originalPayload, NULL), original) && !same_preview_format(small, original),
          "Current-format comparison preserves all four fields, not only dimensions");
    NSMutableData *extendedCurrent = [originalPayload mutableCopy]; append16(extendedCurrent, 0);
    CHECK(!parse_current_format(extendedCurrent, NULL) && !pack_preview_format(@{@"width": @65536, @"height": @1, @"x_raw": @0, @"frequency_raw": @0}),
          "Ununderstood current extensions and out-of-range format fields are rejected before writes");
    NSMutableData *available = [NSMutableData data]; append32(available, 0x0d800012); append32(available, 20); append16(available, 2); append16(available, 8);
    NSData *smallPayload = pack_preview_format(small), *largePayload = pack_preview_format(large);
    [available appendBytes:(const unsigned char *)smallPayload.bytes + 8 length:8];
    [available appendBytes:(const unsigned char *)largePayload.bytes + 8 length:8];
    NSArray *formats = parse_available_formats(available, NULL);
    CHECK(formats.count == 2 && same_preview_format(formats[1], large), "Available preview formats parse bounded camera records");
    NSMutableData *badAvailable = [available mutableCopy]; write32((unsigned char *)badAvailable.mutableBytes + 4, 16);
    CHECK(!parse_available_formats(badAvailable, NULL), "Format list rejects missing count-header bytes rather than over-reading");
    badAvailable = [available mutableCopy]; write16((unsigned char *)badAvailable.mutableBytes + 8, UINT16_MAX);
    CHECK(!parse_available_formats(badAvailable, NULL) && !parse_available_formats([available subdataWithRange:NSMakeRange(0, 11)], NULL),
          "Format list rejects excessive count and truncated headers");
    badAvailable = [available mutableCopy]; write16((unsigned char *)badAvailable.mutableBytes + 10, 0);
    CHECK(!parse_available_formats(badAvailable, NULL), "Format list rejects unsupported record sizes without division by zero");
    NSUInteger profileIndex = 999;
    CHECK(parse_format_index(@"0", &profileIndex) && profileIndex == 0 && !parse_format_index(@"-1", NULL) &&
          !parse_format_index(@"1.5", NULL) && !parse_format_index(@"65536", NULL) && !parse_format_index(@"", NULL),
          "Format indices are nonnegative bounded integers");
    CHECK(keep_preview_format_valid(NO, @"auto") && keep_preview_format_valid(YES, @"max") &&
          keep_preview_format_valid(YES, @"0"), "Retained format requires an explicit selectable preset");
    CHECK(!keep_preview_format_valid(YES, @"auto") && !keep_preview_format_valid(YES, nil) &&
          !keep_preview_format_valid(YES, @"-1"), "Retained format rejects auto, missing selection and invalid indices");
    CHECK(!keep_preview_format_valid(NO, @"max") && !keep_preview_format_valid(NO, @"0") &&
          !keep_preview_format_valid(NO, nil), "Every explicit selection requires retention acknowledgement before any I/O");
    CHECK(s1h_controls_self_test(), "Control protocol fixtures pass without hardware");
    CHECK(s1h_focus_self_test(), "Remote focus validates MF, bounded motor movement and the paired stop command");
    CHECK(s1h_capture_self_test(), "Capture protocol fixtures pass without hardware");
    CHECK(s1h_capture_request_allowed(0x9404, @[@0x03000011]) && !s1h_capture_request_allowed(0x9404, @[@0x03000012]) &&
          s1h_capture_request_allowed(0x101b, @[@1,@0,@1048576]) && !s1h_capture_request_allowed(0x101b, @[@1,@0,@1048577]),
          "Capture backend restricts shutter parameters and partial-transfer bounds");
    CHECK(s1h_storage_inspection_allowed(0x1004, @[]) && !s1h_storage_inspection_allowed(0x1004, @[@1]) &&
          s1h_capture_request_allowed(0x9401, @[@1]) && !s1h_capture_request_allowed(0x9401, @[@1,@2]),
          "Storage inspection and capture event reads require exact parameter counts");
    CHECK(!has_logical_capture_storage(@[@0x00010000, @0x00020000]) &&
          has_logical_capture_storage(@[@0x00010000, @0x00020001]),
          "Physical slot IDs alone do not enable a card-backed shutter");
    BOOL inputEnded = YES;
    NSString *actionError = nil;
    NSString *line = @"{\"id\":\"0AC8F770-87BC-4981-93E8-A2B5431C3BB4\",\"action\":\"refresh\"}\n";
    NSMutableData *actions = [[line stringByAppendingString:line] dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
    NSDictionary *firstAction = next_interactive_action(actions, &inputEnded, &actionError);
    NSDictionary *secondAction = next_interactive_action(actions, &inputEnded, &actionError);
    CHECK([firstAction[@"action"] isEqual:@"refresh"] && [firstAction isEqual:secondAction] && !actions.length && !actionError,
          "Action parser handles buffered commands one at a time");
    actions = [@"{\"id\":\"invalid\"}\n" dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
    CHECK(!next_interactive_action(actions, &inputEnded, &actionError) && actionError,
          "Action parser rejects an invalid request identity");
    actionError = nil;
    actions = [NSMutableData dataWithLength:ActionLineLimit + 1];
    CHECK(!next_interactive_action(actions, &inputEnded, &actionError) && actionError,
          "Action parser rejects an overlong or incomplete request");
    CHECK(same_preview_format(select_preview_format(formats, @"0", NULL), small) &&
          same_preview_format(select_preview_format(formats, @"1", NULL), large) && !select_preview_format(formats, @"2", NULL) &&
          !select_preview_format(@[], @"max", NULL), "Format selection uses actual reported entries and rejects absent indices");
    NSDictionary *huge = @{@"width": @65535, @"height": @65535, @"x_raw": @1, @"frequency_raw": @0};
    CHECK(same_preview_format(select_preview_format(@[small, huge, huge], @"max", NULL), huge) &&
          select_preview_format(@[small, original], @"max", NULL) == small,
          "Maximum format uses wide area arithmetic and stable first-entry ties");
    NSMutableData *dataContainer = [NSMutableData dataWithLength:28];
    BOOL encoded = write_data_container(dataContainer, originalPayload, 0x9415, 42);
    const unsigned char *containerBytes = dataContainer.bytes;
    CHECK(encoded && read32(containerBytes) == 28 && read16(containerBytes + 4) == 2 &&
          read16(containerBytes + 6) == 0x9415 && read32(containerBytes + 8) == 42 &&
          !memcmp(containerBytes + 12, expectedPayload, sizeof expectedPayload),
          "Format DataOut has type two, opcode 9415, matching transaction and real payload bytes");
    CHECK(!write_data_container([NSMutableData dataWithLength:27], originalPayload, 0x9415, 42),
          "Production DataOut encoder refuses a buffer with the wrong size");
    CHECK(format_data_allowed(0x9415, @[@0x0d800011], originalPayload) &&
          !format_data_allowed(0x9403, @[@0x0d800011], originalPayload) &&
          !format_data_allowed(0x9415, @[@0x0d800012], originalPayload) &&
          !format_data_allowed(0x9415, @[@0x0d800011], smallPayload.length ? [smallPayload subdataWithRange:NSMakeRange(0, 15)] : nil) &&
          !opcode_allowed(0x9415, @[@0x0d800011]), "Only the known preview-format payload can use the dedicated DataOut path");
    NSMutableData *info = [NSMutableData data]; append16(info, 100); append32(info, 0x1c); append16(info, 100);
    append_ptp_string(info, @""); append16(info, 0);
    NSUInteger firstList = info.length;
    append32(info, 2); append16(info, 0x1001); append16(info, 0x9402);
    append32(info, 1); append16(info, 0xc109);
    append32(info, 1); append16(info, 0x5001);
    append32(info, 1); append16(info, 0x3801);
    append32(info, 1); append16(info, 0x3801);
    append_ptp_string(info, @"Panasonic");
    NSUInteger modelOffset = info.length;
    append_ptp_string(info, @"DC-S1H");
    NSDictionary *expectedCapabilities = @{@"model":@"DC-S1H", @"operations":@[@0x1001, @0x9402],
        @"events":@[@0xc109], @"properties":@[@0x5001]};
    CHECK([parse_device_capabilities(info) isEqual:expectedCapabilities],
        "DeviceInfo confirms the model and returns the advertised capability lists");
    append_ptp_string(info, @"Firmware fixture"); append_ptp_string(info, @"Serial fixture");
    CHECK([parse_device_capabilities(info) isEqual:expectedCapabilities],
        "DeviceInfo inventory excludes manufacturer, format lists, firmware and serial fields");
    CHECK(!parse_device_capabilities([info subdataWithRange:NSMakeRange(0, firstList + 5)]),
        "Truncated DeviceInfo capability array is rejected");
    NSMutableData *invalidInfo = [info mutableCopy];
    write32((unsigned char *)invalidInfo.mutableBytes + firstList, UINT32_MAX);
    CHECK(!parse_device_capabilities(invalidInfo), "Oversized DeviceInfo capability array is rejected");
    invalidInfo = [[info subdataWithRange:NSMakeRange(0, modelOffset)] mutableCopy];
    append_ptp_string(invalidInfo, @"DC-S1");
    CHECK(!parse_device_capabilities(invalidInfo), "DeviceInfo still rejects other camera models");
    NSMutableData *packet = [NSMutableData data]; append32(packet, 16); append16(packet, 3); append16(packet, 0x2001); append32(packet, 9); append32(packet, 42);
    __block NSUInteger part = 0;
    NSArray *parts = @[[packet subdataWithRange:NSMakeRange(0, 3)], [packet subdataWithRange:NSMakeRange(3, 7)], [packet subdataWithRange:NSMakeRange(10, 6)]];
    PreviewReader *reader = [PreviewReader new]; reader.readChunk = ^NSData *{ return part < parts.count ? parts[part++] : nil; };
    PreviewContainer *parsed = [reader container];
    CHECK(parsed && parsed.transaction == 9 && parsed.code == 0x2001 && parsed.payload.length == 4, "PTP framing spans fragmented USB chunks");
    NSMutableData *eventPacket = [NSMutableData data];
    append32(eventPacket, 16); append16(eventPacket, 4); append16(eventPacket, 0xc109);
    append32(eventPacket, UINT32_MAX); append32(eventPacket, 42);
    NativePreviewTransport *eventTransport = [NativePreviewTransport new];
    eventTransport.interactiveEnabled = YES;
    eventTransport.synchronized = YES;
    // Bypass USB submission with an already queued, unsignalled test read.
    eventTransport.events = (IOUSBHostPipe *)[NSObject new];
    eventTransport.eventPending = [NSMutableData data];
    eventTransport.eventQueue = [NSMutableArray array];
    PreviewInterruptRead *eventRead = [PreviewInterruptRead new];
    eventRead.complete = dispatch_semaphore_create(0);
    eventTransport.eventRead = eventRead;
    NSString *eventError = nil;
    double fragmentDeadline = 0;
    NSString *fragmentError = append_capture_events(eventTransport.eventPending, eventTransport.eventQueue,
        eventPacket, 5, monotonic_seconds(), &fragmentDeadline);
    eventTransport.eventFragmentDeadline = fragmentDeadline;
    CHECK(!fragmentError && ![eventTransport readCaptureEvent:0.002 error:&eventError] && !eventError &&
          eventTransport.eventPending.length == 5 && eventTransport.eventRead == eventRead,
          "Short interrupt polls preserve partial capture events and their pending read");
    eventRead.buffer = [[eventPacket subdataWithRange:NSMakeRange(5, 11)] mutableCopy];
    eventRead.result = kIOReturnSuccess;
    eventRead.count = eventRead.buffer.length;
    dispatch_semaphore_signal(eventRead.complete);
    NSDictionary *receivedEvent = [eventTransport readCaptureEvent:0.002 error:&eventError];
    CHECK(!eventError && [receivedEvent[@"code"] isEqual:@0xc109] && [receivedEvent[@"parameters"] isEqual:@[@42]] &&
          !eventTransport.eventPending.length && !eventTransport.eventFragmentDeadline,
          "A subsequent USB completion joins and delivers exactly one capture event");
    eventTransport.eventFragmentDeadline = monotonic_seconds() - 1.0;
    CHECK(![eventTransport readCaptureEvent:0.002 error:&eventError] && eventError.length,
          "Incomplete capture events fail after their independent deadline");
    unsigned char pixels[12] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255};
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 3, 1, 8, 12, colors, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    NSMutableData *fixture = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)fixture, CFSTR("public.jpeg"), 1, NULL);
    BOOL made = destination && image;
    if (made) { CGImageDestinationAddImage(destination, image, NULL); made = CGImageDestinationFinalize(destination); }
    NSMutableData *wrapped = [NSMutableData dataWithLength:137]; [wrapped appendData:fixture];
    NSUInteger width = 0, height = 0;
    NSData *jpeg = made ? validated_preview_jpeg(wrapped, &width, &height) : nil;
    CHECK(jpeg && width == 3 && height == 1, "JPEG metadata-prefix scanning and ImageIO decode succeed");
    NSData *truncated = fixture.length > 2 ? [fixture subdataWithRange:NSMakeRange(0, fixture.length - 2)] : NSData.data;
    CHECK(!validated_preview_jpeg(truncated, NULL, NULL), "JPEG missing EOI is rejected");
    if (destination) CFRelease(destination); if (image) CGImageRelease(image); if (context) CGContextRelease(context); CGColorSpaceRelease(colors);
    printf("Self-test: %u checks, %u failures; no hardware, processes, or filesystem output.\n", checks, failures);
    return failures ? 1 : 0;
#undef CHECK
}

static void usage(const char *program) {
    printf("Usage: %s --output-dir PATH [--frames N] [--duration SECONDS] [--fps N] [--preview-format auto|max|INDEX] [--keep-preview-format] [--parent-pid PID] [--verbose]\n", program);
    printf("       %s --inspect-controls --output-dir PATH\n", program);
    printf("       %s --interactive --output-dir PATH [--camera-save-dir ABSOLUTE_FOLDER] [--photo-name-prefix PREFIX] [preview options]\n", program);
    printf("       %s --self-test | --help\n", program);
    printf("Default: 60 preview frames at up to 10 fps. Duration without --frames runs until that duration.\n");
    printf("Frame-rate range: 0.1 to 60 fps.\n");
    printf("Preview format defaults to auto (no format query/write). Explicit max or a zero-based index requires --keep-preview-format and retains the verified camera selection after stopping.\n");
    printf("This alpha has no automatic preview-format restoration. Auto forbids --keep-preview-format.\n");
    printf("--inspect-controls reads actual descriptors/current values into status.json, then closes without starting preview or changing camera settings.\n");
    printf("--close-stale-session with --inspect-controls or --interactive explicitly closes a verified leftover session after SessionAlreadyOpen. Only use when the camera is idle.\n");
    printf("--set-capture-target sd|ram|both with --inspect-controls explicitly applies and verifies one camera storage destination.\n");
    printf("--photo-name-prefix numbers Mac copies from either shutter; empty preserves camera filenames.\n");
    printf("Optional --parent-pid must match the launching process; its exit cancels this worker.\n");
    printf("Atomically updates latest.jpg and status.json. Only --interactive accepts explicit capture and control requests on stdin.\n");
    printf("Close Tether and other camera/import software before a hardware run. No driver seizure or process termination is attempted.\n");
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        PreviewOptions *options = [PreviewOptions new]; options.frames = 60; options.fps = 10; options.previewFormat = @"auto";
        BOOL framesSet = NO;
        for (int i = 1; i < argc; ++i) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqual:@"--help"]) { usage(argv[0]); return 0; }
            if ([arg isEqual:@"--self-test"]) return self_test();
            if ([arg isEqual:@"--verbose"]) { options.verbose = YES; continue; }
            if ([arg isEqual:@"--inspect-controls"]) { options.inspectControls = YES; continue; }
            if ([arg isEqual:@"--interactive"]) { options.interactive = YES; continue; }
            if ([arg isEqual:@"--close-stale-session"]) { options.closeStaleSession = YES; continue; }
            if ([arg isEqual:@"--keep-preview-format"]) { options.keepPreviewFormat = YES; continue; }
            if (i + 1 >= argc) { usage(argv[0]); return 2; }
            NSString *value = [NSString stringWithUTF8String:argv[++i]];
            if ([arg isEqual:@"--output-dir"]) options.output = value.stringByExpandingTildeInPath;
            else if ([arg isEqual:@"--camera-save-dir"]) options.cameraSaveDirectory = value;
            else if ([arg isEqual:@"--photo-name-prefix"]) {
                if (!s1h_photo_prefix_valid(value)) { usage(argv[0]); return 2; }
                options.photoNamePrefix = value;
            }
            else if ([arg isEqual:@"--set-capture-target"]) {
                options.explicitStorageTarget = @{ @"sd": @0, @"ram": @1, @"both": @2 }[value];
                if (!options.explicitStorageTarget) { usage(argv[0]); return 2; }
            }
            else if ([arg isEqual:@"--preview-format"]) {
                if (![value isEqualToString:@"auto"] && ![value isEqualToString:@"max"] && !parse_format_index(value, NULL)) {
                    usage(argv[0]); return 2;
                }
                options.previewFormat = value;
            }
            else if ([arg isEqual:@"--parent-pid"]) {
                if (!parse_parent_pid(value.UTF8String, &ExpectedParentPID)) { usage(argv[0]); return 2; }
            }
            else {
                char *end = NULL; double number = strtod(value.UTF8String, &end);
                if (!end || *end || !isfinite(number) || number <= 0) { usage(argv[0]); return 2; }
                if ([arg isEqual:@"--frames"] && floor(number) == number && number <= 1000000000) { options.frames = (NSUInteger)number; framesSet = YES; }
                else if (([arg isEqual:@"--duration"] || [arg isEqual:@"--seconds"]) && number <= 86400) options.duration = number;
                else if ([arg isEqual:@"--fps"] && number >= 0.1 && number <= 60) options.fps = number;
                else { usage(argv[0]); return 2; }
            }
        }
        if (!options.output.length || !keep_preview_format_valid(options.keepPreviewFormat, options.previewFormat) ||
            (options.closeStaleSession && !options.inspectControls && !options.interactive) ||
            (options.explicitStorageTarget && !options.inspectControls) ||
            (options.cameraSaveDirectory && (!options.interactive || !options.cameraSaveDirectory.isAbsolutePath)) ||
            (options.photoNamePrefix && !options.interactive) ||
            (options.inspectControls && (options.interactive || ![options.previewFormat isEqualToString:@"auto"] || options.keepPreviewFormat))) {
            usage(argv[0]); return 2;
        }
        if (ExpectedParentPID && parent_changed(ExpectedParentPID, getppid())) {
            fprintf(stderr, "--parent-pid must equal the process that launched this worker.\n");
            return 2;
        }
        if (options.duration > 0 && !framesSet) options.frames = NSUIntegerMax;
        struct sigaction action = {0}; action.sa_handler = stop_signal; sigemptyset(&action.sa_mask);
        sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
        /* A GUI parent disappearing also closes its log pipe. Do not let
         * SIGPIPE preempt the parent watchdog's orderly cancellation. */
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (ExpectedParentPID) {
            struct sigaction brokenPipe = {0}; brokenPipe.sa_handler = SIG_IGN;
            sigemptyset(&brokenPipe.sa_mask); sigaction(SIGPIPE, &brokenPipe, NULL);
        }
        begin_watchdog();
        int result = run_preview(options);
        dispatch_source_cancel(Watchdog);
        return result;
    }
}
