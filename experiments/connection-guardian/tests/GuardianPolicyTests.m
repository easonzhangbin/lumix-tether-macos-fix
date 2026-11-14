/* Production policy and asynchronous End transitions, with fake environment
 * boundaries. The fixture bypasses the observation-starting initializer.
 * Raw process lookups are trapped so a missing override cannot touch a real
 * process. No camera, app, process enumeration, timer or signal is used. */
#include <libproc.h>
#include <stdio.h>
static unsigned ForbiddenProcessCalls;
static int FixturePIDInfo(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    (void)pid; (void)flavor; (void)arg; (void)buffer; (void)size;
    ++ForbiddenProcessCalls; return 0;
}
static int FixturePIDPath(int pid, void *buffer, uint32_t size) {
    (void)pid; (void)buffer; (void)size; ++ForbiddenProcessCalls; return 0;
}
static int FixtureListPIDs(void *buffer, int size) {
    (void)buffer; (void)size; ++ForbiddenProcessCalls; return 0;
}
static int FixtureProcName(int pid, void *buffer, uint32_t size) {
    (void)pid; (void)buffer; (void)size; ++ForbiddenProcessCalls; return 0;
}
#define proc_pidinfo FixturePIDInfo
#define proc_pidpath FixturePIDPath
#define proc_listallpids FixtureListPIDs
#define proc_name FixtureProcName
#import "../GuardianController.m"
#undef proc_pidinfo
#undef proc_pidpath
#undef proc_listallpids
#undef proc_name

static unsigned Checks = 0, Failures = 0;
static void Check(BOOL condition, const char *label) {
    ++Checks;
    if (!condition) { ++Failures; fprintf(stderr, "FAIL %s\n", label); }
    else printf("PASS %s\n", label);
}
static NSDictionary *Changed(NSDictionary *base, NSString *key, id value) {
    NSMutableDictionary *changed = [base mutableCopy];
    if (value) changed[key] = value; else [changed removeObjectForKey:key];
    return changed;
}

@interface GuardianFixtureTask : NSTask
@property(nonatomic) NSUInteger terminationAttempts;
@end
@implementation GuardianFixtureTask
- (void)terminate { ++self.terminationAttempts; }
@end

@interface GuardianFixtureController : GuardianController
@property(nonatomic) BOOL fakePresent;
@property(nonatomic) BOOL fakeObservationValid;
@property(nonatomic) BOOL rejectQuitTarget;
@property(nonatomic,strong) NSDictionary *fakeIdentity;
@property(nonatomic,strong) NSMutableArray<NSString *> *publishedStates;
@property(nonatomic,strong) NSMutableArray<NSString *> *helperKinds;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *helperRequests;
@property(nonatomic,strong) NSMutableArray<GuardianFixtureTask *> *fakeTasks;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic,copy) void (^helperCompletion)(int,NSDictionary *,BOOL);
@property(nonatomic) NSUInteger normalQuitRequests;
@property(nonatomic) NSUInteger launchRequests;
- (instancetype)initFixture;
- (void)completeHelper:(int)status result:(NSDictionary *)result;
@end
@implementation GuardianFixtureController
- (instancetype)initFixture {
    /* Deliberately NSObject init, not initWithResourceDirectory:onUpdate:. */
    if((self=[super init])) {
        self.queue=dispatch_queue_create("guardian.test.fixture",DISPATCH_QUEUE_SERIAL);
        self.stopCompletions=[NSMutableArray array];
        self.publishedStates=[NSMutableArray array]; self.helperKinds=[NSMutableArray array]; self.helperRequests=[NSMutableArray array];
        self.fakeTasks=[NSMutableArray array]; self.fakeObservationValid=YES;
        self.events=[NSMutableArray array];
        self.state=@"idle"; self.messageZH=@""; self.messageEN=@"";
        self.generation=10;
    }
    return self;
}
- (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields {
    [self.events addObject:@{@"event":event,@"fields":[fields copy] ?: @{}}];
}
- (BOOL)tetherAbsent {
    [self observeTetherPresence:self.fakePresent observationValid:self.fakeObservationValid
        identity:self.fakePresent ? self.fakeIdentity : nil];
    return self.fakeObservationValid && !self.fakePresent;
}
- (void)publish:(NSString *)state zh:(NSString *)zh en:(NSString *)en {
    self.state=state; self.messageZH=zh; self.messageEN=en;
    [self.publishedStates addObject:state];
}
- (void)runHelper:(NSString *)name arguments:(NSArray<NSString *> *)arguments kind:(NSString *)kind
          timeout:(double)timeout completion:(void (^)(int,NSDictionary *,BOOL))completion {
    (void)timeout;
    Check(!self.task && !self.helperCompletion,"Fixture permits only one pending production helper");
    GuardianFixtureTask *task=[GuardianFixtureTask new];
    [self.fakeTasks addObject:task]; self.task=task; self.taskKind=kind;
    [self.helperRequests addObject:@{@"name":name,@"arguments":[arguments copy],@"kind":kind}];
    [self.helperKinds addObject:kind]; self.helperCompletion=completion;
}
- (void)completeHelper:(int)status result:(NSDictionary *)result {
    void (^completion)(int,NSDictionary *,BOOL)=self.helperCompletion;
    self.helperCompletion=nil; self.task=nil; self.taskKind=nil;
    Check(completion!=nil,"Fixture completes an actual stored production callback");
    if(completion) completion(status,result,NO);
    /* Same post-completion boundary as runHelper's production handler. */
    [self advanceEndSession]; [self finishStoppingIfPossible];
}
- (void)requestTetherQuit:(NSString *)purpose {
    ++self.normalQuitRequests;
    if(self.rejectQuitTarget) { [self publish:@"end_needs_attention" zh:@"" en:@""]; return; }
    self.quitIdentity=self.fakeIdentity; self.quitPurpose=purpose;
    self.quitRequested=YES; self.canForce=NO; self.quitDeadline=GuardianNow()+30;
    [self publish:[purpose isEqual:@"end"] ? @"ending_tether" : @"quitting_tether" zh:@"" en:@""];
}
- (void)launchTether { ++self.launchRequests; }
@end

static void Drain(GuardianFixtureController *fixture) { dispatch_sync(fixture.queue,^{}); }
static GuardianFixtureController *Fixture(NSDictionary *identity) {
    GuardianFixtureController *fixture=[[GuardianFixtureController alloc] initFixture];
    fixture.fakeIdentity=identity; return fixture;
}
static NSArray<NSDictionary *> *EventsNamed(GuardianFixtureController *fixture,NSString *name) {
    NSMutableArray *found=[NSMutableArray array];
    for(NSDictionary *entry in fixture.events) if([entry[@"event"] isEqual:name]) [found addObject:entry[@"fields"]];
    return found;
}

static void CheckObservationEvents(NSDictionary *identity) {
    GuardianFixtureController *fixture=Fixture(identity);
    dispatch_sync(fixture.queue,^{
        for(unsigned i=0;i<100;++i) [fixture observeTetherPresence:YES observationValid:YES identity:identity];
    });
    NSArray *observed=EventsNamed(fixture,@"tether_observed");
    Check(observed.count==1,"Repeated unchanged process observations emit only one initial lifecycle event");
    if(observed.count) {
        NSDictionary *first=observed[0];
        Check([first[@"source"] isEqual:@"external_or_unknown"] && [first[@"phase"] isEqual:@"startup"] &&
            [first[@"initial"] boolValue] && [first[@"observed"] boolValue],"An initially running Tether is observed with unknown origin, never attributed to Guardian");
        Check(first[@"path"]==nil && first[@"uid"]==nil && first[@"real_uid"]==nil &&
            [first[@"pid"] isEqual:identity[@"pid"]],"Process observation events retain correlation without executable path or user identity");
    }
    dispatch_sync(fixture.queue,^{
        for(unsigned i=0;i<100;++i) [fixture observeTetherPresence:NO observationValid:NO identity:nil];
    });
    Check(EventsNamed(fixture,@"process_observation_error").count==1 && EventsNamed(fixture,@"tether_observed").count==1,
        "Repeated detector failures emit one error and never synthesize an exit event");
    dispatch_sync(fixture.queue,^{ [fixture observeTetherPresence:YES observationValid:YES identity:identity]; });
    Check(EventsNamed(fixture,@"process_observation_recovered").count==1 && EventsNamed(fixture,@"tether_observed").count==1,
        "Recovered observation is recorded once without duplicating unchanged process presence");
    NSDictionary *replacement=Changed(identity,@"start_seconds",@1234568);
    dispatch_sync(fixture.queue,^{
        [fixture observeTetherPresence:YES observationValid:YES identity:replacement];
        [fixture observeTetherPresence:NO observationValid:YES identity:nil];
    });
    observed=EventsNamed(fixture,@"tether_observed");
    Check(observed.count==3 && [observed[1][@"phase"] isEqual:@"identity_changed"] &&
        [observed[2][@"phase"] isEqual:@"exited"],"PID reuse and later absence create separate lifecycle edges");
    BOOL unknown=YES;
    for(NSDictionary *fields in observed) unknown &= [fields[@"source"] isEqual:@"external_or_unknown"] && !fields[@"created_process"];
    Check(unknown,"Observed lifecycle edges never manufacture a process-creation attribution");
    GuardianFixtureController *delayedIdentity=Fixture(identity);
    dispatch_sync(delayedIdentity.queue,^{
        [delayedIdentity observeTetherPresence:YES observationValid:YES identity:nil];
        [delayedIdentity observeTetherPresence:YES observationValid:YES identity:identity];
        [delayedIdentity observeTetherPresence:YES observationValid:YES identity:nil];
        [delayedIdentity observeTetherPresence:YES observationValid:YES identity:identity];
    });
    NSArray *identified=EventsNamed(delayedIdentity,@"tether_observed");
    Check(identified.count==2 && [identified[1][@"phase"] isEqual:@"identity_available"],
        "A delayed process identity is recorded once without treating it as another launch");
    Check(identified.count==2 && [identified[1][@"source"] isEqual:@"external_or_unknown"] &&
        [identified[1][@"pid"] isEqual:identity[@"pid"]],"Later identity evidence preserves unknown origin and supplies only process correlation");
}

static void CheckActionAndLaunchEvents(NSDictionary *ready,NSDictionary *identity) {
    GuardianFixtureController *started=Fixture(identity);
    [started start]; Drain(started);
    Check(EventsNamed(started,@"user_start").count==1 && [started.recoverySource isEqual:@"afterStartRecovery"],
        "An explicit Start is logged and establishes its own recovery request source");
    dispatch_sync(started.queue,^{ [started completeHelper:0 result:ready]; });
    Check([started.recoverySource isEqual:@"afterStartRecovery"],"Initial USB observation cannot relabel an explicit Start as automatic attachment");
    dispatch_sync(started.queue,^{
        started.recoverAfter=0; [started receiveInspection:ready status:0 expired:NO];
        [started completeHelper:0 result:@{}];
        [started completeHelper:0 result:ready];
    });
    Check(started.launchRequests==1 && [started.launchSource isEqual:@"afterStartRecovery"],
        "A real successful preparation chain passes Start attribution to the launch boundary");
    [started pause]; Drain(started);
    Check(EventsNamed(started,@"user_pause").count==1 && !started.desired,
        "Pause is recorded as a user request without claiming Tether exited");

    GuardianFixtureController *attached=Fixture(identity); attached.desired=YES; attached.inspectionStateObserved=YES;
    dispatch_sync(attached.queue,^{ [attached receiveInspection:ready status:0 expired:NO]; });
    Check([attached.recoverySource isEqual:@"afterUSBAttachRecovery"] && EventsNamed(attached,@"usb_attached").count==1,
        "A later physical USB observation has a distinct automatic recovery source");
    GuardianFixtureController *exited=Fixture(identity); exited.desired=YES; exited.previousTetherRunning=YES;
    dispatch_sync(exited.queue,^{ [exited tick]; });
    Check([exited.recoverySource isEqual:@"afterTetherExitRecovery"] && exited.launchRequests==0,
        "Observed Tether exit selects exit recovery without falsely claiming a new launch");

    GuardianFixtureController *opened=Fixture(identity);
    [opened openTether]; Drain(opened);
    Check(EventsNamed(opened,@"user_open_tether").count==1 && [opened.recoverySource isEqual:@"afterOpenRecovery"] &&
        opened.launchRequests==0 && [opened.helperKinds isEqual:@[@"inspect"]],
        "Open records its intent and queues fresh inspection instead of bypassing recovery");
    GuardianFixtureController *reconnected=Fixture(identity); reconnected.fakePresent=YES;
    [reconnected reconnect]; Drain(reconnected);
    Check(EventsNamed(reconnected,@"user_reconnect").count==1 && [reconnected.recoverySource isEqual:@"afterReconnectRecovery"],
        "Explicit Reconnect retains its own request attribution");

    GuardianFixtureController *late=Fixture(identity);
    late.desired=YES; late.launching=YES; late.activeLaunchSource=@"afterStartRecovery";
    late.launchSource=@"afterReconnectRecovery"; late.launchAttemptID=@"fixture_launch_1";
    uint64_t originalGeneration=late.generation;
    [late endSession]; [late endSession]; Drain(late);
    NSArray *endRequests=EventsNamed(late,@"user_end_session");
    Check(endRequests.count==2 && [endRequests[0][@"accepted"] boolValue] && ![endRequests[1][@"accepted"] boolValue],
        "Repeated End clicks remain auditable while the duplicate request is marked unaccepted");
    dispatch_sync(late.queue,^{ late.fakePresent=YES; [late receiveLaunchResult:identity success:YES generation:originalGeneration]; });
    NSArray *returned=EventsNamed(late,@"launch_returned");
    Check(returned.count==1,"A late OS launch handoff produces one correlated result event");
    if(returned.count) {
        NSDictionary *fields=returned[0];
        Check([fields[@"launch_attempt_id"] isEqual:@"fixture_launch_1"] && [fields[@"source"] isEqual:@"afterStartRecovery"] &&
            [fields[@"generation"] unsignedLongLongValue]==originalGeneration,
            "Late launch retains its immutable attempt source and generation even after a later request changes the pending source");
        Check([fields[@"result"] isEqual:@"returned_app"] && [fields[@"verified"] boolValue] && ![fields[@"accepted"] boolValue],
            "A verified app returned after End is recorded as an unaccepted old request");
        Check(fields[@"created_process"]==nil && fields[@"shooting_verified"]==nil && late.launchRequests==0,
            "A returned application never claims process creation or shooting readiness");
    }
    GuardianFixtureController *absent=Fixture(identity);
    [absent endSession]; Drain(absent);
    Check(EventsNamed(absent,@"session_ended").count==1 && [EventsNamed(absent,@"session_ended")[0][@"observation"] isEqual:@"tether_absent"],
        "Ended is logged only with a reliable process-absence observation");
}

static NSUInteger BlockedFor(GuardianFixtureController *fixture,NSString *reason) {
    NSUInteger count=0;
    for(NSDictionary *fields in EventsNamed(fixture,@"recovery_blocked")) if([fields[@"reason"] isEqual:reason]) ++count;
    return count;
}
static void CheckOpenRecoveryGate(NSDictionary *ready,NSDictionary *identity) {
    NSDictionary *preview=Changed(ready,@"known_camera_apps",@[@{@"name":@"Preview",@"pid":@64956}]);
    GuardianFixtureController *blocked=Fixture(identity);
    blocked.inspection=ready; blocked.inspectionObservationValid=YES; blocked.inspectionObservedAt=GuardianNow()-10;
    [blocked openTether]; Drain(blocked);
    Check(blocked.desired && blocked.pendingRecovery && blocked.launchRequests==0 &&
        [blocked.helperKinds isEqual:@[@"inspect"]],"Open cannot launch using stale cached readiness; it requests a new inspection");
    dispatch_sync(blocked.queue,^{ [blocked completeHelper:0 result:preview]; });
    Check(blocked.pendingRecovery && blocked.launchRequests==0 && blocked.helperKinds.count==1 && [blocked.state isEqual:@"blocked"],
        "A running Preview blocks Open while retaining the requested recovery");
    Check([blocked.messageEN containsString:@"Preview"] || [blocked.messageZH containsString:@"预览"],
        "The blocked status identifies the detected application instead of a generic failure");
    NSUInteger blockedCount=BlockedFor(blocked,@"camera_apps_running");
    NSUInteger appEvents=EventsNamed(blocked,@"recovery_blocked_app").count;
    NSDictionary *blockerEvent=EventsNamed(blocked,@"recovery_blocked").lastObject;
    Check([blockerEvent[@"blocking_app"] isEqual:@"preview"] && [blockerEvent[@"blocking_app_count"] isEqual:@1],
        "The persisted gate identifies Preview using a fixed identifier and a typed count");
    dispatch_sync(blocked.queue,^{
        for(unsigned i=0;i<100;++i) [blocked receiveInspection:preview status:0 expired:NO];
    });
    Check(blockedCount==1 && BlockedFor(blocked,@"camera_apps_running")==1 &&
        EventsNamed(blocked,@"recovery_blocked_app").count==appEvents,
        "Repeated Preview-blocked inspections log the reason and app once without flooding");
    Check(blocked.pendingRecovery && blocked.launchRequests==0 && blocked.helperKinds.count==1,
        "Blocked polling neither loses recovery intent nor starts USB work");
    NSUInteger unblockedBefore=EventsNamed(blocked,@"recovery_unblocked").count;
    dispatch_sync(blocked.queue,^{ blocked.recoverAfter=0; [blocked receiveInspection:ready status:0 expired:NO]; });
    Check(EventsNamed(blocked,@"recovery_unblocked").count==unblockedBefore+1 &&
        [blocked.helperKinds isEqual:@[@"inspect",@"repair"]] && blocked.launchRequests==0,
        "Removing Preview resumes pending USB preparation and records the gate opening");
    NSDictionary *repair=blocked.helperRequests.lastObject;
    NSArray *arguments=repair[@"arguments"];
    Check([repair[@"name"] isEqual:@"s1h_iousbhost_probe"] &&
        [arguments containsObject:@"--drain-input"] && [arguments containsObject:@"--require-s1h"] &&
        [arguments containsObject:@"--expected-interface-id"] && [arguments containsObject:@"123456"],
        "Open uses the production strict S1H drain and expected-interface helper arguments");
    dispatch_sync(blocked.queue,^{ [blocked completeHelper:0 result:@{}]; });
    Check(blocked.launchRequests==0 && [blocked.helperKinds isEqual:@[@"inspect",@"repair",@"inspect"]],
        "Even a successful probe must pass the fresh post-repair inspection before launch");
    dispatch_sync(blocked.queue,^{ [blocked completeHelper:0 result:ready]; });
    Check(blocked.launchRequests==1 && [blocked.launchSource isEqual:@"afterOpenRecovery"] && !blocked.pendingRecovery,
        "Open launches once only after strict preparation and fresh inspection succeed");

    GuardianFixtureController *failed=Fixture(identity);
    [failed openTether]; Drain(failed);
    dispatch_sync(failed.queue,^{
        [failed completeHelper:0 result:ready]; failed.recoverAfter=0;
        [failed receiveInspection:ready status:0 expired:NO]; [failed completeHelper:23 result:@{}];
    });
    Check(failed.launchRequests==0 && ![failed.helperKinds.lastObject isEqual:@"inspect"] && failed.retryCount==1,
        "A failed drain is not converted into an Open launch");

    GuardianFixtureController *postBlocked=Fixture(identity);
    [postBlocked openTether]; Drain(postBlocked);
    dispatch_sync(postBlocked.queue,^{
        [postBlocked completeHelper:0 result:ready]; postBlocked.recoverAfter=0;
        [postBlocked receiveInspection:ready status:0 expired:NO];
        postBlocked.retryCount=2;
    });
    for(unsigned attempt=0;attempt<3;++attempt) {
        dispatch_sync(postBlocked.queue,^{
            [postBlocked completeHelper:0 result:@{}];
            [postBlocked completeHelper:0 result:preview];
        });
        Check(postBlocked.launchRequests==0 && postBlocked.pendingRecovery && postBlocked.retryCount==2,
            "Post-repair Preview arrival retains pending recovery without consuming an I/O failure retry");
        NSUInteger helpersBefore=postBlocked.helperKinds.count;
        dispatch_sync(postBlocked.queue,^{
            for(unsigned i=0;i<20;++i) [postBlocked receiveInspection:preview status:0 expired:NO];
        });
        Check(postBlocked.helperKinds.count==helpersBefore && postBlocked.launchRequests==0,
            "Repeated post-repair blocker observations never spin up another helper");
        dispatch_sync(postBlocked.queue,^{ postBlocked.recoverAfter=0; [postBlocked receiveInspection:ready status:0 expired:NO]; });
        Check(postBlocked.task && [postBlocked.taskKind isEqual:@"repair"] && postBlocked.launchRequests==0,
            "Removing each post-repair blocker resumes preparation while keeping launch gated");
    }
    dispatch_sync(postBlocked.queue,^{
        [postBlocked completeHelper:0 result:@{}]; [postBlocked completeHelper:0 result:ready];
    });
    Check(postBlocked.launchRequests==1 && postBlocked.retryCount==0 && !postBlocked.pendingRecovery,
        "Three post-repair blockers can clear and complete one handoff without exhausting retries");

    GuardianFixtureController *unknown=Fixture(identity);
    [unknown openTether]; Drain(unknown);
    dispatch_sync(unknown.queue,^{ [unknown completeHelper:1 result:nil]; });
    Check(unknown.launchRequests==0 && unknown.helperKinds.count==1 && unknown.pendingRecovery,
        "Inspector failure after Open preserves intent without claiming absence or launching");
    GuardianFixtureController *invalid=Fixture(identity);
    [invalid openTether]; Drain(invalid);
    dispatch_sync(invalid.queue,^{ [invalid completeHelper:0 result:@{}]; });
    Check(invalid.launchRequests==0 && invalid.helperKinds.count==1 && [invalid.state isEqual:@"inspection_error"],
        "Malformed successful inspection cannot bypass the Open gate");
    GuardianFixtureController *running=Fixture(identity); running.fakePresent=YES;
    [running openTether]; Drain(running);
    Check(running.launchRequests==0 && running.helperKinds.count==0 && running.normalQuitRequests==0,
        "Open leaves an already-running Tether alone without preparation, second launch or quit");
    GuardianFixtureController *unknownProcess=Fixture(identity); unknownProcess.fakeObservationValid=NO;
    [unknownProcess openTether]; Drain(unknownProcess);
    Check(unknownProcess.launchRequests==0 && ![unknownProcess.helperKinds containsObject:@"repair"] && unknownProcess.normalQuitRequests==0,
        "Unknown process enumeration never authorizes Open to repair, launch or quit");
    dispatch_sync(unknownProcess.queue,^{
        if(unknownProcess.helperCompletion) [unknownProcess completeHelper:0 result:ready];
        else [unknownProcess receiveInspection:ready status:0 expired:NO];
    });
    Check(!unknownProcess.tetherObservationValid && [unknownProcess.state isEqual:@"inspection_error"] && unknownProcess.launchRequests==0,
        "A valid USB inspection with unknown process enumeration remains unknown instead of being labeled running");

    NSArray *sanitized=GuardianBlockingCameraApps(Changed(ready,@"known_camera_apps",@[
        @{@"name":@"Preview",@"pid":@64956,@"path":@"/private/user/document"},
        @{@"name":@"/private/person/app",@"pid":@64957},
        @{@"name":NSNull.null,@"pid":NSNull.null}
    ]));
    NSData *json=[NSJSONSerialization dataWithJSONObject:sanitized options:0 error:NULL];
    NSString *text=json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
    Check(json && ![text containsString:@"/private/"] && ![text containsString:@"document"] && [text containsString:@"Preview"],
        "Visible blocker metadata uses fixed app labels and never echoes paths or arbitrary app names");
    Check([GuardianPublishedGate(ready,YES,NO,NO) isEqual:@"inspection_error"] &&
        [GuardianPublishedGate(ready,NO,YES,NO) isEqual:@"process_observation_unknown"],
        "Expired inspector or unknown process observations publish unknown gate states instead of ready");
    GuardianFixtureController *quiet=Fixture(identity); quiet.blockingCameraApps=GuardianBlockingCameraApps(preview);
    dispatch_sync(quiet.queue,^{
        quiet.desired=NO; quiet.pendingRecovery=YES;
        for(unsigned i=0;i<100;++i) [quiet observeRecoveryGate:@"camera_apps_running"];
        quiet.desired=YES; quiet.pendingRecovery=NO;
        for(unsigned i=0;i<100;++i) [quiet observeRecoveryGate:@"camera_apps_running"];
    });
    Check(EventsNamed(quiet,@"recovery_blocked").count==0,
        "Paused or nonpending observations never manufacture recovery-blocked log spam");
    dispatch_sync(quiet.queue,^{
        quiet.pendingRecovery=YES; quiet.tetherObservationValid=YES; quiet.tetherRunning=YES;
        for(unsigned i=0;i<100;++i) [quiet observeRecoveryGate:@"camera_apps_running"];
    });
    Check(EventsNamed(quiet,@"recovery_blocked").count==0,
        "An observed running Tether is never logged as a failed recovery merely because clients are present");
}

static void CheckEndTransitions(NSDictionary *ready, NSDictionary *identity) {
    GuardianFixtureController *direct=Fixture(identity); direct.fakePresent=YES; direct.desired=YES;
    [direct endSession]; Drain(direct);
    uint64_t firstEndGeneration=direct.generation;
    Check(!direct.desired && !direct.pendingRecovery && direct.endingSession,"End revokes automatic recovery before requesting normal quit");
    Check(direct.normalQuitRequests==1 && direct.quitRequested && [direct.quitPurpose isEqual:@"end"],"End selects one normal-quit target with end purpose");
    [direct endSession]; Drain(direct);
    Check(direct.generation==firstEndGeneration && direct.quitRequested && GuardianSameIdentity(direct.quitIdentity,identity),"Duplicate End preserves generation and pending normal-quit identity");
    Check(direct.normalQuitRequests==1,"Duplicate End does not deliver a second normal-quit request");
    [direct start]; [direct reconnect]; [direct openTether]; Drain(direct);
    Check(!direct.desired && direct.launchRequests==0 && direct.normalQuitRequests==1,"Start, Reconnect and Open cannot override an End already in progress");
    direct.canForce=YES; [direct forceRestart]; Drain(direct);
    Check(!direct.desired && direct.pendingRecovery==NO && direct.canForce && direct.quitRequested,"Force Restart is rejected during End without consuming Force Quit consent");
    [direct pause]; Drain(direct);
    Check(!direct.endingSession && !direct.quitRequested && !direct.desired && !direct.canForce,"Cancel End removes future quit and restart consent");
    dispatch_sync(direct.queue,^{ [direct advanceEndSession]; });
    Check(direct.normalQuitRequests==1 && direct.launchRequests==0,"Cancelled End cannot request a later quit or restart");

    GuardianFixtureController *repair=Fixture(identity); repair.desired=YES; repair.pendingRecovery=YES;
    dispatch_sync(repair.queue,^{ [repair repairWithInspection:ready serviceRetried:NO generation:repair.generation]; });
    Check(repair.task && [repair.helperKinds isEqual:@[@"repair"]],"Production repair callback is pending before End race");
    [repair endSession]; Drain(repair);
    Check(repair.task && repair.endingSession && !repair.desired && [repair.state isEqual:@"ending_wait"],"End waits for an existing recovery instead of interrupting it");
    dispatch_sync(repair.queue,^{ [repair completeHelper:0 result:@{}]; });
    Check(repair.sessionEnded && !repair.endingSession && !repair.desired && !repair.pendingRecovery,"Late successful recovery settles End after reliable process absence");
    Check(repair.helperKinds.count==1 && repair.launchRequests==0 && repair.normalQuitRequests==0,"Late repair success cannot inspect, restart services or launch Tether after End");
    Check(repair.fakeTasks.firstObject.terminationAttempts==0,"End never terminates the in-flight USB helper");

    GuardianFixtureController *service=Fixture(identity); service.desired=YES; service.inspection=ready;
    dispatch_sync(service.queue,^{ [service inspectForRestartGeneration:service.generation]; });
    NSDictionary *restartReady=Changed(ready,@"restart_guard",@"opt_in_required");
    dispatch_sync(service.queue,^{ [service completeHelper:0 result:restartReady]; });
    Check([service.helperKinds isEqual:@[@"inspect",@"service-restart"]] && service.task,"Production service-restart callback is pending before End race");
    [service endSession]; Drain(service);
    dispatch_sync(service.queue,^{ [service completeHelper:0 result:@{@"status":@"released",@"inspection":ready}]; });
    Check(service.sessionEnded && service.helperKinds.count==2 && service.launchRequests==0,"Late successful service release cannot start a repair after End");
    Check(service.fakeTasks.lastObject.terminationAttempts==0,"End lets an already-owned service helper finish safely");

    GuardianFixtureController *launch=Fixture(identity); launch.desired=YES; launch.launching=YES;
    uint64_t launchGeneration=launch.generation;
    [launch endSession]; Drain(launch);
    Check(launch.launching && launch.endingSession && launch.normalQuitRequests==0,"End waits for an already-submitted launch to resolve");
    dispatch_sync(launch.queue,^{ launch.fakePresent=YES; [launch receiveLaunchResult:identity success:YES generation:launchGeneration]; });
    Check(!launch.launching && !launch.desired && !launch.pendingRecovery && GuardianSameIdentity(launch.ownedIdentity,identity),"Late launch handoff retains the exact owned identity without restoring recovery");
    Check(launch.normalQuitRequests==1 && [launch.quitPurpose isEqual:@"end"] && launch.launchRequests==0,"Late launch handoff advances End into normal quit without relaunch");
    Check(![launch.publishedStates containsObject:@"tether_running"],"Late launch cannot overwrite an End with a running-success message");

    GuardianFixtureController *cancel=Fixture(identity); cancel.desired=YES; cancel.launching=YES;
    uint64_t cancelledLaunchGeneration=cancel.generation;
    [cancel endSession]; [cancel pause]; Drain(cancel);
    dispatch_sync(cancel.queue,^{ cancel.fakePresent=YES; [cancel receiveLaunchResult:identity success:YES generation:cancelledLaunchGeneration]; });
    Check(!cancel.endingSession && !cancel.desired && cancel.normalQuitRequests==0 && cancel.launchRequests==0,"Cancel End before launch handoff leaves the arriving Tether alone");
    Check([cancel.state isEqual:@"paused"],"Cancelled launch completion cannot overwrite Paused status");

    GuardianFixtureController *cancelRepair=Fixture(identity); cancelRepair.desired=YES;
    dispatch_sync(cancelRepair.queue,^{ [cancelRepair repairWithInspection:ready serviceRetried:NO generation:cancelRepair.generation]; });
    [cancelRepair endSession]; [cancelRepair pause]; Drain(cancelRepair);
    dispatch_sync(cancelRepair.queue,^{ [cancelRepair completeHelper:0 result:@{}]; });
    Check(!cancelRepair.endingSession && !cancelRepair.sessionEnded && !cancelRepair.desired && cancelRepair.helperKinds.count==1 && cancelRepair.launchRequests==0,"Cancel End during repair discards old success without falsely declaring session ended");

    GuardianFixtureController *unknown=Fixture(identity); unknown.fakeObservationValid=NO;
    [unknown endSession]; Drain(unknown);
    Check(unknown.endingSession && !unknown.sessionEnded && unknown.normalQuitRequests==0 && [unknown.state isEqual:@"end_needs_attention"],"Unknown process observation cannot settle End or select a quit target");
    dispatch_sync(unknown.queue,^{ unknown.fakeObservationValid=YES; [unknown advanceEndSession]; });
    Check(unknown.sessionEnded && !unknown.desired && !unknown.endingSession,"A fresh reliable absence can settle a previously unknown End");

    GuardianFixtureController *rejected=Fixture(identity); rejected.fakePresent=YES; rejected.rejectQuitTarget=YES;
    [rejected endSession]; Drain(rejected);
    dispatch_sync(rejected.queue,^{ rejected.fakeIdentity=Changed(identity,@"start_seconds",@1234568); [rejected advanceEndSession]; });
    Check(rejected.endQuitAttempted && rejected.normalQuitRequests==1 && !rejected.quitRequested && !rejected.desired,"An unverified or changed End target is never automatically selected a second time");
    Check([rejected.state isEqual:@"end_needs_attention"] && rejected.launchRequests==0,"Rejected End target requires manual attention without restarting");
    Check(!direct.timer && !repair.timer && !launch.timer && !service.timer,"Fixture controllers never create a real observation timer");
}
int main(void) {
    @autoreleasepool {
        NSDictionary *ready = @{
            @"matching_usb_id_device_count": @1, @"s1h_device_count": @1,
            @"s1h_interface_count": @1, @"interface_registry_id": @123456,
            @"device_model_state": @"confirmed", @"usb_product_name": @"DC-S1H",
            @"known_camera_apps": @[], @"other_usb_ptp_interfaces": @[],
            @"inspection_error": NSNull.null
        };
        Check(GuardianInspectionReadiness(ready, NO) == nil, "One confirmed S1H with no camera client permits preparation");
        Check([GuardianInspectionReadiness(ready, YES) isEqual:@"tether_running"], "A running Tether blocks preparation regardless of capture visibility");
        Check([GuardianInspectionReadiness(@{}, NO) isEqual:@"inspection_error"], "Missing inspection fields remain unknown, not absent");
        Check([GuardianInspectionReadiness(nil, NO) isEqual:@"inspection_error"], "Missing inspector result remains unknown");
        Check([GuardianInspectionReadiness(Changed(ready, @"inspection_error", @"registry query failed"), NO) isEqual:@"inspection_error"], "An explicit detector error cannot authorize USB preparation");
        Check([GuardianInspectionReadiness(Changed(ready, @"matching_usb_id_device_count", @"1"), NO) isEqual:@"inspection_error"], "Malformed numeric detector output is refused");
        Check([GuardianInspectionReadiness(Changed(ready, @"device_model_state", NSNull.null), NO) isEqual:@"inspection_error"], "Malformed model state remains an inspection error");
        Check([GuardianInspectionReadiness(Changed(ready, @"known_camera_apps", NSNull.null), NO) isEqual:@"inspection_error"], "Unknown client enumeration is not an empty client list");
        Check([GuardianInspectionReadiness(Changed(ready, @"other_usb_ptp_interfaces", NSNull.null), NO) isEqual:@"inspection_error"], "Unknown other-camera enumeration blocks preparation");
        NSMutableDictionary *absent = [ready mutableCopy];
        absent[@"matching_usb_id_device_count"] = @0; absent[@"s1h_device_count"] = @0;
        absent[@"s1h_interface_count"] = @0; absent[@"interface_registry_id"] = @0;
        absent[@"device_model_state"] = @"unknown";
        Check([GuardianInspectionReadiness(absent, NO) isEqual:@"no_device"], "A well-formed empty USB inventory is distinctly absent");
        Check(![GuardianInspectionReadiness(absent, NO) isEqual:GuardianInspectionReadiness(@{}, NO)], "Absence and detection failure are separate outcomes");
        Check([GuardianInspectionReadiness(Changed(ready, @"known_camera_apps", @[@{@"name": @"Capture One"}]), NO) isEqual:@"camera_apps_running"], "Another camera application blocks automatic preparation");
        Check([GuardianInspectionReadiness(Changed(ready, @"matching_usb_id_device_count", @2), NO) isEqual:@"ambiguous_device"], "Multiple matching cameras cannot be selected arbitrarily");
        Check([GuardianInspectionReadiness(Changed(ready, @"s1h_interface_count", @2), NO) isEqual:@"ambiguous_device"], "Multiple matching interfaces cannot be selected arbitrarily");
        Check([GuardianInspectionReadiness(Changed(ready, @"device_model_state", @"unknown"), NO) isEqual:@"ambiguous_device"], "Shared USB identifiers alone do not establish the S1H model");
        Check([GuardianInspectionReadiness(Changed(ready, @"interface_registry_id", @0), NO) isEqual:@"ambiguous_device"], "A missing registry identity cannot authorize a handoff");
        Check([GuardianInspectionReadiness(Changed(ready, @"other_usb_ptp_interfaces", @[@{@"registry_id": @99}]), NO) isEqual:@"other_camera"], "Another PTP camera prevents a broad service recovery");

        Check(GuardianAcceptCompletion(7, 7, YES, NO, NO), "Only a current enabled operation may continue after success");
        Check(!GuardianAcceptCompletion(7, 8, YES, NO, NO), "A late zero exit from the prior generation cannot continue");
        Check(!GuardianAcceptCompletion(7, 7, NO, NO, NO), "Pausing prevents a successful child from opening Tether");
        Check(!GuardianAcceptCompletion(7, 7, YES, YES, NO), "Tool shutdown prevents new work even before desired state settles");
        Check(!GuardianAcceptCompletion(7, 7, YES, NO, YES), "A manual Tether launch prevents a second launch or repair stage");
        Check(!GuardianAcceptCompletion(7, 9, YES, NO, NO), "Restarting supervision does not revive a previously cancelled operation");
        Check(!GuardianAcceptCompletion(UINT64_MAX, 0, YES, NO, NO), "Generation comparison never accepts a different wrapped value");

        NSDictionary *identity = @{
            @"pid": @23456, @"uid": @501, @"real_uid": @501,
            @"start_seconds": @1234567, @"start_microseconds": @543210,
            @"path": @"/Applications/LUMIX Tether.app/Contents/MacOS/LUMIX Tether"
        };
        Check(GuardianSameIdentity(identity, [identity copy]), "A complete unchanged process identity matches");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"pid", @23457)), "A replacement PID cannot inherit the old quit target");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"start_seconds", @1234568)), "PID reuse with another start time cannot authorize force quit");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"start_microseconds", @543211)), "Subsecond PID reuse is detected");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"uid", @502)), "A changed effective owner invalidates the target");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"real_uid", @502)), "A changed real owner invalidates the target");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"path", @"/Applications/Other.app/Contents/MacOS/Other")), "An executable-path change invalidates the target");
        Check(!GuardianSameIdentity(@{}, @{}) && !GuardianSameIdentity(nil, identity), "Missing identities never compare as the same process");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"pid", NSNull.null)), "Malformed identity values are refused without messaging NSNull");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"start_seconds", @0)), "An unknown process start time cannot authorize a signal");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"start_microseconds", @1000000)), "Out-of-range microseconds cannot authorize a signal");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"path", @"LUMIX Tether")), "A process name is not an absolute executable identity");
        Check(!GuardianSameIdentity(identity, Changed(identity, @"pid", @1)), "A system PID is not a valid quit target");

        Check(GuardianObservationFresh(YES,100,102,2),"A process observation is fresh at the inclusive two-second boundary");
        Check(!GuardianObservationFresh(YES,100,102.001,2),"An expired process observation cannot certify absence");
        Check(GuardianObservationFresh(YES,100,104,4) && !GuardianObservationFresh(YES,100,104.001,4),"USB inspection has its separate four-second freshness bound");
        Check(!GuardianObservationFresh(NO,100,100,2),"An explicitly invalid observation remains unknown even at the current time");
        Check(!GuardianObservationFresh(YES,100,99,2),"A clock value preceding the observation is refused");
        Check(!GuardianObservationFresh(YES,0,1,2),"An uninitialized observation timestamp is refused");
        Check(!GuardianObservationFresh(YES,NAN,100,2) && !GuardianObservationFresh(YES,100,INFINITY,2),"Non-finite observation clocks cannot certify freshness");
        Check(!GuardianObservationFresh(YES,100,101,0) && !GuardianObservationFresh(YES,100,101,NAN),"Invalid freshness limits cannot certify observations");
        Check([GuardianCaptureState(YES,YES) isEqual:@"unknown"],"A running Tether never proves shootability or transfer completion");
        Check([GuardianCaptureState(NO,NO) isEqual:@"unknown"] && [GuardianCaptureState(NO,YES) isEqual:@"unknown"],"Unknown process status never becomes verified absence or shooting readiness");
        Check([GuardianCaptureState(YES,NO) isEqual:@"not_running"],"Reliable process absence only reports Tether not running");
        Check([GuardianEndDecision(NO,NO,NO,NO,NO,YES,YES) isEqual:@"none"],"A cancelled End has no deferred transition");
        Check([GuardianEndDecision(YES,YES,NO,NO,NO,YES,YES) isEqual:@"none"],"Tool shutdown suppresses deferred End actions");
        Check([GuardianEndDecision(YES,NO,YES,NO,NO,YES,YES) isEqual:@"wait_work"],"End waits for an owned helper despite apparent process absence");
        Check([GuardianEndDecision(YES,NO,NO,YES,NO,YES,YES) isEqual:@"wait_work"],"End waits for an unresolved launch before certifying closure");
        Check([GuardianEndDecision(YES,NO,NO,NO,YES,YES,YES) isEqual:@"wait_quit"],"End preserves an existing quit request while it resolves");
        Check([GuardianEndDecision(YES,NO,NO,NO,NO,NO,YES) isEqual:@"unknown"],"Unknown observation overrides a cached absent flag");
        Check([GuardianEndDecision(YES,NO,NO,NO,NO,YES,YES) isEqual:@"settled"],"End settles only after owned work and reliable absence");
        Check([GuardianEndDecision(YES,NO,NO,NO,NO,YES,NO) isEqual:@"request_verified_quit"],"An observed live process requires identity-verified normal quit");
        Check(GuardianForceModeAllowed(YES,YES,YES,YES,@"end"),"End exposes only explicit Force Quit consent");
        Check(!GuardianForceModeAllowed(YES,NO,YES,YES,@"end"),"Force Restart cannot consume End's Force Quit consent");
        Check(!GuardianForceModeAllowed(NO,YES,YES,YES,@"reconnect"),"Force Quit cannot consume a reconnect consent");
        Check(!GuardianForceModeAllowed(YES,YES,YES,YES,@"reconnect"),"Mismatched quit purpose cannot authorize Force Quit");
        Check(!GuardianForceModeAllowed(YES,YES,NO,YES,@"end") && !GuardianForceModeAllowed(YES,YES,YES,NO,@"end"),"An unavailable or already-cleared force action cannot run");

        CheckEndTransitions(ready,identity);
        CheckObservationEvents(identity);
        CheckActionAndLaunchEvents(ready,identity);
        CheckOpenRecoveryGate(ready,identity);
        Check(ForbiddenProcessCalls==0,"All exercised asynchronous paths remain inside fake process boundaries");
        printf("Guardian policy: %u checks, %u failures; production pure functions and fake asynchronous End paths; no hardware, app launch, real process enumeration or signals.\n", Checks, Failures);
        return Failures ? 1 : 0;
    }
}
