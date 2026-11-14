/*
 * Inspect the S1H interface owner; explicitly opt in to restarting the current
 * user's camera import service. Defaults to --inspect (read-only).
 *
 * This program NEVER opens a USB device/pipe, sends PTP commands, changes
 * privileges/settings, or terminates a camera application. The only allowed
 * signal target is the verified current-user /usr/libexec/ptpcamerad that
 * exclusively owns the unique S1H still-image interface.
 *
 * IMPORTANT: IORegistry shows the interface user client, not all of that
 * daemon's ImageCaptureCore/XPC clients. No reliable public, non-invasive API
 * for the latter was identified. client_state is therefore always "unknown".
 * A restart is DISRUPTIVE to this user's camera import service; close every
 * camera/import application and opt in with --restart-camera-service.
 * Known-app detection is a guard, not proof that there are no other clients.
 * IORegistry ownership properties are best-effort observations. Missing or
 * ambiguous ownership evidence fails closed. Device-level browser ownership
 * and unrelated USB peripheral owners are deliberately ignored.
 *
 * Build: xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks
 *   -Wall -Wextra -Werror -O2 src/s1h_camera_service.m
 *   -framework Foundation -framework IOKit -o bin/s1h_camera_service
 *
 * --self-test uses a fake environment: no signals, process enumeration,
 * IORegistry, ImageCaptureCore, or USB access occurs in that mode.
 * Real inspection/restart has an 18-second process watchdog. Expiry exits
 * this helper with status 124; it adds no signal to any other process.
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static NSString *const ServiceExecutable = @"/usr/libexec/ptpcamerad";
static const NSTimeInterval TermWait = 2.0;
static const NSTimeInterval KillWait = 1.0;

@interface ServiceIdentity : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic) uid_t uid;
@property(nonatomic) uid_t realUID;
@property(nonatomic) uint64_t startSeconds;
@property(nonatomic) uint64_t startMicroseconds;
@property(nonatomic, copy) NSString *path;
- (BOOL)isSameProcess:(ServiceIdentity *)other;
- (NSDictionary *)json;
@end
@implementation ServiceIdentity
- (BOOL)isSameProcess:(ServiceIdentity *)other {
    return other && _pid == other.pid && _uid == other.uid && _realUID == other.realUID &&
           _startSeconds == other.startSeconds && _startMicroseconds == other.startMicroseconds &&
           [_path isEqualToString:other.path];
}
- (NSDictionary *)json {
    return @{@"pid": @(_pid), @"uid": @(_uid), @"real_uid": @(_realUID),
             @"start_seconds": @(_startSeconds), @"start_microseconds": @(_startMicroseconds),
             @"executable": _path ?: @""};
}
@end

@interface ServiceSnapshot : NSObject
@property(nonatomic) uid_t callerUID;
@property(nonatomic) uid_t callerEffectiveUID;
@property(nonatomic) NSUInteger deviceCount;
@property(nonatomic, copy) NSString *deviceModelState;
@property(nonatomic, copy) NSString *productName;
@property(nonatomic) NSUInteger interfaceCount;
@property(nonatomic) uint64_t interfaceID;
@property(nonatomic) uint64_t usbLinkSpeed;
@property(nonatomic, copy) NSString *ownerState; /* none, confirmed, unknown */
@property(nonatomic, copy) NSString *ownerLabel;
@property(nonatomic) pid_t ownerPID;
@property(nonatomic, strong) ServiceIdentity *owner;
@property(nonatomic) int ownerLookupError;
@property(nonatomic, copy) NSArray<NSNumber *> *creatorPIDs;
@property(nonatomic, copy) NSArray<NSDictionary *> *knownApps;
@property(nonatomic, copy) NSArray<ServiceIdentity *> *daemons;
@property(nonatomic, copy) NSArray<NSDictionary *> *otherPTPInterfaces;
@property(nonatomic, copy) NSString *inspectionError;
- (NSDictionary *)json;
@end
@implementation ServiceSnapshot
- (instancetype)init {
    if ((self = [super init])) {
        _ownerState = @"unknown";
        _deviceModelState = @"unknown";
        _productName = @"";
        _ownerLabel = @"";
        _creatorPIDs = @[];
        _knownApps = @[];
        _daemons = @[];
        _otherPTPInterfaces = @[];
    }
    return self;
}
- (NSDictionary *)json {
    NSMutableArray *daemons = [NSMutableArray array];
    for (ServiceIdentity *identity in _daemons) [daemons addObject:identity.json];
    return @{@"caller_uid": @(_callerUID), @"caller_effective_uid": @(_callerEffectiveUID),
             @"matching_usb_id_device_count": @(_deviceCount),
             @"s1h_device_count": @([_deviceModelState isEqualToString:@"confirmed"] ? _deviceCount : 0),
             @"device_model_state": _deviceModelState, @"usb_product_name": _productName,
             @"s1h_interface_count": @(_interfaceCount),
             @"interface_registry_id": @(_interfaceID), @"usb_link_speed_bps": @(_usbLinkSpeed),
             @"owner_state": _ownerState,
             @"interface_owner_label": _ownerLabel, @"owner_pid": @(_ownerPID),
             @"owner_process": _owner ? _owner.json : (id)NSNull.null,
             @"owner_identity_lookup_errno": @(_ownerLookupError),
             @"interface_user_client_pids": _creatorPIDs, @"known_camera_apps": _knownApps,
             @"current_user_ptpcamerad": daemons, @"other_usb_ptp_interfaces": _otherPTPInterfaces,
             @"inspection_error": _inspectionError ?: (id)NSNull.null,
             @"client_state": @"unknown",
             @"client_state_note": @"Interface ownership does not reveal all ImageCaptureCore/XPC clients. Close every camera/import app before explicitly restarting this user's camera service."};
}
@end

/* Pure decision function: no process, registry, signal, or clock operations. */
static NSString *guard_reason(ServiceSnapshot *s) {
    if (s.inspectionError) return @"inspection_error";
    if (s.knownApps.count) return @"camera_apps_running";
    if (s.callerUID == 0 || s.callerUID != s.callerEffectiveUID) return @"elevated_caller_refused";
    if (s.deviceCount > 1 || s.interfaceCount > 1) return @"ambiguous_s1h_interfaces";
    if (s.deviceCount == 0) return @"no_owner";
    if (![s.deviceModelState isEqualToString:@"confirmed"]) return @"unsupported_or_unknown_camera_model";
    if (s.interfaceCount != 1) return @"unknown_interface_owner";
    if ([s.ownerState isEqualToString:@"none"]) return @"no_owner";
    if (![s.ownerState isEqualToString:@"confirmed"] || s.ownerPID <= 1)
        return @"unknown_interface_owner";
    if (!s.owner) return @"owner_identity_unavailable";
    if (s.owner.startSeconds == 0) return @"owner_identity_unavailable";
    if (s.owner.uid != s.callerUID || s.owner.realUID != s.callerUID) return @"owner_uid_mismatch";
    if (![s.owner.path isEqualToString:ServiceExecutable]) return @"owner_executable_mismatch";
    if (s.owner.pid != s.ownerPID || s.creatorPIDs.count != 1 ||
        s.creatorPIDs.firstObject.intValue != s.ownerPID) return @"ownership_evidence_mismatch";
    if (s.daemons.count != 1 || ![s.daemons.firstObject isSameProcess:s.owner])
        return @"ambiguous_camera_services";
    if (s.otherPTPInterfaces.count) return @"other_usb_ptp_interface_present";
    return @"opt_in_required";
}

static NSDictionary *result(NSString *status, NSString *reason, ServiceSnapshot *snapshot,
                            NSArray<NSString *> *signals) {
    return @{@"status": status, @"reason": reason,
             @"signals_sent": signals ?: @[], @"inspection": snapshot.json,
             @"client_state": @"unknown"};
}

@protocol ServiceEnvironment <NSObject>
- (ServiceSnapshot *)inspect;
- (ServiceIdentity *)identityForPID:(pid_t)pid;
- (int)sendSignal:(int)signalNumber toProcess:(ServiceIdentity *)identity;
- (double)now;
- (void)pause:(NSTimeInterval)seconds;
@end

static ServiceIdentity *process_identity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) {
        if (!errno) errno = EIO;
        return nil;
    }
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof path) <= 0) {
        if (!errno) errno = EIO;
        return nil;
    }
    ServiceIdentity *identity = [ServiceIdentity new];
    identity.pid = pid;
    identity.uid = info.pbi_uid;
    identity.realUID = info.pbi_ruid;
    identity.startSeconds = info.pbi_start_tvsec;
    identity.startMicroseconds = info.pbi_start_tvusec;
    identity.path = [NSString stringWithUTF8String:path];
    return identity.path ? identity : nil;
}

static id registry_property(io_registry_entry_t entry, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0));
}

static NSUInteger registry_number(io_registry_entry_t entry, CFStringRef key, NSUInteger fallback) {
    id value = registry_property(entry, key);
    return [value isKindOfClass:NSNumber.class] ? [value unsignedIntegerValue] : fallback;
}

static NSString *registry_string(io_registry_entry_t entry, CFStringRef key) {
    id value = registry_property(entry, key);
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static pid_t label_pid(NSString *label) {
    const char *text = label.UTF8String;
    if (!text || strncmp(text, "pid ", 4) != 0) return 0;
    char *end = NULL;
    errno = 0;
    long value = strtol(text + 4, &end, 10);
    if (errno || end == text + 4 || !end || *end != ',' || value <= 1 || value > INT_MAX) return 0;
    return (pid_t)value;
}

static BOOL is_still_image_interface(io_registry_entry_t entry) {
    return IOObjectConformsTo(entry, "IOUSBHostInterface") &&
           registry_number(entry, CFSTR("bInterfaceClass"), NSUIntegerMax) == 6 &&
           registry_number(entry, CFSTR("bInterfaceSubClass"), NSUIntegerMax) == 1 &&
           registry_number(entry, CFSTR("bInterfaceProtocol"), NSUIntegerMax) == 1;
}

static NSString *product_model_state(NSString *name, NSString *alternate) {
    if (!name.length && !alternate.length) return @"unknown";
    if ((!name.length || [name isEqualToString:@"DC-S1H"]) &&
        (!alternate.length || [alternate isEqualToString:@"DC-S1H"])) return @"confirmed";
    return @"unsupported";
}

static NSString *owner_evidence_state(NSString *label, NSSet<NSNumber *> *creators,
                                      BOOL unidentifiableUserClient) {
    pid_t pid = label_pid(label);
    if (!label.length && creators.count == 0 && !unidentifiableUserClient) return @"none";
    if (pid > 1 && creators.count == 1 && [creators containsObject:@(pid)] &&
        !unidentifiableUserClient) return @"confirmed";
    return @"unknown";
}

static void inspect_owner(io_registry_entry_t interface, ServiceSnapshot *snapshot) {
    uint64_t interfaceID = 0;
    if (IORegistryEntryGetRegistryEntryID(interface, &interfaceID) != KERN_SUCCESS) {
        snapshot.inspectionError = @"Could not read the target interface registry ID.";
        return;
    }
    snapshot.interfaceID = interfaceID;
    snapshot.ownerLabel = registry_string(interface, CFSTR("UsbExclusiveOwner"));
    snapshot.ownerPID = label_pid(snapshot.ownerLabel);
    NSMutableSet<NSNumber *> *creatorPIDs = [NSMutableSet set];
    BOOL unreadableCreator = NO;
    io_iterator_t children = IO_OBJECT_NULL;
    kern_return_t kr = IORegistryEntryCreateIterator(interface, kIOServicePlane,
                                                      kIORegistryIterateRecursively, &children);
    if (kr != KERN_SUCCESS) {
        snapshot.inspectionError = @"Could not inspect the interface's registered user clients.";
        return;
    }
    io_registry_entry_t child;
    while ((child = IOIteratorNext(children))) {
        NSString *creator = registry_string(child, CFSTR("IOUserClientCreator"));
        if (creator.length) {
            pid_t pid = label_pid(creator);
            if (pid) [creatorPIDs addObject:@(pid)];
            else unreadableCreator = YES;
        } else if (IOObjectConformsTo(child, "IOUserClient")) unreadableCreator = YES;
        IOObjectRelease(child);
    }
    BOOL valid = IOIteratorIsValid(children);
    IOObjectRelease(children);
    if (!valid) {
        snapshot.inspectionError = @"The interface user-client registry changed during inspection.";
        return;
    }
    snapshot.creatorPIDs = [creatorPIDs.allObjects sortedArrayUsingSelector:@selector(compare:)];
    snapshot.ownerState = owner_evidence_state(snapshot.ownerLabel, creatorPIDs, unreadableCreator);
}

/* IOServiceGetMatchingServices explicitly permits KERN_SUCCESS with a NULL
 * iterator when no services match (IOKitLib.h). NULL is not an invalidated
 * iterator in that API's result. Every non-NULL matching iterator must still
 * pass the native validity check after exhaustion. The injected callback
 * keeps this distinction testable without touching IORegistry. This rule is
 * deliberately not applied to IORegistryEntryCreateIterator. */
static BOOL matching_iteration_complete(kern_return_t status, io_iterator_t iterator,
                                        BOOL (^isValid)(io_iterator_t)) {
    if (status != KERN_SUCCESS) return NO;
    if (iterator == IO_OBJECT_NULL) return YES;
    return isValid ? isValid(iterator) : NO;
}

static void inspect_registry(ServiceSnapshot *snapshot) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) { snapshot.inspectionError = @"Could not create the S1H registry query."; return; }
    CFDictionarySetValue(match, CFSTR("idVendor"), (__bridge CFNumberRef)@0x04da);
    CFDictionarySetValue(match, CFSTR("idProduct"), (__bridge CFNumberRef)@0x2382);
    io_iterator_t devices = IO_OBJECT_NULL;
    kern_return_t deviceMatchStatus = IOServiceGetMatchingServices(kIOMainPortDefault, match, &devices);
    if (deviceMatchStatus != KERN_SUCCESS) { snapshot.inspectionError = @"Could not enumerate S1H registry entries."; return; }
    io_registry_entry_t device;
    while (devices != IO_OBJECT_NULL && (device = IOIteratorNext(devices))) {
        ++snapshot.deviceCount;
        if (snapshot.deviceCount == 1) {
            NSString *name = registry_string(device, CFSTR("USB Product Name"));
            NSString *alternate = registry_string(device, CFSTR("kUSBProductString"));
            snapshot.productName = name.length ? name : alternate;
            snapshot.deviceModelState = product_model_state(name, alternate);
            snapshot.usbLinkSpeed = registry_number(device, CFSTR("UsbLinkSpeed"), 0);
        }
        io_iterator_t entries = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryCreateIterator(device, kIOServicePlane, kIORegistryIterateRecursively, &entries);
        if (kr != KERN_SUCCESS) snapshot.inspectionError = @"Could not inspect the S1H interface registry.";
        else {
            io_registry_entry_t entry;
            while ((entry = IOIteratorNext(entries))) {
                if (is_still_image_interface(entry) &&
                    registry_number(entry, CFSTR("bInterfaceNumber"), NSUIntegerMax) == 0) {
                    ++snapshot.interfaceCount;
                    if (snapshot.interfaceCount == 1) inspect_owner(entry, snapshot);
                }
                IOObjectRelease(entry);
            }
            if (!IOIteratorIsValid(entries))
                snapshot.inspectionError = @"The S1H interface registry changed during inspection.";
            IOObjectRelease(entries);
        }
        IOObjectRelease(device);
    }
    if (!matching_iteration_complete(deviceMatchStatus, devices, ^BOOL(io_iterator_t iterator) { return IOIteratorIsValid(iterator); }))
        snapshot.inspectionError = @"The matching device registry changed during inspection.";
    if (devices != IO_OBJECT_NULL) IOObjectRelease(devices);
    if (snapshot.deviceCount == 0) snapshot.ownerState = @"none";

    /* Only other still-image (06/01/01) interfaces matter. Do not refuse for
     * arbitrary USB hubs, keyboards, tablets, or browser device-level opens. */
    io_iterator_t interfaces = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &interfaces);
    if (kr != KERN_SUCCESS) { snapshot.inspectionError = @"Could not check other USB/PTP interfaces."; return; }
    NSMutableArray *others = [NSMutableArray array];
    io_registry_entry_t interface;
    while (interfaces != IO_OBJECT_NULL && (interface = IOIteratorNext(interfaces))) {
        uint64_t registryID = 0;
        IORegistryEntryGetRegistryEntryID(interface, &registryID);
        if (is_still_image_interface(interface) && registryID != snapshot.interfaceID) {
            NSString *owner = registry_string(interface, CFSTR("UsbExclusiveOwner"));
            [others addObject:@{@"registry_id": @(registryID), @"owner_pid": @(label_pid(owner)),
                               @"owner_present": @(owner.length > 0)}];
        }
        IOObjectRelease(interface);
    }
    if (!matching_iteration_complete(kr, interfaces, ^BOOL(io_iterator_t iterator) { return IOIteratorIsValid(iterator); }))
        snapshot.inspectionError = @"The USB/PTP interface registry changed during inspection.";
    if (interfaces != IO_OBJECT_NULL) IOObjectRelease(interfaces);
    snapshot.otherPTPInterfaces = others;
}

static NSArray<NSString *> *known_camera_names(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"lumix tether", @"preview", @"image capture", @"photos",
                 @"capture one", @"adobe lightroom classic", @"gphoto2", @"ptpcam", @"ptpcamera",
                 @"s1h_ptp_probe", @"s1h_iousbhost_probe"];
    });
    return names;
}

static BOOL known_camera_process(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [known_camera_names() containsObject:lower] || [lower hasPrefix:@"capture one "] ||
           [lower hasPrefix:@"adobe lightroom classic "];
}

/* Full executable basename is authoritative when available. proc_name may be
 * truncated; if the path is unavailable, a significant truncated camera-name
 * prefix must still be treated as a candidate and fail closed on identity.
 * This routine is pure and included in --self-test. */
static BOOL camera_process_candidate(NSString *reportedName, NSString *path) {
    if (path.length) return known_camera_process(path.lastPathComponent);
    if (known_camera_process(reportedName)) return YES;
    NSString *lower = reportedName.lowercaseString;
    if (lower.length >= MAXCOMLEN - 1) {
        for (NSString *canonical in known_camera_names())
            if (canonical.length > lower.length && [canonical hasPrefix:lower]) return YES;
    }
    return NO;
}

static void inspect_processes(ServiceSnapshot *snapshot) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 1000000) {
        snapshot.inspectionError = @"Could not enumerate process metadata for safety checks.";
        return;
    }
    int capacity = count + 512;
    pid_t *pids = calloc((size_t)capacity, sizeof *pids);
    if (!pids) { snapshot.inspectionError = @"Process metadata allocation failed."; return; }
    int actual = proc_listallpids(pids, capacity * (int)sizeof *pids);
    if (actual <= 0 || actual >= capacity) {
        snapshot.inspectionError = @"Process inventory was unavailable or truncated.";
        free(pids);
        return;
    }
    NSMutableArray *apps = [NSMutableArray array], *daemons = [NSMutableArray array];
    for (int i = 0; i < actual; ++i) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == getpid()) continue;
        char nameBytes[2 * MAXCOMLEN + 1] = {0};
        proc_name(pid, nameBytes, sizeof nameBytes);
        NSString *name = [NSString stringWithUTF8String:nameBytes] ?: @"";
        char pathBytes[PROC_PIDPATHINFO_MAXSIZE] = {0};
        NSString *observedPath = proc_pidpath(pid, pathBytes, sizeof pathBytes) > 0 ?
                                [NSString stringWithUTF8String:pathBytes] : nil;
        BOOL daemonCandidate = [observedPath isEqualToString:ServiceExecutable] ||
                               (!observedPath && [name isEqualToString:@"ptpcamerad"]);
        if (!daemonCandidate && !camera_process_candidate(name, observedPath)) continue;
        ServiceIdentity *identity = process_identity(pid);
        if (!identity) {
            /* A named candidate that exits concurrently is harmless; other
             * failures leave safety incomplete and must not permit signals. */
            if (errno != ESRCH)
                snapshot.inspectionError = @"Could not verify a relevant process identity.";
            continue;
        }
        if (identity.uid != snapshot.callerUID || identity.realUID != snapshot.callerUID) continue;
        if ([identity.path isEqualToString:ServiceExecutable]) [daemons addObject:identity];
        else if (known_camera_process(identity.path.lastPathComponent))
            [apps addObject:@{@"pid": @(pid), @"name": identity.path.lastPathComponent}];
    }
    free(pids);
    snapshot.knownApps = apps;
    snapshot.daemons = daemons;
    if (snapshot.ownerPID > 1) {
        snapshot.owner = process_identity(snapshot.ownerPID);
        snapshot.ownerLookupError = snapshot.owner ? 0 : errno;
    }
}

@interface LiveServiceEnvironment : NSObject <ServiceEnvironment>
@end
@implementation LiveServiceEnvironment
- (ServiceSnapshot *)inspect {
    ServiceSnapshot *snapshot = [ServiceSnapshot new];
    snapshot.callerUID = getuid();
    snapshot.callerEffectiveUID = geteuid();
    inspect_registry(snapshot);
    inspect_processes(snapshot);
    return snapshot;
}
- (ServiceIdentity *)identityForPID:(pid_t)pid { return process_identity(pid); }
- (int)sendSignal:(int)signalNumber toProcess:(ServiceIdentity *)identity {
    if (kill(identity.pid, signalNumber) == 0) return 0;
    return errno;
}
- (double)now {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}
- (void)pause:(NSTimeInterval)seconds {
    struct timespec delay = {(time_t)seconds, (long)((seconds - (time_t)seconds) * 1000000000.0)};
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}
@end

/* After a signal, the process may disappear before IORegistry removes its
 * old user-client node. This narrow state is observed only inside a bounded
 * wait. The earlier process-inventory read may still contain that exact old
 * identity; a different identity is never accepted. This state never
 * authorizes another signal, particularly KILL. */
static BOOL expected_shutdown_pending(ServiceSnapshot *s, ServiceIdentity *expected,
                                       uint64_t interfaceID) {
    return !s.inspectionError && s.knownApps.count == 0 &&
           s.callerUID != 0 && s.callerUID == s.callerEffectiveUID &&
           s.callerUID == expected.uid && s.deviceCount == 1 && s.interfaceCount == 1 &&
           [s.deviceModelState isEqualToString:@"confirmed"] &&
           s.interfaceID == interfaceID && [s.ownerState isEqualToString:@"confirmed"] &&
           s.ownerPID == expected.pid && s.creatorPIDs.count == 1 &&
           s.creatorPIDs.firstObject.intValue == expected.pid &&
           !s.owner && s.ownerLookupError == ESRCH &&
           (s.daemons.count == 0 ||
            (s.daemons.count == 1 && [s.daemons.firstObject isSameProcess:expected])) &&
           s.otherPTPInterfaces.count == 0;
}

/* Recheck both registry ownership and PID/start-time identity before every
 * signal. There is no Darwin pidfd API here; this minimizes, but cannot make
 * atomic, the final proc_pidinfo-to-kill interval. Explicit opt-in remains
 * mandatory and the caller must keep all camera applications closed. */
static NSDictionary *restart_service(id<ServiceEnvironment> environment) {
    ServiceSnapshot *initial = [environment inspect];
    NSString *reason = guard_reason(initial);
    if ([reason isEqualToString:@"no_owner"]) return result(@"not_needed", reason, initial, @[]);
    if (![reason isEqualToString:@"opt_in_required"]) return result(@"refused", reason, initial, @[]);
    ServiceIdentity *expected = initial.owner;
    uint64_t interfaceID = initial.interfaceID;
    NSMutableArray<NSString *> *signals = [NSMutableArray array];
    const int signalNumbers[2] = {SIGTERM, SIGKILL};
    const NSTimeInterval waits[2] = {TermWait, KillWait};
    for (int stage = 0; stage < 2; ++stage) {
        ServiceSnapshot *fresh = [environment inspect];
        reason = guard_reason(fresh);
        if ([reason isEqualToString:@"no_owner"]) return result(@"released", reason, fresh, signals);
        if (stage > 0 && expected_shutdown_pending(fresh, expected, interfaceID))
            return result(@"timeout", @"shutdown_pending_registry_not_released", fresh, signals);
        if (![reason isEqualToString:@"opt_in_required"]) return result(@"refused", reason, fresh, signals);
        if (fresh.interfaceID != interfaceID || ![fresh.owner isSameProcess:expected])
            return result(@"refused", @"ownership_or_process_identity_changed", fresh, signals);
        ServiceIdentity *lastIdentity = [environment identityForPID:expected.pid];
        if (![lastIdentity isSameProcess:expected])
            return result(@"refused", @"pid_identity_changed_before_signal", fresh, signals);
        int error = [environment sendSignal:signalNumbers[stage] toProcess:expected];
        if (error != 0) return result(@"refused", error == ESRCH ? @"process_exited_before_signal" : @"signal_failed", fresh, signals);
        [signals addObject:stage == 0 ? @"TERM" : @"KILL"];
        double deadline = [environment now] + waits[stage];
        while ([environment now] < deadline) {
            ServiceSnapshot *observed = [environment inspect];
            reason = guard_reason(observed);
            if ([reason isEqualToString:@"no_owner"]) return result(@"released", reason, observed, signals);
            if (expected_shutdown_pending(observed, expected, interfaceID)) {
                [environment pause:MIN(0.1, MAX(0.0, deadline - [environment now]))];
                continue;
            }
            if (![reason isEqualToString:@"opt_in_required"]) return result(@"refused", reason, observed, signals);
            if (observed.interfaceID != interfaceID || ![observed.owner isSameProcess:expected])
                return result(@"refused", @"ownership_or_process_identity_changed", observed, signals);
            [environment pause:MIN(0.1, MAX(0.0, deadline - [environment now]))];
        }
    }
    return result(@"timeout", @"interface_not_released_after_term_and_kill", [environment inspect], signals);
}

/* All simulation below is isolated from LiveServiceEnvironment and OS APIs. */
@interface FakeServiceEnvironment : NSObject <ServiceEnvironment>
@property(nonatomic, strong) ServiceSnapshot *snapshot;
@property(nonatomic, strong) ServiceIdentity *lookupIdentity;
@property(nonatomic) double clock;
@property(nonatomic) int releaseOnSignal;
@property(nonatomic) int signalError;
@property(nonatomic) BOOL reuseBeforeKill;
@property(nonatomic) BOOL cameraAppAfterTerm;
@property(nonatomic) BOOL delayedRegistryRelease;
@property(nonatomic) BOOL keepRegistryPending;
@property(nonatomic) BOOL retainShutdownInventory;
@property(nonatomic) NSUInteger signalCount;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *signalNumbers;
@end
@implementation FakeServiceEnvironment
- (instancetype)init {
    if ((self = [super init])) _signalNumbers = [NSMutableArray array];
    return self;
}
- (ServiceSnapshot *)inspect {
    if (_delayedRegistryRelease && !_keepRegistryPending && _signalCount >= 1 && _clock >= 0.3) {
        _snapshot.ownerState = @"none";
        _snapshot.ownerLabel = @"";
        _snapshot.ownerPID = 0;
        _snapshot.owner = nil;
        _snapshot.creatorPIDs = @[];
        _snapshot.daemons = @[];
    }
    return _snapshot;
}
- (ServiceIdentity *)identityForPID:(pid_t)pid {
    if (_reuseBeforeKill && _signalCount == 1) {
        ServiceIdentity *replacement = [ServiceIdentity new];
        replacement.pid = _lookupIdentity.pid;
        replacement.uid = _lookupIdentity.uid;
        replacement.realUID = _lookupIdentity.realUID;
        replacement.path = _lookupIdentity.path;
        replacement.startSeconds = _lookupIdentity.startSeconds + 1;
        replacement.startMicroseconds = _lookupIdentity.startMicroseconds;
        return replacement;
    }
    return pid == _lookupIdentity.pid ? _lookupIdentity : nil;
}
- (int)sendSignal:(int)signalNumber toProcess:(ServiceIdentity *)identity {
    (void)identity;
    ++_signalCount;
    [_signalNumbers addObject:@(signalNumber)];
    if (_signalError) return _signalError;
    if (_cameraAppAfterTerm && signalNumber == SIGTERM)
        _snapshot.knownApps = @[@{@"pid": @99999, @"name": @"LUMIX Tether"}];
    if (_delayedRegistryRelease && signalNumber == SIGTERM) {
        _snapshot.owner = nil;
        _snapshot.ownerLookupError = ESRCH;
        /* Process inventory and the final owner lookup are separate reads.
         * Reproduce the inventory retaining the just-exited target. */
        if (!_retainShutdownInventory) _snapshot.daemons = @[];
        _lookupIdentity = nil;
    }
    if (_releaseOnSignal == signalNumber) {
        _snapshot.ownerState = @"none";
        _snapshot.ownerLabel = @"";
        _snapshot.ownerPID = 0;
        _snapshot.owner = nil;
        _snapshot.creatorPIDs = @[];
        _snapshot.daemons = @[];
    }
    return 0;
}
- (double)now { return _clock; }
- (void)pause:(NSTimeInterval)seconds { _clock += seconds; }
@end

static ServiceIdentity *fake_identity(void) {
    ServiceIdentity *identity = [ServiceIdentity new];
    identity.pid = 90001;
    identity.uid = 501;
    identity.realUID = 501;
    identity.startSeconds = 1000;
    identity.startMicroseconds = 123;
    identity.path = ServiceExecutable;
    return identity;
}

static FakeServiceEnvironment *fake_environment(void) {
    FakeServiceEnvironment *environment = [FakeServiceEnvironment new];
    ServiceSnapshot *s = [ServiceSnapshot new];
    s.callerUID = 501;
    s.callerEffectiveUID = 501;
    s.deviceCount = 1;
    s.deviceModelState = @"confirmed";
    s.productName = @"DC-S1H";
    s.interfaceCount = 1;
    s.interfaceID = 777;
    s.ownerState = @"confirmed";
    s.ownerLabel = @"pid 90001, ptpcamerad";
    s.ownerPID = 90001;
    s.owner = fake_identity();
    s.creatorPIDs = @[@90001];
    s.daemons = @[s.owner];
    environment.snapshot = s;
    environment.lookupIdentity = s.owner;
    return environment;
}

static int self_test(void) {
    __block unsigned failures = 0, checks = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *name) {
        ++checks;
        if (!passed) ++failures;
        printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
    };
    __block unsigned validityCalls = 0;
    const io_iterator_t fixtureIterator = (io_iterator_t)12345;
    BOOL (^validIterator)(io_iterator_t) = ^BOOL(io_iterator_t iterator) {
        ++validityCalls;
        return iterator == fixtureIterator;
    };
    check(matching_iteration_complete(KERN_SUCCESS, IO_OBJECT_NULL, validIterator) && validityCalls == 0,
          @"Successful NULL matching result is empty and never queries iterator validity");
    check(!matching_iteration_complete(KERN_FAILURE, IO_OBJECT_NULL, validIterator) && validityCalls == 0,
          @"Failed matching request with NULL is an error, not a successful empty result");
    check(!matching_iteration_complete(KERN_FAILURE, fixtureIterator, validIterator) && validityCalls == 0,
          @"Failed matching request cannot be accepted even with a non-NULL handle");
    check(matching_iteration_complete(KERN_SUCCESS, fixtureIterator, validIterator) && validityCalls == 1,
          @"Non-NULL exhausted matching iterator requires and passes its injected validity check");
    check(!matching_iteration_complete(KERN_SUCCESS, fixtureIterator, ^BOOL(io_iterator_t iterator) {
        ++validityCalls;
        return iterator != fixtureIterator;
    }) && validityCalls == 2,
          @"A genuinely invalidated non-NULL matching iterator remains an error");
    check(!matching_iteration_complete(KERN_SUCCESS, fixtureIterator, nil),
          @"A non-NULL iterator without validity evidence fails closed");

    FakeServiceEnvironment *emptyMatch = fake_environment();
    emptyMatch.snapshot.deviceCount = 0; emptyMatch.snapshot.interfaceCount = 0;
    emptyMatch.snapshot.ownerState = @"none"; emptyMatch.snapshot.deviceModelState = @"unknown";
    if (!matching_iteration_complete(KERN_SUCCESS, IO_OBJECT_NULL, validIterator))
        emptyMatch.snapshot.inspectionError = @"Matching enumeration incomplete";
    check([restart_service(emptyMatch)[@"status"] isEqual:@"not_needed"] && emptyMatch.signalCount == 0 && validityCalls == 2,
          @"Normalized empty matching inventory reports no owner and sends no service signal");
    FakeServiceEnvironment *invalidMatch = fake_environment();
    if (!matching_iteration_complete(KERN_SUCCESS, fixtureIterator, ^BOOL(io_iterator_t iterator) { (void)iterator; return NO; }))
        invalidMatch.snapshot.inspectionError = @"Matching iterator invalidated";
    check([restart_service(invalidMatch)[@"reason"] isEqual:@"inspection_error"] && invalidMatch.signalCount == 0,
          @"Normalized invalidated matching inventory refuses service restart without signals");
    FakeServiceEnvironment *e = fake_environment();
    check([guard_reason(e.snapshot) isEqualToString:@"opt_in_required"], @"Verified ownership still requires explicit opt-in");
    for (NSString *name in @[@"LUMIX Tether", @"Preview", @"Image Capture", @"Photos", @"Capture One", @"Adobe Lightroom Classic", @"gphoto2", @"PTPCamera", @"s1h_iousbhost_probe"]) {
        e = fake_environment();
        e.snapshot.knownApps = @[@{@"pid": @99999, @"name": name}];
        NSDictionary *r = restart_service(e);
        check([r[@"reason"] isEqual:@"camera_apps_running"] && e.signalCount == 0 && known_camera_process(name),
              [@"Refuse running camera app: " stringByAppendingString:name]);
    }
    e = fake_environment(); e.snapshot.owner.uid = 502;
    check([restart_service(e)[@"reason"] isEqual:@"owner_uid_mismatch"] && e.signalCount == 0, @"Refuse owner with different UID");
    e = fake_environment(); e.snapshot.owner.path = @"/tmp/ptpcamerad";
    check([restart_service(e)[@"reason"] isEqual:@"owner_executable_mismatch"] && e.signalCount == 0, @"Refuse executable-name spoofing");
    e = fake_environment(); e.snapshot.callerEffectiveUID = 0;
    check([restart_service(e)[@"reason"] isEqual:@"elevated_caller_refused"] && e.signalCount == 0, @"Refuse privilege escalation");
    e = fake_environment(); e.snapshot.ownerState = @"unknown";
    check([restart_service(e)[@"reason"] isEqual:@"unknown_interface_owner"] && e.signalCount == 0, @"Refuse unknown interface owner");
    e = fake_environment(); e.snapshot.interfaceCount = 2;
    check([restart_service(e)[@"reason"] isEqual:@"ambiguous_s1h_interfaces"] && e.signalCount == 0, @"Refuse multiple target interfaces");
    e = fake_environment(); e.snapshot.deviceModelState = product_model_state(@"DC-GH5", @"DC-GH5");
    check([restart_service(e)[@"reason"] isEqual:@"unsupported_or_unknown_camera_model"] && e.signalCount == 0,
          @"A shared VID/PID does not authorize restarting for a GH5");
    e = fake_environment(); e.snapshot.deviceModelState = product_model_state(@"", @"");
    check([restart_service(e)[@"reason"] isEqual:@"unsupported_or_unknown_camera_model"] && e.signalCount == 0,
          @"Unknown product model refuses restart");
    check([product_model_state(@"", @"DC-S1H") isEqualToString:@"confirmed"] &&
          [product_model_state(@"DC-S1H", @"DC-G9") isEqualToString:@"unsupported"],
          @"Either non-conflicting S1H product property is accepted; conflicting properties refuse");
    check([owner_evidence_state(@"pid 90001, ptpcamerad", [NSSet setWithObject:@90001], YES) isEqual:@"unknown"],
          @"A user-client node without a creator keeps ownership unknown");
    check([owner_evidence_state(@"pid 90001, ptpcamerad", [NSSet setWithObject:@90001], NO) isEqual:@"confirmed"],
          @"Ordinary non-user-client children do not invalidate matching ownership evidence");
    e = fake_environment(); e.snapshot.inspectionError = @"Iterator invalidated by hot unplug";
    check([restart_service(e)[@"reason"] isEqual:@"inspection_error"] && e.signalCount == 0,
          @"Invalidated registry iteration fails closed");
    e = fake_environment(); e.snapshot.daemons = @[e.snapshot.owner, fake_identity()];
    check([restart_service(e)[@"reason"] isEqual:@"ambiguous_camera_services"] && e.signalCount == 0, @"Refuse multiple current-user daemons");
    e = fake_environment(); e.snapshot.otherPTPInterfaces = @[@{@"registry_id": @888}];
    check([restart_service(e)[@"reason"] isEqual:@"other_usb_ptp_interface_present"] && e.signalCount == 0, @"Refuse other USB/PTP cameras, including unknown owners");
    e = fake_environment(); e.snapshot.ownerState = @"none";
    check([restart_service(e)[@"status"] isEqual:@"not_needed"] && e.signalCount == 0, @"No owner requires no restart");
    e = fake_environment(); e.snapshot.ownerState = @"none"; e.snapshot.deviceCount = 0;
    e.snapshot.knownApps = @[@{@"pid": @99999, @"name": @"LUMIX Tether"}];
    check([restart_service(e)[@"reason"] isEqual:@"camera_apps_running"] && e.signalCount == 0,
          @"Refuse an active camera app even when no owner or device is present");
    e = fake_environment(); e.snapshot.ownerState = @"none"; e.snapshot.callerEffectiveUID = 0;
    check([restart_service(e)[@"reason"] isEqual:@"elevated_caller_refused"] && e.signalCount == 0,
          @"Refuse an elevated caller even when no owner is present");
    check(camera_process_candidate(@"Adobe Lightroom", @"/Applications/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic"),
          @"Full executable detects Lightroom despite truncated proc_name");
    check(camera_process_candidate(@"s1h_iousbhost_pro", @"/tmp/s1h_iousbhost_probe"),
          @"Full executable detects a PTP probe despite truncated proc_name");
    check(camera_process_candidate(@"s1h_iousbhost_pro", nil),
          @"A truncated camera name with unavailable path remains a safety candidate");
    check(!camera_process_candidate(@"s1h_iousbhost_pro", @"/tmp/unrelated-program"),
          @"Available unrelated full basename does not match a truncated camera hint");
    check(!camera_process_candidate(@"Google Chrome", @"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
          @"A browser is not classified as a camera app solely by device-level USB activity");
    e = fake_environment(); e.lookupIdentity = fake_identity(); e.lookupIdentity.startMicroseconds = 124;
    check([restart_service(e)[@"reason"] isEqual:@"pid_identity_changed_before_signal"] && e.signalCount == 0, @"Refuse PID reuse before TERM");
    e = fake_environment(); e.reuseBeforeKill = YES;
    check([restart_service(e)[@"reason"] isEqual:@"pid_identity_changed_before_signal"] && e.signalCount == 1,
          @"Refuse PID reuse before KILL after TERM timeout");
    e = fake_environment(); e.cameraAppAfterTerm = YES;
    check([restart_service(e)[@"reason"] isEqual:@"camera_apps_running"] && e.signalCount == 1,
          @"A camera app starting after TERM prevents KILL fallback");
    e = fake_environment(); e.releaseOnSignal = SIGTERM;
    check([restart_service(e)[@"status"] isEqual:@"released"] && [e.signalNumbers isEqual:@[@(SIGTERM)]], @"TERM releases interface without KILL");
    e = fake_environment(); e.delayedRegistryRelease = YES;
    check([restart_service(e)[@"status"] isEqual:@"released"] && e.signalCount == 1 && e.clock >= 0.3,
          @"A dead target with a transient old registry owner waits for registry removal");
    e = fake_environment(); e.delayedRegistryRelease = YES; e.retainShutdownInventory = YES;
    check([restart_service(e)[@"status"] isEqual:@"released"] && e.signalCount == 1 && e.clock >= 0.3,
          @"A cached inventory entry for the exited target only permits bounded waiting");
    e = fake_environment();
    ServiceIdentity *expected = e.snapshot.owner;
    e.snapshot.owner = nil; e.snapshot.ownerLookupError = ESRCH;
    ServiceIdentity *unexpected = fake_identity(); unexpected.pid += 1;
    e.snapshot.daemons = @[unexpected];
    check(!expected_shutdown_pending(e.snapshot, expected, e.snapshot.interfaceID),
          @"A different daemon in the shutdown inventory cannot authorize waiting or signals");
    unexpected.pid = expected.pid; unexpected.startMicroseconds += 1;
    check(!expected_shutdown_pending(e.snapshot, expected, e.snapshot.interfaceID),
          @"A reused PID in the shutdown inventory cannot authorize waiting or signals");
    e = fake_environment(); e.delayedRegistryRelease = YES; e.keepRegistryPending = YES;
    check([restart_service(e)[@"reason"] isEqual:@"shutdown_pending_registry_not_released"] && e.signalCount == 1 && e.clock >= TermWait,
          @"A dead target with persistent old registry owner times out without KILL");
    e = fake_environment(); e.releaseOnSignal = SIGKILL;
    check([restart_service(e)[@"status"] isEqual:@"released"] && [e.signalNumbers isEqual:@[@(SIGTERM), @(SIGKILL)]] && e.clock >= TermWait,
          @"TERM timeout permits revalidated KILL fallback");
    e = fake_environment();
    check([restart_service(e)[@"status"] isEqual:@"timeout"] && e.signalCount == 2 && e.clock >= TermWait + KillWait,
          @"TERM and KILL waits are bounded when interface never releases");
    e = fake_environment(); e.signalError = EPERM;
    check([restart_service(e)[@"reason"] isEqual:@"signal_failed"] && e.signalCount == 1, @"Signal denial does not escalate privileges");
    printf("Self-test: %u checks, %u failures; simulated only, no process or registry access.\n", checks, failures);
    return failures ? 1 : 0;
}

static void print_json(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) { fprintf(stderr, "Could not encode inspection result.\n"); return; }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL restart = NO, simulate = NO;
        if (argc == 2 && strcmp(argv[1], "--restart-camera-service") == 0) restart = YES;
        else if (argc == 2 && strcmp(argv[1], "--self-test") == 0) simulate = YES;
        else if (argc == 2 && strcmp(argv[1], "--help") == 0) {
            printf("Usage: %s [--inspect | --restart-camera-service | --self-test]\n", argv[0]);
            printf("Default/--inspect is read-only. Restart is explicit opt-in and may interrupt this user's camera import service.\n");
            printf("Close ALL camera/import applications first. Actual daemon client state cannot be proven empty.\n");
            return 0;
        } else if (!(argc == 1 || (argc == 2 && strcmp(argv[1], "--inspect") == 0))) {
            fprintf(stderr, "Usage: %s [--inspect | --restart-camera-service | --self-test]\n", argv[0]);
            return 2;
        }
        if (simulate) return self_test();
        /* A rare blocked system inspection must not leave a supervisor
         * waiting indefinitely. Only real modes reach this watchdog; fake
         * self-tests and argument/help handling remain entirely isolated.
         * Exiting this helper neither broadens the restart guard nor sends
         * an additional signal to its previously verified service target. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                fprintf(stderr, "Camera service helper exceeded its 18-second deadline; exiting this helper only (status 124).\n");
                _exit(124);
            });
        LiveServiceEnvironment *environment = [LiveServiceEnvironment new];
        if (!restart) {
            ServiceSnapshot *snapshot = [environment inspect];
            NSMutableDictionary *output = [snapshot.json mutableCopy];
            output[@"mode"] = @"inspect";
            output[@"read_only"] = @YES;
            output[@"restart_guard"] = guard_reason(snapshot);
            output[@"restart_requires_explicit_opt_in"] = @YES;
            print_json(output);
            return snapshot.inspectionError ? 1 : 0;
        }
        NSDictionary *output = restart_service(environment);
        print_json(output);
        return [@[@"released", @"not_needed"] containsObject:output[@"status"]] ? 0 : 1;
    }
}
