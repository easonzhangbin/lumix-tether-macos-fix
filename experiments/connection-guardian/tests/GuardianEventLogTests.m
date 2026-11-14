/* Filesystem-only tests of the real logger. All files live in an isolated
 * temporary directory and are removed afterwards. No controller, process
 * observation, application, network or camera operation is involved. */
#import "../GuardianEventLog.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

static unsigned Checks,Failures;
static void Check(BOOL condition,const char *label) {
    ++Checks;
    if(condition) printf("PASS %s\n",label);
    else { ++Failures; fprintf(stderr,"FAIL %s\n",label); }
}
static NSString *Directory(NSString *root,NSString *name) {
    NSString *path=[root stringByAppendingPathComponent:name];
    BOOL made=[NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    Check(made,"Temporary test directory is created privately"); return path;
}
static NSArray<NSDictionary *> *Entries(NSString *path,BOOL *valid) {
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data) { *valid=NO; return @[]; }
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text || (data.length && ![text hasSuffix:@"\n"])) { *valid=NO; return @[]; }
    NSMutableArray *entries=[NSMutableArray array];
    for(NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if(!line.length) continue;
        NSData *lineData=[line dataUsingEncoding:NSUTF8StringEncoding];
        id object=[NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
        if(![object isKindOfClass:NSDictionary.class] || lineData.length+1>8192) { *valid=NO; return @[]; }
        [entries addObject:object];
    }
    *valid=YES; return entries;
}
static mode_t Permissions(NSString *path) {
    struct stat info={0}; return lstat(path.fileSystemRepresentation,&info)==0 ? info.st_mode&0777 : 0;
}
static NSDictionary *Fields(NSDictionary *entry) {
    /* Fields are top-level in the production schema. This helper also gives
     * a useful failure if an accidental incompatible nesting is introduced. */
    return entry;
}
static void CheckBasic(NSString *root) {
    NSString *directory=Directory(root,@"basic");
    GuardianEventLog *log=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:directory isDirectory:YES]];
    NSMutableDictionary *first=[@{@"source":@"user_start",@"generation":@1,@"desired_running":@YES} mutableCopy];
    [log recordEvent:@"user_start" fields:first];
    first[@"generation"]=@999;
    [log recordEvent:@"user_end_session" fields:@{@"source":@"user_end",@"generation":@2}];
    [log recordEvent:@"launch_returned" fields:@{@"source":@"guardian_request",@"generation":@3,@"success":@YES}];
    [log flush];
    BOOL valid=NO; NSArray *entries=Entries(log.fileURL.path,&valid);
    Check(valid && entries.count==3,"Flush drains multiple writes into complete independently parseable JSON lines");
    if(entries.count==3) {
        Check([entries[0][@"event"] isEqual:@"user_start"] && [entries[1][@"event"] isEqual:@"user_end_session"] &&
            [entries[2][@"event"] isEqual:@"launch_returned"],"JSONL preserves enqueue order");
        Check([Fields(entries[0])[@"generation"] isEqual:@1],"Enqueued fields are snapshotted before caller mutation");
        Check([entries[0][@"sequence"] unsignedLongLongValue]<[entries[1][@"sequence"] unsignedLongLongValue] &&
            [entries[1][@"sequence"] unsignedLongLongValue]<[entries[2][@"sequence"] unsignedLongLongValue],"Sequence increases with every persisted event");
        BOOL schema=YES;
        for(NSDictionary *entry in entries) schema &= [entry[@"schema_version"] isEqual:@1] &&
            [entry[@"time"] isKindOfClass:NSString.class] && [entry[@"local_time"] isKindOfClass:NSString.class] &&
            [entry[@"uptime_seconds"] isKindOfClass:NSNumber.class] &&
            [entry[@"run_id"] isKindOfClass:NSString.class] && [entry[@"guardian_pid"] isKindOfClass:NSNumber.class];
        Check(schema,"Each event has version, UTC/local time, monotonic time and run/process correlation");
        Check([entries[0][@"run_id"] isEqual:entries[2][@"run_id"]],"One writer keeps a stable run identifier");
        Check([entries[0][@"message_zh"] isEqual:@"请求开始拍摄并启用守护"] &&
            [entries[1][@"message_zh"] isEqual:@"请求结束本次拍摄"],"Known event labels round-trip as valid multilingual JSON without arbitrary caller text");
    }
    Check(Permissions(directory)==0700 && Permissions(log.fileURL.path)==0600,"Directory and event file permissions are private");
    Check(log.errorDescription.length==0,"Normal writes and fsync leave no logging error");
    [log flush];
    BOOL validAfter=NO; NSArray *after=Entries(log.fileURL.path,&validAfter);
    Check(validAfter && after.count==entries.count,"Repeated flush does not duplicate or synthesize events");
}
static void CheckFiltering(NSString *root) {
    NSString *directory=Directory(root,@"filtering");
    GuardianEventLog *log=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:directory isDirectory:YES]];
    [log recordEvent:@"privacy_test" fields:@{
        @"source":@"safe_identifier",@"generation":@7,@"success":@YES,@"blocking_app":@"preview",@"blocking_app_count":@1,
        @"serial":@"PRIVATE-SERIAL",@"path":@"/private/photos/照片.RW2",@"email":@"private@example.invalid",
        @"nested":@{@"serial":@"SECRET"},@"payload":@"quote\"slash\\line\n中文",
        @"reason":@"含中文\nquote\"slash\\",@"request_source":@"bad/identifier",@"state":@"bad\nidentifier",
        @"phase":[@"a" stringByPaddingToLength:129 withString:@"a" startingAtIndex:0],
        @"pid":@"not_a_number",@"exit_status":NSNull.null,@"error_code":@(NAN)
    }];
    [log recordEvent:@"identifier_test" fields:@{@"source":@"safe.value-2_1",@"generation":@8}];
    [log flush];
    BOOL valid=NO; NSArray *entries=Entries(log.fileURL.path,&valid);
    Check(valid && entries.count==2,"Invalid or multilingual fields cannot inject extra JSONL lines");
    if(entries.count==2) {
        NSDictionary *entry=Fields(entries[0]);
        Check([entry[@"source"] isEqual:@"safe_identifier"] && [entry[@"generation"] isEqual:@7] && [entry[@"success"] boolValue],"Allowlisted safe identifiers and typed values are retained");
        Check([entry[@"blocking_app"] isEqual:@"preview"] && [entry[@"blocking_app_count"] isEqual:@1],
            "A fixed blocker identifier and typed count survive event privacy filtering");
        BOOL absent=YES;
        for(NSString *key in @[@"serial",@"path",@"email",@"nested",@"payload",@"reason",@"request_source",@"state",@"phase",@"pid",@"exit_status",@"error_code"])
            absent &= entry[key]==nil;
        Check(absent,"Unknown fields, unsafe strings, invalid types and non-finite numbers are dropped");
    }
    NSString *text=[NSString stringWithContentsOfFile:log.fileURL.path encoding:NSUTF8StringEncoding error:NULL];
    Check(![text containsString:@"PRIVATE-SERIAL"] && ![text containsString:@"照片"] &&
        ![text containsString:@"private@example.invalid"] && ![text containsString:@"SECRET"],"Private nested, Unicode and path values never reach the event file");
    [log recordEvent:@"bad\nevent" fields:@{}]; [log recordEvent:@"非法事件" fields:@{}];
    [log recordEvent:@"bad/event" fields:@{}]; [log flush];
    BOOL validAfter=NO; NSArray *after=Entries(log.fileURL.path,&validAfter);
    Check(validAfter && after.count==2,"Invalid event identifiers are dropped without corrupting previous lines");
    Check(log.errorDescription.length>0,"Invalid event rejection is reported as a logging error");
}
static void CheckRotation(NSString *root) {
    NSString *directory=Directory(root,@"rotation");
    GuardianEventLog *log=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:directory isDirectory:YES]];
    NSMutableDictionary *fields=[NSMutableDictionary dictionary];
    NSString *value=[@"x" stringByPaddingToLength:128 withString:@"x" startingAtIndex:0];
    for(NSString *key in @[@"source",@"request_source",@"result",@"reason",@"state",@"previous_state",@"helper_kind",@"purpose",@"quit_purpose",@"phase",@"trigger",@"mode",@"app_version",@"attempt_id",@"launch_attempt_id",@"helper_attempt_id",@"session_id",@"correlation_id",@"observation",@"verification",@"error_domain"]) fields[key]=value;
    for(NSUInteger index=0;index<5000;++index) {
        fields[@"generation"]=@(index); [log recordEvent:@"rotation_test" fields:fields];
        if(index%250==249) [log flush];
    }
    [log flush];
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL];
    NSSet *expected=[NSSet setWithArray:@[@"events.jsonl",@"events.jsonl.1",@"events.jsonl.2",@"events.jsonl.3",@"events.lock"]];
    Check(names.count==5 && [expected isEqual:[NSSet setWithArray:names]],"Rotation retains only the active file, three bounded archives and writer lock");
    BOOL sizes=YES,validLines=YES,permissions=YES,ordered=YES;
    uint64_t previousSequence=0; NSUInteger retained=0;
    for(NSString *name in @[@"events.jsonl.3",@"events.jsonl.2",@"events.jsonl.1",@"events.jsonl"]) {
        NSString *path=[directory stringByAppendingPathComponent:name];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        sizes &= attributes && [attributes[NSFileSize] unsignedLongLongValue]<=1024*1024;
        permissions &= Permissions(path)==0600;
        BOOL valid=NO; NSArray *entries=Entries(path,&valid); validLines &= valid && entries.count>0;
        for(NSDictionary *entry in entries) {
            uint64_t sequence=[entry[@"sequence"] unsignedLongLongValue];
            ordered &= sequence>previousSequence; previousSequence=sequence; ++retained;
        }
    }
    Check(sizes,"Every retained JSONL file stays within one MiB");
    Check(validLines && retained>0 && retained<5000,"Rotated files contain only complete bounded JSON entries and discard the oldest history");
    Check(ordered && previousSequence==5000,"Rotation preserves global event order and the newest event");
    Check(permissions,"Rotated archives retain private permissions");
    Check(log.errorDescription.length==0,"Bounded rotation succeeds without a logging error");
}
static void CheckUnsafeTargets(NSString *root) {
    NSString *outside=[root stringByAppendingPathComponent:@"outside-marker"];
    NSData *marker=[@"must_remain_unchanged" dataUsingEncoding:NSUTF8StringEncoding];
    [marker writeToFile:outside atomically:YES];
    for(NSString *kind in @[@"symlink",@"hardlink",@"directory",@"fifo"]) {
        NSString *directory=Directory(root,kind);
        NSString *target=[directory stringByAppendingPathComponent:@"events.jsonl"];
        int result=0;
        if([kind isEqual:@"symlink"]) result=symlink(outside.fileSystemRepresentation,target.fileSystemRepresentation);
        else if([kind isEqual:@"hardlink"]) result=link(outside.fileSystemRepresentation,target.fileSystemRepresentation);
        else if([kind isEqual:@"fifo"]) result=mkfifo(target.fileSystemRepresentation,0600);
        else result=mkdir(target.fileSystemRepresentation,0700);
        Check(result==0,"Unsafe event target fixture is created");
        GuardianEventLog *log=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:directory isDirectory:YES]];
        NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
        [log recordEvent:@"security_test" fields:@{}]; [log flush];
        Check([[NSData dataWithContentsOfFile:outside] isEqual:marker],"Logger never overwrites a symlink or hardlink destination");
        Check(log.errorDescription.length>0,"Unsafe linked or nonregular event target is reported and refused");
        if([kind isEqual:@"fifo"]) Check(NSProcessInfo.processInfo.systemUptime-began<2.0,"Flushing a refused FIFO returns promptly without opening a blocking writer");
    }
}
static void CheckWriterLock(NSString *root) {
    NSString *directory=Directory(root,@"locked-writer");
    NSString *lockPath=[directory stringByAppendingPathComponent:@"events.lock"];
    int lock=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC,0600);
    BOOL held=lock>=0 && flock(lock,LOCK_EX|LOCK_NB)==0;
    Check(held,"A test-owned lock simulates another writer without launching a process");
    if(!held) { if(lock>=0) close(lock); return; }
    GuardianEventLog *log=[[GuardianEventLog alloc] initWithDirectory:[NSURL fileURLWithPath:directory isDirectory:YES]];
    [log recordEvent:@"lock_test" fields:@{@"generation":@1}]; [log flush];
    Check(log.errorDescription.length>0 && ![NSFileManager.defaultManager fileExistsAtPath:log.fileURL.path],
        "A competing writer is refused without waiting or creating a partial event");
    flock(lock,LOCK_UN); close(lock);
    [log recordEvent:@"lock_test" fields:@{@"generation":@2}]; [log flush];
    BOOL valid=NO; NSArray *entries=Entries(log.fileURL.path,&valid);
    Check(valid && entries.count==1 && [Fields(entries[0])[@"generation"] isEqual:@2],
        "Writer recovers after lock release without replaying the refused event");
    Check(Permissions(lockPath)==0600 && log.errorDescription.length==0,"Writer lock stays private and successful recovery clears the error");
}
int main(void) {
    @autoreleasepool {
        NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"guardian-event-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        @try {
            Directory(root,@"");
            CheckBasic(root); CheckFiltering(root); CheckRotation(root); CheckUnsafeTargets(root); CheckWriterLock(root);
        } @catch(NSException *exception) {
            (void)exception; Check(NO,"Logger must not throw on tested invalid filesystem or field inputs");
        } @finally {
            Check([NSFileManager.defaultManager removeItemAtPath:root error:NULL],"Temporary logger fixtures are removed");
        }
        printf("Guardian event log: %u checks, %u failures; temporary files only.\n",Checks,Failures);
        return Failures ? 1 : 0;
    }
}
