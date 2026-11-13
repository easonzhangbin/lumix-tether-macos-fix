/*
 * S1H native IOUSBHost transport probe (no ImageCaptureCore or libusb).
 * Only standard PTP OpenSession, GetDeviceInfo, CloseSession are sent.
 * No vendor commands, capture, property writes, photo downloads, reset,
 * driver capture/seize, configuration changes, or persistent settings.
 * DeviceInfo payload is consumed and discarded without logging it.
 * Optional --events queues one interrupt IN 0x83 read before OpenSession,
 * to compare the Windows driver's early event-read submission order.
 * Optional --io-buffer uses fixed-length kernel DMA buffers from the
 * interface's ioDataWithCapacity:error: API; IN data is copied to an ordinary
 * user buffer after successful completion, never resized in kernel memory.
 * Optional --read-after-out-error checks for a matching PTP response even
 * after a reported OUT completion error. This does not convert that error
 * into transfer success; all three matching transactions must be observed.
 * Optional --drain-input consumes at most five pre-existing complete PTP
 * containers, within three seconds, before sending any OUT command. Only a
 * zero-byte input timeout on a container boundary establishes a cleared IN
 * queue. Payload is discarded and never logged.
 *
 * Build (macOS SDK IOUSBHost headers are the API reference):
 * xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 \
 *   s1h_iousbhost_probe.m -framework Foundation -framework IOKit \
 *   -framework IOUSBHost -o s1h_iousbhost_probe
 *
 * Close other camera clients before running. No entitlement or root
 * escalation is attempted; access/ownership errors are reported as-is.
 * Per-transfer timeout: 2 seconds. Process watchdog: 18 seconds.
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define IO_TIMEOUT 2.0
#define READ_CAPACITY 65536U
#define MAX_CONTAINER_LENGTH (16U * 1024U * 1024U)

/* Stable failure stages for the launcher; an open failure alone does not
 * establish exclusivity or identify the process holding an interface. */
enum {
    ProbeNoInterface = 20,
    ProbeMultipleInterfaces = 21,
    ProbeOpenFailed = 22,
    ProbeDrainFailed = 23,
    ProbeSessionFailed = 24
};

typedef struct {
    BOOL events;
    BOOL ioBuffer;
    BOOL readAfterOutError;
    BOOL drainInput;
} ProbeOptions;

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
                           IOReturn *completionStatus) {
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
    printf("%s: completion=0x%08x API-reported-bytes=%lu requested=%lu\n", label,
           (unsigned int)status, (unsigned long)count,
           (unsigned long)data.length);
    if (actual) *actual = count;
    if (callbackReceived) *callbackReceived = YES;
    if (completionStatus) *completionStatus = status;
    return status == kIOReturnSuccess && count <= data.length;
}

static BOOL transfer(IOUSBHostPipe *pipe, NSMutableData *data,
                     const char *label, NSUInteger *actual, BOOL *callbackReceived) {
    return transfer_timed(pipe, data, label, actual, callbackReceived,
                          IO_TIMEOUT, 3.0, NULL);
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
                                  &callbackReceived, ioTimeout, waitTimeout, &status);
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

@interface PTPReader : NSObject
@property(nonatomic, strong) IOUSBHostPipe *pipe;
@property(nonatomic, strong) IOUSBHostInterface *interface;
@property(nonatomic) BOOL ioBuffer;
@property(nonatomic, strong) NSMutableData *pending;
@property(nonatomic) NSUInteger offset;
- (BOOL)take:(NSUInteger)length into:(void *)destination;
@end
@implementation PTPReader
- (BOOL)take:(NSUInteger)length into:(void *)destination {
    unsigned char *dest = destination;
    while (length) {
        if (!_pending || _offset == _pending.length) {
            NSMutableData *next = make_buffer(_interface, READ_CAPACITY, _ioBuffer);
            if (!next) return NO;
            NSUInteger actual = 0;
            if (!transfer(_pipe, next, "native bulk IN 0x82", &actual, NULL) || actual == 0)
                return NO;
            /* Never setLength: or change capacity on an ioData buffer.
             * Copy only bytes from a successful bounded IN completion. */
            _pending = [NSMutableData dataWithBytes:next.bytes length:actual];
            _offset = 0;
        }
        NSUInteger count = MIN(length, _pending.length - _offset);
        if (dest) {
            memcpy(dest, (const unsigned char *)_pending.bytes + _offset, count);
            dest += count;
        }
        _offset += count;
        length -= count;
    }
    return YES;
}
@end

@interface EventRead : NSObject
@property(nonatomic, strong) IOUSBHostPipe *pipe;
@property(nonatomic, strong) IOUSBHostInterface *interface;
@property(nonatomic) BOOL ioBuffer;
@property(nonatomic, strong) NSMutableData *buffer;
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(atomic) BOOL finished;
- (BOOL)start;
- (void)stop;
@end
@implementation EventRead
- (BOOL)start {
    _buffer = make_buffer(_interface, 64, _ioBuffer);
    if (!_buffer) return NO;
    _completed = dispatch_semaphore_create(0);
    NSError *error = nil;
    BOOL queued = [_pipe enqueueIORequestWithData:_buffer completionTimeout:0
                                         error:&error
                             completionHandler:^(IOReturn status, NSUInteger count) {
        (void)self.buffer.length;
        printf("interrupt IN 0x83: completion=0x%08x API-reported-bytes=%lu; payload not logged\n",
               (unsigned int)status, (unsigned long)count);
        self.finished = YES;
        dispatch_semaphore_signal(self.completed);
    }];
    if (!queued) {
        show_error("Queue interrupt IN 0x83", error);
        return NO;
    }
    printf("interrupt IN 0x83: 64-byte async read queued before OpenSession (timeout 0 required for interrupt pipe).\n");
    return YES;
}
- (void)stop {
    if (!self.finished) {
        NSError *error = nil;
        if (![_pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:&error])
            show_error("Abort interrupt IN 0x83", error);
        if (dispatch_semaphore_wait(_completed,
                dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0)
            printf("interrupt IN 0x83: abort callback not observed within 1 second; destroying interface.\n");
    }
}
@end

static BOOL command(IOUSBHostInterface *interface, IOUSBHostPipe *out,
                    uint16_t opcode, uint32_t tx, BOOL parameterPresent,
                    uint32_t parameter, BOOL ioBuffer, BOOL *callbackReceived) {
    if (callbackReceived) *callbackReceived = NO;
    NSMutableData *data = make_buffer(interface, parameterPresent ? 16 : 12, ioBuffer);
    if (!data) return NO;
    unsigned char *bytes = data.mutableBytes;
    write32(bytes, (uint32_t)data.length);
    write16(bytes + 4, 1);
    write16(bytes + 6, opcode);
    write32(bytes + 8, tx);
    if (parameterPresent) write32(bytes + 12, parameter);
    printf("command opcode=0x%04x tx=%u length=%lu\n", opcode, tx,
           (unsigned long)data.length);
    NSUInteger actual = 0;
    return transfer(out, data, "native bulk OUT 0x01", &actual, callbackReceived) && actual == data.length;
}

static BOOL response(PTPReader *reader, uint16_t expectedOpcode,
                     uint32_t expectedTx, BOOL dataExpected) {
    BOOL sawData = NO;
    for (int i = 0; i < 2; ++i) {
        unsigned char header[12];
        if (![reader take:sizeof header into:header]) return NO;
        uint32_t length = read32(header), tx = read32(header + 8);
        uint16_t type = read16(header + 4), code = read16(header + 6);
        printf("PTP container type=%u length=%u code=0x%04x tx=%u\n",
               type, length, code, tx);
        if (length < sizeof header || length > MAX_CONTAINER_LENGTH || tx != expectedTx) {
            printf("Invalid PTP container length or transaction ID.\n");
            return NO;
        }
        if (![reader take:length - sizeof header into:NULL]) return NO;
        if (type == 2 && dataExpected && !sawData && code == expectedOpcode) {
            sawData = YES;
            printf("DeviceInfo payload discarded: %u bytes.\n", length - 12);
            continue;
        }
        if (type == 3) {
            printf("PTP response=0x%04x%s\n", code, code == 0x2001 ? " OK" : " not OK");
            return code == 0x2001 && (!dataExpected || sawData);
        }
        printf("Unexpected PTP container type or code.\n");
        return NO;
    }
    return NO;
}

static BOOL transaction(IOUSBHostInterface *interface, IOUSBHostPipe *out,
                        PTPReader *reader, uint16_t opcode, uint32_t tx,
                        BOOL parameterPresent, uint32_t parameter,
                        BOOL dataExpected, ProbeOptions options) {
    BOOL callbackReceived = NO;
    BOOL outOK = command(interface, out, opcode, tx, parameterPresent, parameter,
                         options.ioBuffer, &callbackReceived);
    if (!outOK) {
        if (!options.readAfterOutError || !callbackReceived) return NO;
        printf("OUT completion was not successful for opcode=0x%04x tx=%u; checking IN for matching response.\n",
               opcode, tx);
    }
    BOOL matched = response(reader, opcode, tx, dataExpected);
    if (!outOK && matched)
        printf("Matched response observed after OUT error for tx=%u; this alone does not establish full probe success.\n", tx);
    return matched;
}

static int probe(ProbeOptions options) {
    printf("Native IOUSBHost async probe; VID 04da PID 2382 interface 0.\n");
    printf("No seize/capture/detach/reset/configuration changes.\n");
    printf("Early interrupt event read: %s\n", options.events ? "enabled" : "disabled");
    printf("Transfer buffers: %s\n", options.ioBuffer ? "native kernel DMA ioData (fixed length)" : "ordinary NSMutableData");
    printf("Read matching response after OUT completion error: %s\n", options.readAfterOutError ? "enabled" : "disabled");
    printf("Drain pre-existing input before any OUT: %s\n", options.drainInput ? "enabled" : "disabled");
    CFMutableDictionaryRef match =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x04da
                                                      productID:@0x2382
                                                      bcdDevice:nil
                                                interfaceNumber:@0
                                             configurationValue:@1
                                                 interfaceClass:@6
                                              interfaceSubclass:@1
                                              interfaceProtocol:@1
                                                          speed:nil
                                                 productIDArray:nil];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != KERN_SUCCESS) {
        printf("Matching services failed: 0x%08x\n", kr);
        return 1;
    }
    io_service_t selected = IO_OBJECT_NULL, current;
    unsigned matches = 0;
    while ((current = IOIteratorNext(iterator))) {
        ++matches;
        if (selected) IOObjectRelease(selected);
        selected = current;
    }
    IOObjectRelease(iterator);
    if (matches != 1) {
        printf("Expected one matching interface; found %u.\n", matches);
        if (selected) IOObjectRelease(selected);
        return matches == 0 ? ProbeNoInterface : ProbeMultipleInterfaces;
    }

    NSError *error = nil;
    dispatch_queue_t queue = dispatch_queue_create("local.s1h.native-usb-probe", DISPATCH_QUEUE_SERIAL);
    IOUSBHostInterface *interface = [[IOUSBHostInterface alloc]
                                    initWithIOService:selected
                                    options:IOUSBHostObjectInitOptionsNone
                                    queue:queue error:&error interestHandler:nil];
    IOObjectRelease(selected);
    if (!interface) {
        show_error("Open native interface (no seizure)", error);
        return ProbeOpenFailed;
    }
    const IOUSBInterfaceDescriptor *descriptor = interface.interfaceDescriptor;
    if (!descriptor || descriptor->bInterfaceNumber != 0 ||
        descriptor->bInterfaceClass != 6 || descriptor->bInterfaceSubClass != 1 ||
        descriptor->bInterfaceProtocol != 1 || descriptor->bAlternateSetting != 0) {
        printf("Unexpected interface descriptor; stopping.\n");
        [interface destroy];
        return 1;
    }
    printf("Interface opened: number=%u alt=%u class=%02x/%02x/%02x endpoints=%u\n",
           descriptor->bInterfaceNumber, descriptor->bAlternateSetting,
           descriptor->bInterfaceClass, descriptor->bInterfaceSubClass,
           descriptor->bInterfaceProtocol, descriptor->bNumEndpoints);
    IOUSBHostPipe *out = [interface copyPipeWithAddress:0x01 error:&error];
    if (!out) {
        show_error("Open OUT pipe 0x01", error);
        [interface destroy];
        return 1;
    }
    IOUSBHostPipe *in = [interface copyPipeWithAddress:0x82 error:&error];
    if (!in) {
        show_error("Open IN pipe 0x82", error);
        [interface destroy];
        return 1;
    }
    if (options.drainInput && !drain_input(interface, in, options.ioBuffer)) {
        [interface destroy];
        return ProbeDrainFailed;
    }
    PTPReader *reader = [PTPReader new];
    reader.pipe = in;
    reader.interface = interface;
    reader.ioBuffer = options.ioBuffer;
    EventRead *events = nil;
    if (options.events) {
        IOUSBHostPipe *interrupt = [interface copyPipeWithAddress:0x83 error:&error];
        if (!interrupt) {
            show_error("Open interrupt pipe 0x83", error);
            [interface destroy];
            return 1;
        }
        events = [EventRead new];
        events.pipe = interrupt;
        events.interface = interface;
        events.ioBuffer = options.ioBuffer;
        if (![events start]) {
            [interface destroy];
            return 1;
        }
    }
    BOOL opened = transaction(interface, out, reader, 0x1002, 0, YES, 1, NO, options);
    [events stop];
    BOOL infoOK = NO, closeOK = NO;
    if (opened) {
        infoOK = transaction(interface, out, reader, 0x1001, 1, NO, 0, YES, options);
        printf("Closing session confirmed opened by this probe.\n");
        closeOK = transaction(interface, out, reader, 0x1003, 2, NO, 0, NO, options);
    }
    [interface destroy];
    BOOL success = opened && infoOK && closeOK;
    printf("Required transaction checks: OpenSession tx0=%s, GetDeviceInfo data+OK tx1=%s, CloseSession tx2=%s\n",
           opened ? "matched" : "failed", infoOK ? "matched" : "failed", closeOK ? "matched" : "failed");
    printf("Native probe result: %s\n", success ? "SUCCESS" : "FAILED");
    return success ? 0 : ProbeSessionFailed;
}

int main(int argc, const char *argv[]) {
    ProbeOptions options = {NO, NO, NO, NO};
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--events") == 0) options.events = YES;
        else if (strcmp(argv[i], "--io-buffer") == 0) options.ioBuffer = YES;
        else if (strcmp(argv[i], "--read-after-out-error") == 0) options.readAfterOutError = YES;
        else if (strcmp(argv[i], "--drain-input") == 0) options.drainInput = YES;
        else if (strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [--events] [--io-buffer] [--read-after-out-error] [--drain-input]\n", argv[0]);
            printf("--events: queue interrupt IN 0x83 before OpenSession.\n");
            printf("--io-buffer: use fixed-length native kernel DMA buffers.\n");
            printf("--read-after-out-error: seek matching PTP IN after an OUT completion error.\n");
            printf("--drain-input: consume old input before OUT; require a boundary timeout within 3 seconds / 5 containers.\n");
            return 0;
        } else {
            fprintf(stderr, "Usage: %s [--events] [--io-buffer] [--read-after-out-error] [--drain-input]\n", argv[0]);
            return 2;
        }
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    /* A process-level limit also bounds unexpected open/destroy blocking.
     * This source is intentionally a one-shot CLI, never a service. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        fprintf(stderr, "Process watchdog deadline (18 seconds) exceeded.\n");
        _exit(124);
    });
    @autoreleasepool { return probe(options); }
}
