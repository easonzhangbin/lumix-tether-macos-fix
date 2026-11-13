#import "GuardianEventLog.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static const off_t GuardianEventLogLimit = 1024 * 1024;
static const NSUInteger GuardianEventEntryLimit = 8192;

static BOOL GuardianEventIdentifier(NSString *value, NSUInteger maximum, BOOL lowercase) {
    if(![value isKindOfClass:NSString.class] || !value.length || value.length>maximum) return NO;
    NSString *allowed=lowercase ? @"abcdefghijklmnopqrstuvwxyz0123456789_.-" :
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-";
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:allowed].invertedSet].location==NSNotFound;
}
static NSDictionary *GuardianEventFields(NSDictionary *fields) {
    if(![fields isKindOfClass:NSDictionary.class]) return @{};
    NSSet *strings=[NSSet setWithArray:@[@"source",@"request_source",@"result",@"reason",@"state",@"previous_state",
        @"helper_kind",@"purpose",@"quit_purpose",@"phase",@"trigger",@"mode",@"app_version",@"attempt_id",
        @"launch_attempt_id",@"helper_attempt_id",@"session_id",@"correlation_id",@"observation",@"verification",@"error_domain"]];
    NSSet *numbers=[NSSet setWithArray:@[@"pid",@"tether_pid",@"previous_pid",@"start_seconds",@"start_microseconds",
        @"exit_status",@"error_code",@"generation",@"retry_count",@"duration_ms",@"usb_link_speed_bps",@"device_count",
        @"interface_count",@"expired",@"initial",@"verified",@"success",@"accepted",@"desired_running",@"ending_session",
        @"session_ended",@"tether_running",@"stopping",@"busy",@"normal_quit_delivered",@"already_running",@"observed"]];
    NSMutableDictionary *safe=[NSMutableDictionary dictionary];
    for(id key in fields) {
        if(![key isKindOfClass:NSString.class]) continue;
        id value=fields[key];
        if([strings containsObject:key] && GuardianEventIdentifier(value,128,NO)) safe[key]=[value copy];
        else if([numbers containsObject:key] && [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) safe[key]=value;
    }
    return safe;
}
static NSString *GuardianEventLabel(NSString *event) {
    NSDictionary *labels=@{
        @"app_started":@"守护工具启动",@"app_stopping":@"请求退出守护工具",@"app_stopped":@"守护工具已停止",
        @"user_start":@"请求开始拍摄并启用守护",@"user_pause":@"请求暂停自动恢复",
        @"user_end_session":@"请求结束本次拍摄",@"user_reconnect":@"请求重新连接",
        @"user_open_tether":@"请求打开官方 Tether",@"user_force_quit":@"明确请求强制退出 Tether",
        @"user_force_restart":@"明确请求强制重启 Tether",@"usb_attached":@"检测到相机 USB 接入",
        @"usb_detached":@"检测到相机 USB 断开",@"inspection_error":@"连接检查出现错误",
        @"inspection_recovered":@"连接检查已恢复",@"tether_observed":@"观察到 Tether 进程状态变化",
        @"process_observation_error":@"暂时无法确认 Tether 进程状态",@"process_observation_recovered":@"Tether 进程状态检查已恢复",
        @"helper_started":@"连接恢复步骤开始",@"helper_finished":@"连接恢复步骤结束",@"helper_error":@"连接恢复步骤出现错误",
        @"recovery_failed":@"本次连接恢复未成功",
        @"normal_quit_queued":@"已准备正常退出 Tether 的请求",@"normal_quit_delivered":@"已向 Tether 发送正常退出请求",
        @"normal_quit_exited":@"正常退出目标进程已结束或变化",@"normal_quit_timeout":@"Tether 正常退出等待超时",
        @"normal_quit_target_changed":@"正常退出目标身份已变化",@"normal_quit_cancelled":@"正常退出请求在发送前已取消",
        @"session_ended":@"本次拍摄已结束",@"launch_requested":@"守护器已提交 Tether 启动请求",
        @"launch_attempt_started":@"开始准备 Tether 启动请求",@"launch_skipped":@"未提交新的 Tether 启动请求",
        @"launch_returned":@"系统返回 Tether 启动请求结果",@"launch_cancelled":@"Tether 启动后续操作已取消",
        @"force_quit_delivered":@"已按明确选择向 Tether 发送强制退出请求",
        @"force_quit_refused":@"强制退出请求未通过身份核验",@"force_quit_cancelled":@"强制退出请求在发送前已取消"
    };
    return labels[event] ?: event;
}

@interface GuardianEventLog ()
@property(nonatomic,strong,readwrite) NSURL *fileURL;
@property(atomic,copy,readwrite,nullable) NSString *errorDescription;
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,copy) NSString *runID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic,strong) NSISO8601DateFormatter *utcFormatter;
@property(nonatomic,strong) NSISO8601DateFormatter *localFormatter;
@end

@implementation GuardianEventLog
- (instancetype)initWithDirectory:(NSURL *)directory {
    if((self=[super init])) {
        _directory=[directory copy]; _fileURL=[directory URLByAppendingPathComponent:@"events.jsonl"];
        _queue=dispatch_queue_create("local.s1h.connection-guardian.events",DISPATCH_QUEUE_SERIAL);
        _runID=NSUUID.UUID.UUIDString;
        _utcFormatter=[NSISO8601DateFormatter new];
        _utcFormatter.formatOptions=NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        _utcFormatter.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
        _localFormatter=[NSISO8601DateFormatter new]; _localFormatter.formatOptions=_utcFormatter.formatOptions;
        _localFormatter.timeZone=NSTimeZone.localTimeZone;
    }
    return self;
}
- (void)fail:(NSString *)reason code:(int)code {
    self.errorDescription=[NSString stringWithFormat:@"Event log %@ (errno %d).",reason,code];
}
- (int)openDirectory {
    if(!self.directory.isFileURL) { [self fail:@"invalid_directory" code:EINVAL]; return -1; }
    NSError *error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        [self fail:@"directory_unavailable" code:(int)error.code]; return -1;
    }
    int descriptor=open(self.directory.fileSystemRepresentation,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat attributes={0};
    if(descriptor<0) { [self fail:@"directory_open_failed" code:errno]; return -1; }
    if(fstat(descriptor,&attributes) || !S_ISDIR(attributes.st_mode) || attributes.st_uid!=geteuid() || fchmod(descriptor,0700)) {
        [self fail:@"directory_identity_failed" code:errno ?: EPERM]; close(descriptor); return -1;
    }
    return descriptor;
}
- (BOOL)validateName:(const char *)name inDirectory:(int)directory {
    struct stat attributes={0};
    if(fstatat(directory,name,&attributes,AT_SYMLINK_NOFOLLOW)) {
        if(errno==ENOENT) return YES;
        [self fail:@"file_inspection_failed" code:errno]; return NO;
    }
    if(!S_ISREG(attributes.st_mode) || attributes.st_uid!=geteuid() || attributes.st_nlink!=1) {
        [self fail:@"unsafe_file_refused" code:EPERM]; return NO;
    }
    return YES;
}
- (BOOL)rotateInDirectory:(int)directory {
    const char *names[]={"events.jsonl","events.jsonl.1","events.jsonl.2","events.jsonl.3"};
    for(unsigned i=0;i<4;++i) if(![self validateName:names[i] inDirectory:directory]) return NO;
    if(unlinkat(directory,names[3],0) && errno!=ENOENT) { [self fail:@"rotation_remove_failed" code:errno]; return NO; }
    for(int i=2;i>=0;--i) if(renameat(directory,names[i],directory,names[i+1]) && errno!=ENOENT) {
        [self fail:@"rotation_move_failed" code:errno]; return NO;
    }
    return YES;
}
- (void)append:(NSData *)data {
    int directory=[self openDirectory]; if(directory<0) return;
    if(![self validateName:"events.lock" inDirectory:directory]) { close(directory); return; }
    int lock=openat(directory,"events.lock",O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0600);
    if(lock<0) { [self fail:@"lock_open_failed" code:errno]; close(directory); return; }
    struct stat lockAttributes={0};
    if(fstat(lock,&lockAttributes) || !S_ISREG(lockAttributes.st_mode) || lockAttributes.st_uid!=geteuid() ||
        lockAttributes.st_nlink!=1 || fchmod(lock,0600) || flock(lock,LOCK_EX | LOCK_NB)) {
        [self fail:@"lock_unavailable" code:errno ?: EPERM]; close(lock); close(directory); return;
    }
    int file=-1;
    if(![self validateName:"events.jsonl" inDirectory:directory]) goto done;
    struct stat attributes={0};
    if(fstatat(directory,"events.jsonl",&attributes,AT_SYMLINK_NOFOLLOW)==0 &&
        (attributes.st_size<0 || (uint64_t)attributes.st_size+data.length>(uint64_t)GuardianEventLogLimit))
        if(![self rotateInDirectory:directory]) goto done;
    file=openat(directory,"events.jsonl",O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0600);
    if(file<0) { [self fail:@"file_open_failed" code:errno]; goto done; }
    if(fstat(file,&attributes) || !S_ISREG(attributes.st_mode) || attributes.st_uid!=geteuid() ||
        attributes.st_nlink!=1 || fchmod(file,0600)) { [self fail:@"unsafe_file_refused" code:errno ?: EPERM]; goto done; }
    NSUInteger offset=0;
    while(offset<data.length) {
        ssize_t wrote=write(file,(const char *)data.bytes+offset,data.length-offset);
        if(wrote<0 && errno==EINTR) continue;
        if(wrote<=0) { [self fail:@"write_failed" code:errno ?: EIO]; goto done; }
        offset+=(NSUInteger)wrote;
    }
    self.errorDescription=nil;
done:
    if(file>=0) close(file);
    flock(lock,LOCK_UN); close(lock); close(directory);
}
- (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields {
    if(!GuardianEventIdentifier(event,80,YES)) {
        dispatch_async(self.queue,^{ [self fail:@"invalid_event_refused" code:EINVAL]; });
        return;
    }
    NSString *name=[event copy]; NSDictionary *safe=GuardianEventFields(fields);
    NSDate *when=NSDate.date; double uptime=NSProcessInfo.processInfo.systemUptime;
    dispatch_async(self.queue,^{
        NSMutableDictionary *entry=[@{@"schema_version":@1,@"event":name,@"message_zh":GuardianEventLabel(name),
            @"time":[self.utcFormatter stringFromDate:when],@"local_time":[self.localFormatter stringFromDate:when],
            @"uptime_seconds":@(uptime),@"run_id":self.runID,@"sequence":@(++self.sequence),
            @"guardian_pid":@(getpid())} mutableCopy];
        [entry addEntriesFromDictionary:safe];
        NSData *json=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:NULL];
        if(!json || json.length+1>GuardianEventEntryLimit) { [self fail:@"entry_size_refused" code:EFBIG]; return; }
        NSMutableData *line=[json mutableCopy]; [line appendBytes:"\n" length:1]; [self append:line];
    });
}
- (void)flush {
    dispatch_sync(self.queue,^{
        int directory=open(self.directory.fileSystemRepresentation,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if(directory<0) return;
        if(![self validateName:"events.jsonl" inDirectory:directory]) { close(directory); return; }
        int file=openat(directory,"events.jsonl",O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if(file>=0) {
            struct stat attributes={0};
            if(fstat(file,&attributes)==0 && S_ISREG(attributes.st_mode) && attributes.st_uid==geteuid() && attributes.st_nlink==1)
                if(fsync(file)) [self fail:@"flush_failed" code:errno];
            close(file);
        } else if(errno!=ENOENT) [self fail:@"flush_open_failed" code:errno];
        close(directory);
    });
}
@end
