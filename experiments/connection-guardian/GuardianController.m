#import "GuardianController.h"
#import "GuardianEventLog.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <math.h>

static NSString *const GuardianBundleID = @"isb-152.LUMIXTether";
static double GuardianNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL GuardianIdentityShape(NSDictionary *identity) {
    if(![identity isKindOfClass:NSDictionary.class]) return NO;
    for(NSString *key in @[@"pid",@"uid",@"real_uid",@"start_seconds",@"start_microseconds"])
        if(![identity[key] isKindOfClass:NSNumber.class]) return NO;
    return [identity[@"pid"] intValue]>1 && [identity[@"start_seconds"] unsignedLongLongValue]>0 &&
        [identity[@"start_microseconds"] unsignedLongLongValue]<1000000 &&
        [identity[@"path"] isKindOfClass:NSString.class] && [identity[@"path"] isAbsolutePath];
}
static BOOL GuardianSameIdentity(NSDictionary *a, NSDictionary *b) {
    if (!GuardianIdentityShape(a) || !GuardianIdentityShape(b)) return NO;
    for (NSString *key in @[@"pid",@"uid",@"real_uid",@"start_seconds",@"start_microseconds",@"path"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static BOOL GuardianAcceptCompletion(uint64_t expected, uint64_t current, BOOL desired, BOOL stopping, BOOL tetherRunning) {
    return expected == current && desired && !stopping && !tetherRunning;
}
static BOOL GuardianObservationFresh(BOOL valid, double observedAt, double now, double maximumAge) {
    return valid && observedAt > 0 && isfinite(observedAt) && isfinite(now) &&
        maximumAge > 0 && isfinite(maximumAge) && now >= observedAt && now-observedAt <= maximumAge;
}
static NSString *GuardianCaptureState(BOOL processObservationValid, BOOL tetherRunning) {
    /* USB presence, interface ownership and a live process cannot prove
     * that Tether has connected, finished a transfer or can take a photo. */
    return processObservationValid && !tetherRunning ? @"not_running" : @"unknown";
}
static NSString *GuardianEndDecision(BOOL ending, BOOL stopping, BOOL helperBusy, BOOL launchBusy,
                                     BOOL quitPending, BOOL observationValid, BOOL tetherAbsent) {
    if(!ending || stopping) return @"none";
    if(helperBusy || launchBusy) return @"wait_work";
    if(quitPending) return @"wait_quit";
    if(!observationValid) return @"unknown";
    return tetherAbsent ? @"settled" : @"request_verified_quit";
}
static BOOL GuardianForceModeAllowed(BOOL ending, BOOL requestedEnding, BOOL canForce, BOOL quitPending, NSString *purpose) {
    return canForce && quitPending && ending==requestedEnding &&
        requestedEnding==[purpose isEqual:@"end"];
}
static NSDictionary *GuardianSafeEventFields(NSDictionary *fields) {
    if(![fields isKindOfClass:NSDictionary.class]) return @{};
    NSSet *strings=[NSSet setWithArray:@[@"source",@"request_source",@"result",@"reason",@"state",@"previous_state",
        @"helper_kind",@"purpose",@"quit_purpose",@"phase",@"trigger",@"mode",@"app_version",@"attempt_id",
        @"launch_attempt_id",@"helper_attempt_id",@"session_id",@"correlation_id",@"observation",@"verification",@"error_domain",@"blocking_app"]];
    NSSet *numbers=[NSSet setWithArray:@[@"pid",@"tether_pid",@"previous_pid",@"start_seconds",@"start_microseconds",
        @"exit_status",@"error_code",@"generation",@"retry_count",@"duration_ms",@"usb_link_speed_bps",@"device_count",
        @"interface_count",@"expired",@"initial",@"verified",@"success",@"accepted",@"desired_running",@"ending_session",
        @"session_ended",@"tether_running",@"stopping",@"busy",@"normal_quit_delivered",@"already_running",@"observed",@"blocking_app_count"]];
    NSCharacterSet *unsafe=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"] invertedSet];
    NSMutableDictionary *safe=[NSMutableDictionary dictionary];
    for(NSString *key in fields) {
        id value=fields[key];
        if([strings containsObject:key] && [value isKindOfClass:NSString.class] && [value length]>0 && [value length]<=128 &&
            [value rangeOfCharacterFromSet:unsafe].location==NSNotFound) safe[key]=value;
        else if([numbers containsObject:key] && [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) safe[key]=value;
    }
    return safe;
}
static NSDictionary *GuardianSafeIdentityFields(NSDictionary *identity) {
    if(!GuardianIdentityShape(identity)) return @{};
    return @{@"pid":identity[@"pid"],@"start_seconds":identity[@"start_seconds"],@"start_microseconds":identity[@"start_microseconds"]};
}
static NSString *GuardianInspectionReadiness(NSDictionary *inspection, BOOL tetherRunning) {
    if (tetherRunning) return @"tether_running";
    if (![inspection isKindOfClass:NSDictionary.class] ||
        (inspection[@"inspection_error"] && inspection[@"inspection_error"] != NSNull.null)) return @"inspection_error";
    for (NSString *key in @[@"matching_usb_id_device_count",@"s1h_device_count",@"s1h_interface_count",@"interface_registry_id"])
        if (![inspection[key] isKindOfClass:NSNumber.class]) return @"inspection_error";
    if(![inspection[@"device_model_state"] isKindOfClass:NSString.class]) return @"inspection_error";
    if (![inspection[@"known_camera_apps"] isKindOfClass:NSArray.class] ||
        ![inspection[@"other_usb_ptp_interfaces"] isKindOfClass:NSArray.class]) return @"inspection_error";
    if ([inspection[@"known_camera_apps"] count]) return @"camera_apps_running";
    if ([inspection[@"matching_usb_id_device_count"] unsignedIntegerValue] == 0) return @"no_device";
    if (![inspection[@"device_model_state"] isEqual:@"confirmed"] ||
        [inspection[@"matching_usb_id_device_count"] unsignedIntegerValue] != 1 ||
        [inspection[@"s1h_device_count"] unsignedIntegerValue] != 1 ||
        [inspection[@"s1h_interface_count"] unsignedIntegerValue] != 1 ||
        [inspection[@"interface_registry_id"] unsignedLongLongValue] == 0) return @"ambiguous_device";
    if ([inspection[@"other_usb_ptp_interfaces"] count]) return @"other_camera";
    return nil;
}
static NSArray<NSDictionary *> *GuardianBlockingCameraApps(NSDictionary *inspection) {
    id rows=[inspection isKindOfClass:NSDictionary.class] ? inspection[@"known_camera_apps"] : nil;
    if(![rows isKindOfClass:NSArray.class]) return @[];
    NSDictionary *known=@{
        @"lumix tether":@[@"LUMIX Tether",@"lumix_tether"], @"lumixtether":@[@"LUMIX Tether",@"lumix_tether"],
        @"preview":@[@"Preview",@"preview"], @"image capture":@[@"Image Capture",@"image_capture"],
        @"photos":@[@"Photos",@"photos"], @"capture one":@[@"Capture One",@"capture_one"],
        @"adobe lightroom classic":@[@"Adobe Lightroom Classic",@"lightroom_classic"],
        @"gphoto2":@[@"gphoto2",@"gphoto2"], @"ptpcam":@[@"ptpcam",@"ptpcam"],
        @"ptpcamera":@[@"PTPCamera",@"ptpcamera"], @"s1h_ptp_probe":@[@"S1H PTP Probe",@"s1h_ptp_probe"],
        @"s1h_iousbhost_probe":@[@"S1H USB Recovery",@"s1h_usb_recovery"]};
    NSMutableArray *result=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for(id row in rows) {
        if(![row isKindOfClass:NSDictionary.class]) continue;
        id raw=row[@"name"];
        NSString *name=[raw isKindOfClass:NSString.class] ? [raw lowercaseString] : @"";
        NSArray *label=known[name];
        if(!label && [name hasPrefix:@"capture one "] && ![name containsString:@"/"]) label=known[@"capture one"];
        if(!label && [name hasPrefix:@"adobe lightroom classic "] && ![name containsString:@"/"]) label=known[@"adobe lightroom classic"];
        if(!label) label=@[@"Other camera application",@"other_camera_app"];
        NSMutableDictionary *item=[@{@"name":label[0],@"identifier":label[1]} mutableCopy];
        id pid=row[@"pid"];
        if([pid isKindOfClass:NSNumber.class] && isfinite([pid doubleValue]) && floor([pid doubleValue])==[pid doubleValue] &&
            [pid doubleValue]>=2 && [pid doubleValue]<=INT_MAX) item[@"pid"]=pid;
        NSString *key=[NSString stringWithFormat:@"%@:%@",item[@"identifier"],item[@"pid"] ?: @"unknown"];
        if(![seen containsObject:key]) { [seen addObject:key]; [result addObject:item]; }
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult order=[a[@"identifier"] compare:b[@"identifier"]];
        return order==NSOrderedSame ? [a[@"pid"] ?: @0 compare:b[@"pid"] ?: @0] : order;
    }];
    return result;
}
static NSString *GuardianPublishedGate(NSDictionary *inspection, BOOL processValid, BOOL inspectionValid, BOOL tetherRunning) {
    if(!processValid) return @"process_observation_unknown";
    if(!inspectionValid) return @"inspection_error";
    return GuardianInspectionReadiness(inspection,tetherRunning) ?: @"ready";
}
static NSDictionary *GuardianProcessIdentity(pid_t pid) {
    if (pid <= 1) return nil;
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof info) != sizeof info ||
        proc_pidpath(pid,path,sizeof path) <= 0 || !info.pbi_start_tvsec) return nil;
    NSString *name = [NSString stringWithUTF8String:path];
    if (!name) return nil;
    return @{@"pid":@(pid),@"uid":@(info.pbi_uid),@"real_uid":@(info.pbi_ruid),
        @"start_seconds":@(info.pbi_start_tvsec),@"start_microseconds":@(info.pbi_start_tvusec),
        @"path":name.stringByResolvingSymlinksInPath};
}
static BOOL GuardianTetherName(NSString *name) {
    return [name.lowercaseString isEqual:@"lumix tether"] || [name.lowercaseString isEqual:@"lumixtether"];
}
/* A positive launch-in-progress observation blocks recovery even before
 * LaunchServices has registered the application. Enumeration errors also
 * block recovery; they are never interpreted as Tether being absent. */
static NSArray<NSNumber *> *GuardianTetherPIDs(BOOL *reliable) {
    if (reliable) *reliable = NO;
    int count = proc_listallpids(NULL,0);
    if (count <= 0) return @[];
    NSUInteger capacity = (NSUInteger)count + 64;
    pid_t *pids = calloc(capacity,sizeof(pid_t));
    if (!pids) return @[];
    int found = proc_listallpids(pids,(int)(capacity * sizeof(pid_t)));
    if (found <= 0 || (NSUInteger)found >= capacity) { free(pids); return @[]; }
    NSMutableSet *matches = [NSMutableSet set];
    for (int i=0;i<found;++i) {
        if (pids[i] <= 1) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i],path,sizeof path) > 0) {
            NSString *value = [NSString stringWithUTF8String:path];
            if (GuardianTetherName(value.lastPathComponent)) [matches addObject:@(pids[i])];
        } else {
            char name[64] = {0};
            if (proc_name(pids[i],name,sizeof name) > 0 && GuardianTetherName([NSString stringWithUTF8String:name]))
                [matches addObject:@(pids[i])];
        }
    }
    free(pids);
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:GuardianBundleID])
        if (!app.terminated) [matches addObject:@(app.processIdentifier)];
    if (reliable) *reliable = YES;
    return [matches.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
static SecRequirementRef GuardianRequirement(void) CF_RETURNS_RETAINED {
    SecRequirementRef requirement = NULL;
    NSString *text = @"anchor apple generic and identifier \"isb-152.LUMIXTether\" and certificate leaf[subject.OU] = \"7R6S626R47\"";
    if (SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&requirement) != errSecSuccess) return NULL;
    return requirement;
}
static BOOL GuardianValidTetherURL(NSURL *url) {
    if (!url.isFileURL) return NO;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqual:GuardianBundleID] ||
        ![info[@"CFBundleShortVersionString"] isEqual:@"2.12"] ||
        !GuardianTetherName(info[@"CFBundleExecutable"])) return NO;
    SecStaticCodeRef code = NULL; SecRequirementRef requirement = GuardianRequirement();
    BOOL valid = requirement && SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code) == errSecSuccess &&
        /* Match the established recovery script's --verify --deep policy.
         * Finder metadata on an otherwise valid installed vendor app is not
         * a payload-signature failure and is not changed by this tool. */
        SecStaticCodeCheckValidity(code,kSecCSCheckAllArchitectures | kSecCSCheckNestedCode,requirement) == errSecSuccess;
    if (code) CFRelease(code); if (requirement) CFRelease(requirement);
    return valid;
}
static BOOL GuardianValidRunningTether(NSDictionary *identity, NSRunningApplication **application) {
    if (!identity || [identity[@"uid"] unsignedIntValue] != getuid() ||
        [identity[@"real_uid"] unsignedIntValue] != getuid()) return NO;
    pid_t pid = [identity[@"pid"] intValue];
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated || ![app.bundleIdentifier isEqual:GuardianBundleID] ||
        ![app.executableURL.path.stringByResolvingSymlinksInPath isEqual:identity[@"path"]] ||
        !GuardianValidTetherURL(app.bundleURL)) return NO;
    SecCodeRef code = NULL; SecRequirementRef requirement = GuardianRequirement();
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid:@(pid)};
    BOOL valid = requirement && SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)attributes,kSecCSDefaultFlags,&code) == errSecSuccess &&
        SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement) == errSecSuccess;
    if (code) CFRelease(code); if (requirement) CFRelease(requirement);
    if (!GuardianSameIdentity(identity,GuardianProcessIdentity(pid))) valid = NO;
    if (valid && application) *application = app;
    return valid;
}
static NSString *GuardianLanguage(void) {
    NSString *language = [NSLocale.preferredLanguages.firstObject componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject.lowercaseString;
    return [@[@"zh",@"en",@"ja",@"de",@"es",@"fr",@"it",@"ru"] containsObject:language] ? language : @"en";
}

@interface GuardianController ()
@property(nonatomic,strong) NSURL *resources;
@property(nonatomic,copy) void (^onUpdate)(NSDictionary *);
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,strong) NSTask *task;
@property(nonatomic,strong) NSFileHandle *taskLog;
@property(nonatomic,copy) NSString *taskKind;
@property(nonatomic,copy) NSString *logDirectory;
@property(nonatomic,strong) GuardianEventLog *eventLog;
@property(nonatomic,copy) NSString *recoverySource;
@property(nonatomic,copy) NSString *launchSource;
@property(nonatomic,copy) NSString *activeLaunchSource;
@property(nonatomic,copy) NSString *launchAttemptID;
@property(nonatomic,copy) NSString *quitRequestID;
@property(nonatomic) BOOL quitTimeoutLogged;
@property(nonatomic) BOOL stoppingLogged;
@property(nonatomic) BOOL stoppedLogged;
@property(nonatomic) BOOL inspectionErrorLogged;
@property(nonatomic) BOOL inspectionStateObserved;
@property(nonatomic) BOOL processStateObserved;
@property(nonatomic) BOOL observedProcessPresent;
@property(nonatomic) BOOL processObservationErrorLogged;
@property(nonatomic,strong) NSDictionary *observedProcessIdentity;
@property(nonatomic,strong) NSDictionary *inspection;
@property(nonatomic,strong) NSArray<NSDictionary *> *blockingCameraApps;
@property(nonatomic,copy) NSString *lastRecoveryGate;
@property(nonatomic,copy) NSString *lastRecoveryGateSignature;
@property(nonatomic,strong) NSArray<NSDictionary *> *lastRecoveryGateApps;
@property(nonatomic,strong) NSDictionary *quitIdentity;
@property(nonatomic,strong) NSDictionary *ownedIdentity;
@property(nonatomic,strong) NSMutableArray<dispatch_block_t> *stopCompletions;
/* Main-queue launch/quit handoffs read these scalar cancellation gates. */
@property(atomic) uint64_t generation;
@property(atomic) BOOL desired;
@property(atomic) BOOL stopping;
@property(nonatomic) BOOL pendingRecovery;
@property(nonatomic) BOOL devicePresent;
@property(nonatomic) BOOL tetherRunning;
@property(nonatomic) BOOL previousTetherRunning;
@property(nonatomic) BOOL tetherObservationValid;
@property(nonatomic) BOOL inspectionObservationValid;
@property(nonatomic) double tetherObservedAt;
@property(nonatomic) double inspectionObservedAt;
@property(atomic) BOOL endingSession;
@property(nonatomic) BOOL sessionEnded;
@property(nonatomic) BOOL endQuitAttempted;
@property(atomic) BOOL normalQuitDelivered;
@property(nonatomic) BOOL publishedTetherObservationValid;
@property(nonatomic) BOOL publishedInspectionObservationValid;
@property(nonatomic) BOOL canForce;
@property(atomic) BOOL quitRequested;
@property(nonatomic) BOOL launching;
@property(nonatomic) BOOL sawTetherDuringHelper;
@property(nonatomic) BOOL taskExpired;
@property(nonatomic) uint64_t interfaceID;
@property(nonatomic) NSUInteger retryCount;
@property(nonatomic) double nextInspect;
@property(nonatomic) double recoverAfter;
@property(nonatomic) double quitDeadline;
@property(nonatomic,copy) NSString *quitPurpose;
@property(nonatomic,copy) NSString *state;
@property(nonatomic,copy) NSString *messageZH;
@property(nonatomic,copy) NSString *messageEN;
- (void)advanceEndSession;
- (void)receiveLaunchResult:(NSDictionary *)verifiedIdentity success:(BOOL)success generation:(uint64_t)generation;
- (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields;
- (void)observeTetherPresence:(BOOL)present observationValid:(BOOL)valid identity:(NSDictionary *)identity;
- (void)observeRecoveryGate:(NSString *)reason;
- (void)publishRecoveryGate:(NSString *)reason;
@end

@implementation GuardianController
- (instancetype)initWithResourceDirectory:(NSURL *)directory onUpdate:(void (^)(NSDictionary *))onUpdate {
    if ((self=[super init])) {
        _resources=directory; _onUpdate=[onUpdate copy];
        _queue=dispatch_queue_create("local.s1h.connection-guardian.state",DISPATCH_QUEUE_SERIAL);
        _stopCompletions=[NSMutableArray array]; _state=@"idle";
        _messageZH=@"已暂停。点击“开始守护”后自动准备相机连接。";
        _messageEN=@"Paused. Choose Start Guardian to prepare camera connections automatically.";
        _logDirectory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/S1H Connection Guardian"];
        _eventLog=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:_logDirectory isDirectory:YES]];
        NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        [self recordEvent:@"app_started" fields:version ? @{@"app_version":version} : @{}];
        _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
        dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/2,NSEC_PER_SEC/20);
        __weak GuardianController *weakSelf=self;
        dispatch_source_set_event_handler(_timer,^{ [weakSelf tick]; }); dispatch_resume(_timer);
        dispatch_async(_queue,^{ [weakSelf republish]; });
    }
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields {
    NSMutableDictionary *safe=[GuardianSafeEventFields(fields ?: @{}) mutableCopy];
    if([event hasPrefix:@"user_"] && !safe[@"phase"]) safe[@"phase"]=@"requested";
    if(!safe[@"generation"]) safe[@"generation"]=@(self.generation);
    safe[@"desired_running"]=@(self.desired);
    safe[@"ending_session"]=@(self.endingSession); safe[@"stopping"]=@(self.stopping);
    [self.eventLog recordEvent:event fields:safe];
}
- (void)observeTetherPresence:(BOOL)present observationValid:(BOOL)valid identity:(NSDictionary *)identity {
    self.tetherObservationValid=valid;
    if(!valid) {
        if(!self.processObservationErrorLogged) [self recordEvent:@"process_observation_error" fields:@{@"reason":@"process_inventory_unavailable"}];
        self.processObservationErrorLogged=YES; return;
    }
    if(self.processObservationErrorLogged) [self recordEvent:@"process_observation_recovered" fields:@{}];
    self.processObservationErrorLogged=NO;
    BOOL initial=!self.processStateObserved;
    BOOL changed=initial || present!=self.observedProcessPresent;
    BOOL replaced=present && self.observedProcessPresent && self.observedProcessIdentity && GuardianIdentityShape(identity) &&
        !GuardianSameIdentity(self.observedProcessIdentity,identity);
    BOOL identityAvailable=present && self.observedProcessPresent && !self.observedProcessIdentity && GuardianIdentityShape(identity);
    if(changed || replaced || identityAvailable) {
        NSString *phase=initial ? @"startup" : replaced ? @"identity_changed" : identityAvailable ? @"identity_available" : present ? @"appeared" : @"exited";
        NSDictionary *eventIdentity=present ? identity : self.observedProcessIdentity;
        NSMutableDictionary *fields=[GuardianSafeIdentityFields(eventIdentity) mutableCopy];
        [fields addEntriesFromDictionary:@{@"phase":phase,@"source":@"external_or_unknown",@"initial":@(initial),
            @"observed":@YES,@"tether_running":@(present),@"verification":@"process_observation"}];
        [self recordEvent:@"tether_observed" fields:fields];
    }
    self.processStateObserved=YES; self.observedProcessPresent=present;
    if(!present) self.observedProcessIdentity=nil;
    else if(GuardianIdentityShape(identity)) self.observedProcessIdentity=identity;
    self.tetherObservedAt=GuardianNow(); self.tetherRunning=present;
    if(present && !self.endingSession) self.sessionEnded=NO;
}
- (void)publish:(NSString *)state zh:(NSString *)zh en:(NSString *)en {
    self.state=state; self.messageZH=zh; self.messageEN=en;
    double now=GuardianNow();
    BOOL processValid=GuardianObservationFresh(self.tetherObservationValid,self.tetherObservedAt,now,2.0);
    BOOL inspectionValid=GuardianObservationFresh(self.inspectionObservationValid,self.inspectionObservedAt,now,4.0);
    BOOL forceEnd=self.canForce && self.quitRequested && self.endingSession && [self.quitPurpose isEqual:@"end"];
    BOOL forceRestart=self.canForce && self.quitRequested && !self.endingSession && ![self.quitPurpose isEqual:@"end"];
    self.publishedTetherObservationValid=processValid; self.publishedInspectionObservationValid=inspectionValid;
    NSString *gate=GuardianPublishedGate(self.inspection,processValid,inspectionValid,self.tetherRunning);
    [self observeRecoveryGate:gate];
    NSMutableArray *visibleBlockers=[NSMutableArray array];
    if(inspectionValid) for(NSDictionary *app in self.blockingCameraApps)
        if(!(processValid && self.tetherRunning && [app[@"identifier"] isEqual:@"lumix_tether"])) [visibleBlockers addObject:app];
    NSMutableDictionary *snapshot=[@{@"state":state,@"message_zh":zh,@"message_en":en,
        @"desired_running":@(self.desired),@"device_present":@(self.devicePresent),
        @"tether_running":@(self.tetherRunning),@"can_force_restart":@(forceRestart),@"can_force_quit":@(forceEnd),
        @"force_action":forceEnd ? @"quit" : forceRestart ? @"restart" : @"none",
        @"ending_session":@(self.endingSession),@"session_ended":@(self.sessionEnded && processValid && !self.tetherRunning),
        @"tether_observation_valid":@(processValid),@"inspection_observation_valid":@(inspectionValid),
        @"tether_observed_at":@(self.tetherObservedAt),@"inspection_observed_at":@(self.inspectionObservedAt),
        @"observation_monotonic_seconds":@(now),
        @"inspection_gate":gate,@"blocking_camera_apps":visibleBlockers,
        @"capture_state":GuardianCaptureState(processValid,self.tetherRunning),@"shooting_verified":@NO,
        @"busy":@((BOOL)(self.task || self.quitRequested || self.launching || self.endingSession)),
        @"retry_count":@(self.retryCount),@"log_directory":self.logDirectory} mutableCopy];
    if (self.inspection) snapshot[@"inspection"]=self.inspection;
    NSNumber *speed=self.inspection[@"usb_link_speed_bps"];
    if ([speed isKindOfClass:NSNumber.class]) snapshot[@"usb_link_speed_bps"]=speed;
    void (^handler)(NSDictionary *)=self.onUpdate;
    dispatch_async(dispatch_get_main_queue(),^{ if (handler) handler(snapshot); });
}
- (void)observeRecoveryGate:(NSString *)reason {
    NSString *gate=reason ?: @"ready";
    /* A working Tether process is the intended handoff, not a recovery
     * failure. Passive/paused observations also do not create block events. */
    if(!self.desired || !self.pendingRecovery || (self.tetherObservationValid && self.tetherRunning) || [gate isEqual:@"tether_running"]) return;
    NSArray<NSDictionary *> *apps=[gate isEqual:@"camera_apps_running"] ? self.blockingCameraApps ?: @[] : @[];
    NSMutableArray *parts=[NSMutableArray arrayWithObject:gate];
    for(NSDictionary *app in apps) [parts addObject:[NSString stringWithFormat:@"%@:%@",app[@"identifier"],app[@"pid"] ?: @"unknown"]];
    NSString *signature=[parts componentsJoinedByString:@";"];
    if([signature isEqual:self.lastRecoveryGateSignature]) return;
    NSString *previous=self.lastRecoveryGate;
    NSArray *previousApps=self.lastRecoveryGateApps ?: @[];
    self.lastRecoveryGate=gate; self.lastRecoveryGateSignature=signature; self.lastRecoveryGateApps=apps;
    if([gate isEqual:@"ready"]) {
        if(previous && ![previous isEqual:@"ready"]) [self recordEvent:@"recovery_unblocked" fields:@{
            @"reason":previous,@"blocking_app_count":@0,@"blocking_app":previousApps.count==1 ? previousApps[0][@"identifier"] : @"none"}];
        return;
    }
    [self recordEvent:@"recovery_blocked" fields:@{@"reason":gate,@"blocking_app_count":@(apps.count),
        @"blocking_app":apps.count==1 ? apps[0][@"identifier"] : apps.count ? @"multiple" : @"none"}];
    if(apps.count>1) for(NSDictionary *app in apps) {
        NSMutableDictionary *fields=[@{@"reason":gate,@"blocking_app_count":@(apps.count),@"blocking_app":app[@"identifier"]} mutableCopy];
        if(app[@"pid"]) fields[@"pid"]=app[@"pid"];
        [self recordEvent:@"recovery_blocked_app" fields:fields];
    }
}
- (void)publishRecoveryGate:(NSString *)reason {
    [self observeRecoveryGate:reason];
    if([reason isEqual:@"camera_apps_running"] && self.blockingCameraApps.count) {
        NSMutableArray *names=[NSMutableArray array];
        for(NSDictionary *app in self.blockingCameraApps) [names addObject:app[@"name"]];
        NSString *joined=[names componentsJoinedByString:@", "];
        [self publish:@"blocked" zh:[NSString stringWithFormat:@"检测到 %@ 正在运行。请正常退出后，连接准备会自动继续；这不表示它已占用相机。",joined]
            en:[NSString stringWithFormat:@"%@ is running. Quit it normally and preparation will continue automatically; its presence does not prove camera ownership.",joined]];
    } else if([reason isEqual:@"no_device"]) [self publish:@"waiting_device" zh:@"等待 S1H USB 连接，请选择 PC(Tether)。" en:@"Waiting for S1H over USB. Select PC(Tether)."];
    else if([reason isEqual:@"process_observation_unknown"] || [reason isEqual:@"inspection_error"])
        [self publish:@"inspection_error" zh:@"暂时无法确认相机软件或连接状态；将继续只读检查，不会启动恢复。" en:@"Camera application or connection state is unknown. Read-only checks will continue without starting recovery."];
    else [self publish:@"blocked" zh:@"安全检查尚未通过，请关闭其他相机软件并检查连接。" en:@"Safety checks are not ready. Close other camera applications and check the connection."];
}
- (void)republish { [self publish:self.state zh:self.messageZH en:self.messageEN]; }
- (void)publishObservationFreshnessIfNeeded {
    double now=GuardianNow();
    if(self.publishedTetherObservationValid!=GuardianObservationFresh(self.tetherObservationValid,self.tetherObservedAt,now,2.0) ||
        self.publishedInspectionObservationValid!=GuardianObservationFresh(self.inspectionObservationValid,self.inspectionObservedAt,now,4.0))
        [self republish];
}
- (BOOL)tetherAbsent {
    BOOL reliable=NO; NSArray *pids=GuardianTetherPIDs(&reliable);
    NSDictionary *identity=reliable && pids.count==1 ? GuardianProcessIdentity([pids.firstObject intValue]) : nil;
    [self observeTetherPresence:pids.count>0 observationValid:reliable identity:identity];
    return reliable && !self.tetherRunning;
}
- (NSURL *)helper:(NSString *)name { return [self.resources URLByAppendingPathComponent:name]; }
- (void)finishStoppingIfPossible {
    if (!self.stopping || self.task || self.launching) return;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer=nil; }
    [self publish:@"stopped"
        zh:self.normalQuitDelivered ? @"守护工具已停止；此前发给 Tether 的退出请求无法撤回。" : @"守护工具已停止；Tether 保持当前状态。"
        en:self.normalQuitDelivered ? @"Guardian stopped. The earlier Tether quit request cannot be withdrawn." : @"Guardian stopped; Tether was left as it was."];
    if(!self.stoppedLogged) { self.stoppedLogged=YES; [self recordEvent:@"app_stopped" fields:@{}]; [self.eventLog flush]; }
    NSArray *blocks=[self.stopCompletions copy]; [self.stopCompletions removeAllObjects];
    dispatch_async(dispatch_get_main_queue(),^{ for(dispatch_block_t block in blocks) block(); });
}
- (void)runHelper:(NSString *)name arguments:(NSArray<NSString *> *)arguments kind:(NSString *)kind
          timeout:(double)timeout completion:(void (^)(int,NSDictionary *,BOOL))completion {
    BOOL significant=[@[@"repair",@"service-restart"] containsObject:kind];
    NSString *helperID=significant ? NSUUID.UUID.UUIDString : nil;
    NSString *source=self.recoverySource ?: @"unknown";
    uint64_t generation=self.generation; double began=GuardianNow();
    if (self.task || self.stopping) {
        if(significant) [self recordEvent:@"helper_error" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,@"reason":@"controller_busy_or_stopping",@"source":source,@"generation":@(generation)}];
        completion(-1,nil,YES); return;
    }
    NSURL *url=[self helper:name];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:url.path]) {
        if(significant) [self recordEvent:@"helper_error" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,@"reason":@"helper_unavailable",@"source":source,@"generation":@(generation)}];
        completion(-1,nil,NO); return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:self.logDirectory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    NSString *fileName=[kind isEqual:@"inspect"] ? @"latest-inspection.log" : [NSString stringWithFormat:@"%@-%@.log",kind,NSUUID.UUID.UUIDString];
    NSString *file=[self.logDirectory stringByAppendingPathComponent:fileName];
    [NSFileManager.defaultManager createFileAtPath:file contents:[NSData data] attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *log=[NSFileHandle fileHandleForWritingAtPath:file];
    if (!log) {
        if(significant) [self recordEvent:@"helper_error" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,@"reason":@"diagnostic_log_unavailable",@"source":source,@"generation":@(generation)}];
        completion(-1,nil,NO); return;
    }
    NSTask *task=[NSTask new]; task.executableURL=url; task.arguments=arguments;
    task.standardOutput=log; task.standardError=log; task.standardInput=[NSFileHandle fileHandleWithNullDevice];
    self.task=task; self.taskLog=log; self.taskKind=kind; self.taskExpired=NO; self.sawTetherDuringHelper=NO;
    __weak GuardianController *weakSelf=self;
    task.terminationHandler=^(NSTask *finished) {
        GuardianController *liveController=weakSelf; if(!liveController) return;
        dispatch_async(liveController.queue,^{
            GuardianController *controller=weakSelf; if (!controller || controller.task!=finished) return;
            [controller.taskLog closeFile]; controller.taskLog=nil;
            NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:file];
            NSData *data=[reader readDataOfLength:1024*1024]; [reader closeFile];
            id json=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            NSDictionary *object=[json isKindOfClass:NSDictionary.class] ? json : nil;
            int status=finished.terminationReason==NSTaskTerminationReasonExit ? finished.terminationStatus : 128+finished.terminationStatus;
            BOOL expired=controller.taskExpired;
            controller.task=nil; controller.taskKind=nil;
            if(significant) [controller recordEvent:@"helper_finished" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,
                @"source":source,@"generation":@(generation),@"exit_status":@(status),@"expired":@(expired),
                @"success":@(status==0 && !expired),@"accepted":@(generation==controller.generation && controller.desired && !controller.stopping && !controller.endingSession),
                @"duration_ms":@((GuardianNow()-began)*1000)}];
            completion(status,object,expired);
            [controller advanceEndSession];
            [controller pruneLogs];
            [controller finishStoppingIfPossible];
        });
    };
    NSError *error=nil;
    if (![task launchAndReturnError:&error]) {
        task.terminationHandler=nil; [log closeFile]; self.task=nil; self.taskLog=nil; self.taskKind=nil;
        if(significant) [self recordEvent:@"helper_error" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,
            @"source":source,@"generation":@(generation),@"reason":@"launch_failed",@"error_code":@(error.code)}];
        completion(-1,nil,NO); return;
    }
    if(significant) [self recordEvent:@"helper_started" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,
        @"source":source,@"generation":@(generation),@"pid":@(task.processIdentifier)}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)),self.queue,^{
        GuardianController *controller=weakSelf;
        if (!controller || controller.task!=task || !task.running) return;
        controller.taskExpired=YES; ++controller.generation; controller.pendingRecovery=NO;
        if(significant) [controller recordEvent:@"helper_error" fields:@{@"helper_kind":kind,@"helper_attempt_id":helperID,
            @"source":source,@"generation":@(generation),@"reason":@"helper_deadline",@"expired":@YES}];
        [controller publish:@"helper_timeout" zh:@"准备连接超时，正在等待恢复程序安全结束。" en:@"Preparation timed out; waiting for the recovery helper to finish safely."];
        /* Passive inspect owns no USB session and is safe to cancel. The
         * recovery helper has its own 18s watchdog; never interrupt its
         * in-flight PTP session on Pause/Quit or an external app launch. */
        if ([kind isEqual:@"inspect"]) [task terminate];
    });
}
- (void)pruneLogs {
    NSArray<NSURL *> *urls=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.logDirectory isDirectory:YES]
        includingPropertiesForKeys:@[NSURLContentModificationDateKey,NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSMutableArray<NSURL *> *owned=[NSMutableArray array];
    for(NSURL *url in urls) {
        NSString *name=url.lastPathComponent; NSNumber *regular=nil; [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if(regular.boolValue && [name.pathExtension isEqual:@"log"] &&
            ([name hasPrefix:@"repair-"] || [name hasPrefix:@"service-restart-"])) [owned addObject:url];
    }
    [owned sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b) {
        NSDate *first=nil,*second=nil; [a getResourceValue:&first forKey:NSURLContentModificationDateKey error:NULL];
        [b getResourceValue:&second forKey:NSURLContentModificationDateKey error:NULL];
        return [(first ?: NSDate.distantPast) compare:(second ?: NSDate.distantPast)];
    }];
    while(owned.count>30) { [NSFileManager.defaultManager removeItemAtURL:owned.firstObject error:NULL]; [owned removeObjectAtIndex:0]; }
}
- (void)failRecovery:(NSString *)zh en:(NSString *)en {
    ++self.retryCount;
    self.pendingRecovery=self.desired && self.retryCount<3;
    self.recoverAfter=GuardianNow()+(self.retryCount==1 ? 5 : 15);
    [self recordEvent:@"recovery_failed" fields:@{@"reason":@"preparation_not_ready",@"retry_count":@(self.retryCount),@"source":self.recoverySource ?: @"unknown"}];
    [self publish:self.pendingRecovery ? @"retry_wait" : @"needs_attention" zh:zh en:en];
}
- (BOOL)acceptGeneration:(uint64_t)generation {
    BOOL absent=[self tetherAbsent];
    return GuardianAcceptCompletion(generation,self.generation,self.desired,self.stopping,!absent) && !self.sawTetherDuringHelper;
}
- (void)receiveLaunchResult:(NSDictionary *)verifiedIdentity success:(BOOL)success generation:(uint64_t)generation {
    /* The OS-facing callback has already validated this optional identity.
     * This state-only handoff can also be driven by hardware-free fixtures. */
    self.launching=NO;
    NSMutableDictionary *launchFields=[GuardianSafeIdentityFields(verifiedIdentity) mutableCopy];
    [launchFields addEntriesFromDictionary:@{@"launch_attempt_id":self.launchAttemptID ?: @"unknown",
        @"source":self.activeLaunchSource ?: self.launchSource ?: @"unknown",@"generation":@(generation),@"result":success ? @"returned_app" : @"error",
        @"verified":@(GuardianIdentityShape(verifiedIdentity)),@"verification":@"panasonic_signature",
        @"accepted":@(generation==self.generation && !self.stopping && !self.endingSession)}];
    /* A returned app is not proof that this request created its PID. Another
     * app launch can race NSWorkspace; no parent-PID inference is made. */
    [self recordEvent:@"launch_returned" fields:launchFields];
    if(success) {
        if(GuardianIdentityShape(verifiedIdentity)) self.ownedIdentity=verifiedIdentity;
        self.tetherRunning=YES; self.previousTetherRunning=YES;
        self.tetherObservationValid=YES; self.tetherObservedAt=GuardianNow();
        if(!self.stopping && !self.endingSession && self.generation==generation)
            [self publish:@"tether_running" zh:@"官方 Tether 已打开，请在 Tether 中确认相机连接和拍摄状态。" en:@"Official Tether is open. Confirm the camera connection and shooting state in Tether."];
    } else if(!self.stopping && !self.endingSession && self.generation==generation)
        [self publish:@"needs_attention" zh:@"未能打开官方 Tether，请手动检查应用。" en:@"Official Tether could not be opened. Check the installed application."];
    [self advanceEndSession]; [self finishStoppingIfPossible];
}
- (void)launchTether {
    if (self.stopping || self.task || self.launching || self.endingSession) return;
    if (![self tetherAbsent]) {
        [self recordEvent:@"launch_skipped" fields:@{@"source":self.launchSource ?: @"unknown",@"reason":@"process_present_or_unknown",@"already_running":@(self.tetherObservationValid && self.tetherRunning)}];
        [self publish:@"tether_running" zh:@"Tether 已打开，守护工具只观察连接状态。" en:@"Tether is already open; Guardian is observing only."]; return;
    }
    self.launching=YES; uint64_t generation=self.generation;
    self.launchAttemptID=NSUUID.UUID.UUIDString;
    NSString *attemptID=self.launchAttemptID, *source=self.launchSource ?: @"unknown";
    self.activeLaunchSource=source;
    [self recordEvent:@"launch_attempt_started" fields:@{@"launch_attempt_id":attemptID,@"source":source,@"generation":@(generation)}];
    [self publish:@"launching" zh:@"正在验证并打开官方 Tether 2.12…" en:@"Validating and opening official Tether 2.12…"];
    NSURL *selected=nil;
    for (NSString *path in @[@"/Applications/LUMIX Tether.app",[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/LUMIX Tether.app"]]) {
        NSURL *candidate=[NSURL fileURLWithPath:path isDirectory:YES];
        if (GuardianValidTetherURL(candidate)) { selected=candidate; break; }
    }
    if (!selected || self.stopping || generation!=self.generation || ![self tetherAbsent]) {
        self.launching=NO;
        [self recordEvent:@"launch_cancelled" fields:@{@"launch_attempt_id":attemptID,@"source":source,@"generation":@(generation),@"reason":@"validation_or_state_changed"}];
        [self publish:@"needs_attention" zh:@"未打开 Tether。请确认已安装签名有效的松下官方 2.12。" en:@"Tether was not opened. Install a valid Panasonic-signed Tether 2.12."];
        [self advanceEndSession]; [self finishStoppingIfPossible]; return;
    }
    NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
    configuration.arguments=@[[NSString stringWithFormat:@"-lang=%@",GuardianLanguage()]];
    configuration.activates=YES; configuration.createsNewApplicationInstance=NO;
    configuration.allowsRunningApplicationSubstitution=NO;
    __weak GuardianController *weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        GuardianController *liveController=weakSelf; if(!liveController) return;
        BOOL reliable=NO; NSArray *existing=GuardianTetherPIDs(&reliable);
        if(liveController.stopping || liveController.endingSession || liveController.generation!=generation || !reliable || existing.count) {
            dispatch_async(liveController.queue,^{
                [liveController recordEvent:@"launch_cancelled" fields:@{@"launch_attempt_id":attemptID,@"source":source,@"generation":@(generation),@"reason":@"handoff_state_changed"}];
                liveController.launching=NO; [liveController advanceEndSession]; [liveController finishStoppingIfPossible];
            });
            return;
        }
        [liveController recordEvent:@"launch_requested" fields:@{@"launch_attempt_id":attemptID,@"source":source,@"generation":@(generation)}];
        [NSWorkspace.sharedWorkspace openApplicationAtURL:selected configuration:configuration completionHandler:^(NSRunningApplication *app,NSError *error) {
            GuardianController *live=weakSelf; if(!live) return;
            dispatch_async(live.queue,^{
                GuardianController *controller=weakSelf; if(!controller) return;
                NSDictionary *verifiedIdentity=nil;
                if(app && !error) {
                    NSDictionary *identity=GuardianProcessIdentity(app.processIdentifier);
                    if(GuardianValidRunningTether(identity,NULL)) verifiedIdentity=identity;
                }
                [controller receiveLaunchResult:verifiedIdentity success:app && !error generation:generation];
            });
        }];
    });
}
- (void)repairWithInspection:(NSDictionary *)inspection serviceRetried:(BOOL)serviceRetried generation:(uint64_t)generation {
    if (![self acceptGeneration:generation]) {
        if(generation==self.generation && self.desired && !self.stopping && !self.endingSession) self.pendingRecovery=YES;
        return;
    }
    NSString *reason=GuardianInspectionReadiness(inspection,NO);
    if (reason) {
        self.blockingCameraApps=GuardianBlockingCameraApps(inspection); self.pendingRecovery=self.desired;
        [self publishRecoveryGate:reason]; return;
    }
    NSString *registry=[inspection[@"interface_registry_id"] stringValue];
    [self publish:@"recovering" zh:@"正在准备 USB 连接，请暂时不要打开其他相机软件…" en:@"Preparing USB. Keep other camera applications closed for now…"];
    [self runHelper:@"s1h_iousbhost_probe" arguments:@[@"--io-buffer",@"--drain-input",@"--require-s1h",@"--expected-interface-id",registry]
        kind:@"repair" timeout:25 completion:^(int status,NSDictionary *json,BOOL expired) {
        (void)json;
        if (![self acceptGeneration:generation] || expired) {
            if(self.sawTetherDuringHelper) { self.pendingRecovery=NO; self.retryCount=3; }
            if (!self.stopping && !self.endingSession) [self publish:self.desired ? @"needs_attention" : @"paused"
                zh:@"准备程序已结束；自动后续操作已取消。需要时请点击“重新连接”。" en:@"Preparation finished; further automatic actions were cancelled. Choose Reconnect when needed."];
            return;
        }
        if(status==0) {
            [self runHelper:@"s1h_camera_service" arguments:@[@"--inspect"] kind:@"inspect" timeout:2 completion:^(int inspectStatus,NSDictionary *fresh,BOOL inspectExpired) {
                if(![self acceptGeneration:generation] || inspectExpired) return;
                NSString *gate=GuardianInspectionReadiness(fresh,NO);
                if(!inspectStatus && ![gate isEqual:@"inspection_error"]) {
                    self.inspection=fresh; self.inspectionObservationValid=YES; self.inspectionObservedAt=GuardianNow();
                    self.blockingCameraApps=GuardianBlockingCameraApps(fresh);
                } else { self.inspectionObservationValid=NO; self.blockingCameraApps=@[]; }
                if(inspectStatus || gate ||
                    ![fresh[@"interface_registry_id"] isEqual:inspection[@"interface_registry_id"]]) {
                    if(!inspectStatus && [gate isEqual:@"camera_apps_running"]) {
                        /* The USB check succeeded. Another application is
                         * now present, so retain the requested handoff until
                         * it exits; this is not an I/O retry failure. */
                        self.pendingRecovery=self.desired; self.recoverAfter=GuardianNow()+1;
                        [self publishRecoveryGate:gate]; return;
                    }
                    [self failRecovery:@"连接状态在准备后发生变化；未打开 Tether，将重新检查。" en:@"The connection changed after preparation. Tether was not opened; it will be checked again."];
                    if(gate) [self publishRecoveryGate:gate];
                    return;
                }
                self.inspection=fresh; self.inspectionObservationValid=YES; self.inspectionObservedAt=GuardianNow();
                self.pendingRecovery=NO; self.retryCount=0; self.launchSource=self.recoverySource ?: @"unknown"; [self launchTether];
            }];
            return;
        }
        if(status==22 && !serviceRetried) { [self inspectForRestartGeneration:generation]; return; }
        [self failRecovery:@"暂未恢复连接；请检查 PC(Tether) 模式、数据线和相机软件。" en:@"Connection is not ready. Check PC(Tether) mode, the data cable and camera applications."];
    }];
}
- (void)inspectForRestartGeneration:(uint64_t)generation {
    if (![self acceptGeneration:generation]) return;
    [self runHelper:@"s1h_camera_service" arguments:@[@"--inspect"] kind:@"inspect" timeout:2 completion:^(int status,NSDictionary *inspection,BOOL expired) {
        if (![self acceptGeneration:generation] || expired) return;
        if(status || GuardianInspectionReadiness(inspection,NO) || ![inspection[@"restart_guard"] isEqual:@"opt_in_required"] ||
            ![inspection[@"interface_registry_id"] isEqual:self.inspection[@"interface_registry_id"]]) {
            [self failRecovery:@"相机接口仍被占用，安全检查未允许重启服务。请关闭相机软件后重试。" en:@"The interface is busy and safety checks did not allow a service restart. Close camera applications and retry."]; return;
        }
        [self publish:@"restarting_service" zh:@"正在按守护设置释放当前用户的相机服务…" en:@"Releasing the current user's camera service as authorized by Guardian…"];
        [self runHelper:@"s1h_camera_service" arguments:@[@"--restart-camera-service"] kind:@"service-restart" timeout:20 completion:^(int serviceStatus,NSDictionary *result,BOOL serviceExpired) {
            if (![self acceptGeneration:generation] || serviceExpired) return;
            NSDictionary *fresh=result[@"inspection"];
            if(serviceStatus || ![@[@"released",@"not_needed"] containsObject:result[@"status"]] ||
                GuardianInspectionReadiness(fresh,NO) || ![fresh[@"interface_registry_id"] isEqual:inspection[@"interface_registry_id"]]) {
                [self failRecovery:@"相机服务未安全释放；已停止自动准备。" en:@"The camera service was not safely released; automatic preparation stopped."]; return;
            }
            [self repairWithInspection:fresh serviceRetried:YES generation:generation];
        }];
    }];
}
- (void)receiveInspection:(NSDictionary *)inspection status:(int)status expired:(BOOL)expired {
    self.nextInspect=GuardianNow()+2;
    if(self.stopping) return;
    if(status || expired || [GuardianInspectionReadiness(inspection,NO) isEqual:@"inspection_error"]) {
        self.inspectionObservationValid=NO;
        self.blockingCameraApps=@[]; [self observeRecoveryGate:@"inspection_error"];
        if(!self.inspectionErrorLogged) [self recordEvent:@"inspection_error" fields:@{@"reason":expired ? @"deadline" : status ? @"helper_exit" : @"invalid_observation",@"exit_status":@(status),@"expired":@(expired)}];
        self.inspectionErrorLogged=YES;
        if(self.endingSession) { [self advanceEndSession]; return; }
        if (!self.stopping) [self publish:@"inspection_error" zh:@"暂时无法确认连接状态；不会自动操作相机。" en:@"Connection state could not be verified; no automatic camera action will be taken."];
        return;
    }
    if(self.inspectionErrorLogged) [self recordEvent:@"inspection_recovered" fields:@{}];
    self.inspectionErrorLogged=NO;
    self.inspection=inspection; self.inspectionObservationValid=YES; self.inspectionObservedAt=GuardianNow();
    self.blockingCameraApps=GuardianBlockingCameraApps(inspection);
    BOOL knownPresent=[inspection[@"device_model_state"] isEqual:@"confirmed"] && [inspection[@"s1h_device_count"] unsignedIntegerValue]==1 &&
        [inspection[@"s1h_interface_count"] unsignedIntegerValue]==1 && [inspection[@"interface_registry_id"] unsignedLongLongValue]>0;
    BOOL confirmedAbsent=[inspection[@"matching_usb_id_device_count"] isKindOfClass:NSNumber.class] &&
        [inspection[@"matching_usb_id_device_count"] unsignedIntegerValue]==0;
    if(knownPresent) {
        uint64_t registry=[inspection[@"interface_registry_id"] unsignedLongLongValue];
        if(!self.devicePresent || registry!=self.interfaceID) {
            [self recordEvent:@"usb_attached" fields:@{@"initial":@(!self.inspectionStateObserved),@"observation":self.inspectionStateObserved ? @"presence_or_identity_changed" : @"first_seen",
                @"device_count":inspection[@"s1h_device_count"],@"interface_count":inspection[@"s1h_interface_count"],
                @"usb_link_speed_bps":[inspection[@"usb_link_speed_bps"] isKindOfClass:NSNumber.class] ? inspection[@"usb_link_speed_bps"] : @0}];
            if(self.inspectionStateObserved || !self.pendingRecovery) self.recoverySource=@"afterUSBAttachRecovery";
            self.interfaceID=registry; self.devicePresent=YES; self.retryCount=0;
            self.pendingRecovery=self.desired; self.recoverAfter=GuardianNow()+1;
        }
    } else if(confirmedAbsent) {
        BOOL detached=self.devicePresent; self.devicePresent=NO; self.interfaceID=0; self.pendingRecovery=NO;
        if(detached) [self recordEvent:@"usb_detached" fields:@{@"device_count":@0,@"interface_count":@0,@"observation":@"confirmed_absent"}];
        if(detached && self.desired && self.ownedIdentity && self.tetherRunning && !self.quitRequested)
            [self requestTetherQuit:@"detach"];
    }
    self.inspectionStateObserved=YES;
    if(self.stopping) return;
    if(self.endingSession) { [self advanceEndSession]; return; }
    if(self.sessionEnded) { [self publish:@"session_ended" zh:@"本次拍摄已结束；Tether 已退出，守护工具只观察状态。" en:@"This session has ended. Tether is closed; Guardian is observing only."]; return; }
    if(!self.desired) { [self publish:@"paused" zh:@"自动恢复已暂停；Tether 保持当前状态。" en:@"Automatic recovery is paused; Tether is left as it is."]; return; }
    if(self.quitRequested) { [self republish]; return; }
    BOOL absent=[self tetherAbsent];
    if(!self.tetherObservationValid) { [self publishRecoveryGate:@"process_observation_unknown"]; return; }
    if(!absent) { [self publish:@"tether_running" zh:@"Tether 正在运行；只观察 USB 状态，不访问相机。" en:@"Tether is running; observing USB state without opening the camera."]; return; }
    NSString *reason=GuardianInspectionReadiness(inspection,NO);
    if(reason) {
        [self publishRecoveryGate:reason];
        return;
    }
    [self observeRecoveryGate:@"ready"];
    if(self.pendingRecovery && GuardianNow()>=self.recoverAfter && !self.task && !self.launching) {
        self.pendingRecovery=NO; [self repairWithInspection:inspection serviceRetried:NO generation:self.generation];
    } else if(!self.pendingRecovery && self.retryCount>=3) [self republish];
    else [self publish:@"waiting" zh:@"正在等待稳定的相机连接…" en:@"Waiting for a stable camera connection…"];
}
- (void)requestTetherQuit:(NSString *)purpose {
    if(self.stopping || self.task || self.launching || self.quitRequested) return;
    BOOL reliable=NO; NSArray<NSNumber *> *pids=GuardianTetherPIDs(&reliable);
    if(!reliable || pids.count!=1) { [self publish:[purpose isEqual:@"end"] ? @"end_needs_attention" : @"needs_attention" zh:@"无法唯一确认官方 Tether，请先手动退出相机软件。" en:@"Official Tether could not be identified uniquely. Quit camera applications manually."]; return; }
    NSDictionary *identity=GuardianProcessIdentity(pids.firstObject.intValue); NSRunningApplication *app=nil;
    if(!GuardianValidRunningTether(identity,&app) ||
        ([purpose isEqual:@"detach"] && !GuardianSameIdentity(identity,self.ownedIdentity))) {
        [self publish:[purpose isEqual:@"end"] ? @"end_needs_attention" : @"needs_attention" zh:@"不会关闭未确认的应用。请手动退出 Tether 后重试。" en:@"An unverified application will not be closed. Quit Tether manually and retry."]; return;
    }
    self.quitIdentity=identity; self.quitPurpose=purpose; self.quitRequested=YES; self.canForce=NO; self.quitDeadline=GuardianNow()+30;
    self.quitRequestID=NSUUID.UUID.UUIDString; self.quitTimeoutLogged=NO;
    NSString *requestID=self.quitRequestID;
    NSMutableDictionary *queued=[GuardianSafeIdentityFields(identity) mutableCopy];
    [queued addEntriesFromDictionary:@{@"correlation_id":requestID,@"purpose":purpose}];
    [self recordEvent:@"normal_quit_queued" fields:queued];
    uint64_t generation=self.generation;
    [self publish:[purpose isEqual:@"end"] ? @"ending_tether" : @"quitting_tether" zh:@"正在请求 Tether 正常退出，等待其完成当前操作…" en:@"Asking Tether to quit normally and waiting for its current operation…"];
    dispatch_async(dispatch_get_main_queue(),^{
        /* This is a normal application quit request, never a signal. */
        if(!self.stopping && self.generation==generation && self.quitRequested &&
            GuardianSameIdentity(identity,GuardianProcessIdentity(app.processIdentifier))) {
            self.normalQuitDelivered=YES;
            BOOL accepted=[app terminate];
            NSMutableDictionary *fields=[GuardianSafeIdentityFields(identity) mutableCopy];
            [fields addEntriesFromDictionary:@{@"correlation_id":requestID,@"purpose":purpose,@"generation":@(generation),@"accepted":@(accepted),@"normal_quit_delivered":@YES}];
            [self recordEvent:@"normal_quit_delivered" fields:fields];
        } else [self recordEvent:@"normal_quit_cancelled" fields:@{@"correlation_id":requestID,@"purpose":purpose,@"generation":@(generation),@"reason":@"handoff_state_or_identity_changed"}];
    });
}
- (void)advanceEndSession {
    if(!self.endingSession || self.stopping) return;
    BOOL absent=NO;
    if(!self.task && !self.launching && !self.quitRequested) absent=[self tetherAbsent];
    NSString *decision=GuardianEndDecision(self.endingSession,self.stopping,self.task!=nil,self.launching,
        self.quitRequested,self.tetherObservationValid,absent);
    if([decision isEqual:@"wait_work"]) {
        [self publish:@"ending_wait" zh:@"自动恢复已关闭；等待当前准备安全结束，然后正常退出 Tether。" en:@"Automatic recovery is off. Waiting for preparation to finish safely, then Tether will be asked to quit normally."];
    } else if([decision isEqual:@"unknown"]) {
        self.canForce=NO;
        [self publish:@"end_needs_attention" zh:@"暂时无法确认 Tether 进程状态；不会退出未知应用，也不会自动重新打开。" en:@"Tether's process state is unknown. No unknown application will be quit or automatically reopened."];
    } else if([decision isEqual:@"settled"]) {
        self.desired=NO; self.pendingRecovery=NO; self.endingSession=NO; self.sessionEnded=YES;
        self.canForce=NO; self.quitRequested=NO; self.quitIdentity=nil; self.quitPurpose=nil; self.ownedIdentity=nil;
        [self recordEvent:@"session_ended" fields:@{@"session_ended":@YES,@"observation":@"tether_absent",@"correlation_id":self.quitRequestID ?: @"none"}];
        [self publish:@"session_ended" zh:@"本次拍摄已结束；Tether 已退出，守护工具只观察状态。" en:@"This session has ended. Tether is closed; Guardian is observing only."];
    } else if([decision isEqual:@"request_verified_quit"]) {
        if(self.endQuitAttempted) {
            self.canForce=NO;
            [self publish:@"end_needs_attention" zh:@"退出目标未能安全确认或已经变化。请手动退出 Tether；不会自动关闭后来打开的进程。" en:@"The quit target could not be verified or has changed. Quit Tether manually; a later process will not be closed automatically."];
            return;
        }
        self.endQuitAttempted=YES;
        [self requestTetherQuit:@"end"];
    }
}
- (void)tick {
    if(self.stopping) { [self finishStoppingIfPossible]; return; }
    BOOL absent=[self tetherAbsent];
    [self publishObservationFreshnessIfNeeded];
    if(self.task && ![self.taskKind isEqual:@"inspect"] && !absent) self.sawTetherDuringHelper=YES;
    if(self.previousTetherRunning && absent && self.desired && !self.quitRequested) {
        self.recoverySource=@"afterTetherExitRecovery";
        ++self.generation; self.pendingRecovery=YES; self.retryCount=0; self.recoverAfter=GuardianNow()+1; self.nextInspect=0;
    }
    self.previousTetherRunning=self.tetherRunning;
    if(self.quitRequested) {
        NSDictionary *current=GuardianProcessIdentity([self.quitIdentity[@"pid"] intValue]);
        if(!GuardianSameIdentity(self.quitIdentity,current)) {
            NSMutableDictionary *fields=[GuardianSafeIdentityFields(self.quitIdentity) mutableCopy];
            [fields addEntriesFromDictionary:@{@"correlation_id":self.quitRequestID ?: @"unknown",@"purpose":self.quitPurpose ?: @"unknown",
                @"observation":self.tetherObservationValid && !self.tetherRunning ? @"tether_absent" : @"target_identity_unavailable_or_changed"}];
            [self recordEvent:self.tetherObservationValid && !self.tetherRunning ? @"normal_quit_exited" : @"normal_quit_target_changed" fields:fields];
            BOOL reconnect=[self.quitPurpose isEqual:@"reconnect"];
            self.quitRequested=NO; self.canForce=NO; self.quitIdentity=nil; self.ownedIdentity=nil; self.quitPurpose=nil;
            if(reconnect && self.desired) { self.pendingRecovery=YES; self.retryCount=0; self.recoverAfter=GuardianNow()+1; }
            self.nextInspect=0;
        } else if(GuardianNow()>=self.quitDeadline) {
            self.canForce=YES;
            if(!self.quitTimeoutLogged) {
                self.quitTimeoutLogged=YES;
                NSMutableDictionary *fields=[GuardianSafeIdentityFields(self.quitIdentity) mutableCopy];
                [fields addEntriesFromDictionary:@{@"correlation_id":self.quitRequestID ?: @"unknown",@"purpose":self.quitPurpose ?: @"unknown"}];
                [self recordEvent:@"normal_quit_timeout" fields:fields];
            }
            if(self.endingSession) [self publish:@"ending_needs_force" zh:@"Tether 尚未退出。确认当前拍摄和传输已结束后，可明确选择“强制退出”；不会重新打开。" en:@"Tether has not quit. After confirming capture and transfers are finished, explicitly choose Force Quit. It will not reopen."];
            else [self publish:@"needs_force" zh:@"Tether 尚未退出。确认当前拍摄已结束后，可明确选择“强制重启”。" en:@"Tether has not quit. After confirming capture has finished, explicitly choose Force Restart."];
            return;
        } else { [self republish]; return; }
    }
    if(self.endingSession) { [self advanceEndSession]; return; }
    if(self.task || self.launching || GuardianNow()<self.nextInspect) return;
    self.nextInspect=GuardianNow()+2;
    [self runHelper:@"s1h_camera_service" arguments:@[@"--inspect"] kind:@"inspect" timeout:2 completion:^(int status,NSDictionary *json,BOOL expired) {
        [self receiveInspection:json status:status expired:expired];
    }];
}
- (void)start {
    dispatch_async(self.queue,^{ if(self.stopping) return;
        [self recordEvent:@"user_start" fields:@{@"accepted":@(!self.endingSession)}];
        if(self.endingSession) { [self republish]; return; }
        self.recoverySource=@"afterStartRecovery";
        self.sessionEnded=NO; self.normalQuitDelivered=NO;
        ++self.generation; self.desired=YES; self.retryCount=0;
        self.pendingRecovery=YES; self.recoverAfter=GuardianNow()+1; self.nextInspect=0;
        [self publish:@"starting" zh:@"守护已开始，正在只读检查连接状态。" en:@"Guardian started; checking connection state read-only."]; [self tick]; });
}
- (void)pause {
    dispatch_async(self.queue,^{ ++self.generation; self.desired=NO; self.pendingRecovery=NO; self.canForce=NO;
        [self recordEvent:@"user_pause" fields:@{@"normal_quit_delivered":@(self.normalQuitDelivered)}];
        self.endingSession=NO; self.endQuitAttempted=NO;
        self.quitRequested=NO; self.quitIdentity=nil; self.quitPurpose=nil;
        if(self.normalQuitDelivered) [self publish:@"paused"
            zh:@"后续自动操作已取消；此前发出的退出请求无法撤回，Tether 仍可能退出。"
            en:@"Further automatic actions were cancelled. The earlier quit request cannot be withdrawn, so Tether may still exit."];
        else [self publish:@"paused" zh:self.task ? @"自动恢复已暂停；等待当前准备安全结束，不再打开 Tether。" : @"自动恢复已暂停；Tether 保持当前状态。"
            en:self.task ? @"Automatic recovery paused; waiting for current preparation to finish safely. Tether will not be opened." : @"Automatic recovery paused; Tether was left as it was."]; });
}
- (void)endSession {
    dispatch_async(self.queue,^{
        if(self.stopping) return;
        /* First revoke recovery/launch consent. A helper already owning a
         * session is allowed to finish; none of its old results can restart
         * Tether. No new normal-quit target is selected after one attempt. */
        self.desired=NO;
        self.pendingRecovery=NO;
        if(self.endingSession) {
            [self recordEvent:@"user_end_session" fields:@{@"accepted":@NO,@"result":@"already_ending"}];
            [self republish]; return;
        }
        ++self.generation; self.retryCount=0;
        [self recordEvent:@"user_end_session" fields:@{@"accepted":@YES,@"result":@"accepted"}];
        self.endingSession=YES; self.sessionEnded=NO; self.endQuitAttempted=NO;
        self.canForce=NO; self.quitRequested=NO; self.quitIdentity=nil; self.quitPurpose=nil;
        [self advanceEndSession];
    });
}
- (void)reconnect {
    dispatch_async(self.queue,^{ if(self.stopping) return;
        [self recordEvent:@"user_reconnect" fields:@{@"accepted":@(!self.endingSession && !self.task && !self.launching)}];
        if(self.endingSession) { [self republish]; return; }
        if(self.task || self.launching) { [self publish:@"busy" zh:@"当前准备尚未完成，请稍后再重新连接。" en:@"Preparation is still finishing. Choose Reconnect afterward."]; return; }
        self.recoverySource=@"afterReconnectRecovery";
        self.sessionEnded=NO; self.normalQuitDelivered=NO;
        ++self.generation; self.desired=YES; self.pendingRecovery=YES; self.retryCount=0; self.recoverAfter=GuardianNow()+1;
        if([self tetherAbsent]) { self.nextInspect=0; [self tick]; } else [self requestTetherQuit:@"reconnect"];
    });
}
- (void)forceRestart {
    [self forceTetherForEnding:NO];
}
- (void)forceQuit {
    [self forceTetherForEnding:YES];
}
- (void)forceTetherForEnding:(BOOL)ending {
    dispatch_async(self.queue,^{
        [self recordEvent:ending ? @"user_force_quit" : @"user_force_restart" fields:@{@"accepted":@(!self.stopping && !self.task && !self.launching &&
            GuardianForceModeAllowed(self.endingSession,ending,self.canForce,self.quitRequested,self.quitPurpose))}];
        if(self.stopping || self.task || self.launching ||
            !GuardianForceModeAllowed(self.endingSession,ending,self.canForce,self.quitRequested,self.quitPurpose)) return;
        if(ending) { self.desired=NO; self.pendingRecovery=NO; }
        NSDictionary *expected=self.quitIdentity; NSDictionary *fresh=GuardianProcessIdentity([expected[@"pid"] intValue]);
        NSRunningApplication *app=nil;
        if(!GuardianSameIdentity(expected,fresh) || !GuardianValidRunningTether(fresh,&app)) {
            [self recordEvent:@"force_quit_refused" fields:@{@"purpose":ending ? @"end" : @"restart",@"reason":@"target_identity_changed",@"correlation_id":self.quitRequestID ?: @"unknown"}];
            self.canForce=NO; self.quitRequested=NO; self.quitIdentity=nil;
            [self publish:ending ? @"end_needs_attention" : @"needs_attention" zh:@"Tether 身份已变化；未强制关闭任何应用。" en:@"Tether's identity changed; no application was forced to quit."]; return;
        }
        self.canForce=NO; self.quitDeadline=GuardianNow()+10;
        uint64_t generation=self.generation;
        NSString *requestID=self.quitRequestID ?: @"unknown";
        [self publish:@"force_quitting" zh:@"正在按你的明确选择强制退出已核验的 Tether…" en:@"Forcing the verified Tether process to quit as explicitly requested…"];
        dispatch_async(dispatch_get_main_queue(),^{
            if(!self.stopping && self.generation==generation && self.quitRequested &&
                GuardianSameIdentity(expected,GuardianProcessIdentity(app.processIdentifier))) {
                BOOL accepted=[app forceTerminate];
                NSMutableDictionary *fields=[GuardianSafeIdentityFields(expected) mutableCopy];
                [fields addEntriesFromDictionary:@{@"correlation_id":requestID,@"purpose":ending ? @"end" : @"restart",@"generation":@(generation),@"accepted":@(accepted)}];
                [self recordEvent:@"force_quit_delivered" fields:fields];
            } else [self recordEvent:@"force_quit_cancelled" fields:@{@"correlation_id":requestID,@"purpose":ending ? @"end" : @"restart",@"generation":@(generation),@"reason":@"handoff_state_or_identity_changed"}];
        });
    });
}
- (void)openTether {
    dispatch_async(self.queue,^{ if(self.stopping) return;
        [self recordEvent:@"user_open_tether" fields:@{@"accepted":@(!self.endingSession && !self.task && !self.quitRequested && !self.launching)}];
        if(self.endingSession) { [self republish]; return; }
        if(self.task || self.quitRequested || self.launching) { [self publish:@"busy" zh:@"当前准备尚未完成，请稍后打开 Tether。" en:@"Preparation is still finishing. Open Tether afterward."]; return; }
        BOOL absent=[self tetherAbsent];
        if(self.tetherObservationValid && self.tetherRunning) {
            [self recordEvent:@"launch_skipped" fields:@{@"source":@"afterOpenRecovery",@"reason":@"already_running",@"already_running":@YES}];
            [self publish:@"tether_running" zh:@"Tether 正在运行；本次只检查状态，不重新启动或访问相机。" en:@"Tether is running. This action only observes status; it does not relaunch or open the camera."];
            return;
        }
        self.sessionEnded=NO; self.normalQuitDelivered=NO;
        self.recoverySource=@"afterOpenRecovery";
        ++self.generation; self.desired=YES; self.pendingRecovery=YES; self.retryCount=0;
        self.recoverAfter=GuardianNow()+1; self.nextInspect=0;
        if(!absent) [self publishRecoveryGate:@"process_observation_unknown"];
        else [self publish:@"starting" zh:@"正在检查连接；只有完成安全检查和 USB 准备后才会打开 Tether。" en:@"Checking the connection. Tether will open only after safety checks and USB preparation succeed."];
        [self tick];
    });
}
- (void)stopTool { [self stopToolWithCompletion:^{}]; }
- (void)stopToolWithCompletion:(dispatch_block_t)completion {
    dispatch_async(self.queue,^{
        if(completion) [self.stopCompletions addObject:[completion copy]];
        if(!self.stoppingLogged) { self.stoppingLogged=YES; [self recordEvent:@"app_stopping" fields:@{}]; }
        ++self.generation; self.stopping=YES; self.desired=NO; self.pendingRecovery=NO; self.canForce=NO; self.quitRequested=NO;
        self.endingSession=NO;
        [self publish:@"stopping" zh:self.normalQuitDelivered ? @"正在停止守护；此前发出的 Tether 退出请求无法撤回。" : @"正在停止守护；等待当前准备安全结束，保留 Tether。"
            en:self.normalQuitDelivered ? @"Stopping Guardian. The earlier Tether quit request cannot be withdrawn." : @"Stopping Guardian; allowing current preparation to finish safely and leaving Tether alone."];
        if(self.task && [self.taskKind isEqual:@"inspect"]) [self.task terminate];
        [self finishStoppingIfPossible];
    });
}
@end
