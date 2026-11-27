#import "GuardianDiagnosticCapture.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

NS_ASSUME_NONNULL_BEGIN

static const NSTimeInterval GuardianDiagnosticLogSeconds = 120;
static const NSUInteger GuardianDiagnosticToolLimit = 512 * 1024;
static const NSUInteger GuardianDiagnosticEventLimit = 128 * 1024;
static const NSUInteger GuardianDiagnosticCrashLimit = 1024 * 1024;

static double Uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

static BOOL MatchesProcessInfo(NSDictionary *identity, struct proc_bsdinfo info) {
    return [identity[@"pid"] isEqual:@(info.pbi_pid)] &&
           [identity[@"uid"] isEqual:@(info.pbi_uid)] &&
           [identity[@"real_uid"] isEqual:@(info.pbi_ruid)] &&
           [identity[@"start_seconds"] isEqual:@(info.pbi_start_tvsec)] &&
           [identity[@"start_microseconds"] isEqual:@(info.pbi_start_tvusec)];
}

static NSString * _Nullable CandidateExecutable(NSDictionary * _Nullable identity, BOOL service) {
    if (![identity isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"pid", @"uid", @"real_uid", @"start_seconds", @"start_microseconds"])
        if (![identity[key] isKindOfClass:NSNumber.class]) return nil;
    pid_t pid = [identity[@"pid"] intValue];
    if (pid <= 1 || ![identity[@"pid"] isEqual:@(pid)] ||
        ![identity[@"uid"] isEqual:@(geteuid())] || ![identity[@"real_uid"] isEqual:@(getuid())] ||
        ![identity[@"start_seconds"] unsignedLongLongValue] ||
        [identity[@"start_microseconds"] unsignedLongLongValue] >= 1000000) return nil;
    NSString *expectedPath = identity[@"path"] ?: identity[@"executable"];
    if (![expectedPath isKindOfClass:NSString.class] || !expectedPath.isAbsolutePath) return nil;
    if (service) {
        if (![expectedPath isEqual:@"/usr/libexec/ptpcamerad"]) return nil;
    } else {
        NSString *suffix = expectedPath.lowercaseString;
        if (![suffix hasSuffix:@".app/contents/macos/lumix tether"] &&
            ![suffix hasSuffix:@".app/contents/macos/lumixtether"]) return nil;
    }
    return expectedPath;
}

static NSString * _Nullable LiveExecutable(NSDictionary * _Nullable identity, BOOL service) {
    NSString *expectedPath = CandidateExecutable(identity, service);
    if (!expectedPath) return nil;
    pid_t pid = [identity[@"pid"] intValue];

    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info || !MatchesProcessInfo(identity, info) ||
        proc_pidpath(pid, path, sizeof path) <= 0) return nil;
    NSString *observed = [NSString stringWithUTF8String:path];
    if (![observed.stringByResolvingSymlinksInPath isEqual:expectedPath.stringByResolvingSymlinksInPath] ||
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info || !MatchesProcessInfo(identity, info)) return nil;
    return observed;
}

static NSTimeInterval IdentityStartTime(NSDictionary *identity) {
    return [identity[@"start_seconds"] doubleValue] + [identity[@"start_microseconds"] doubleValue] / 1000000;
}

static int OpenPrivateDirectoryAt(int parent, const char *name) {
    int descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) return -1;
    struct stat attributes = {0};
    if (fstat(descriptor, &attributes) || !S_ISDIR(attributes.st_mode) ||
        attributes.st_uid != geteuid() || (attributes.st_mode & 077)) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static BOOL SavePrivateArtifact(int directory, NSString *name, NSData *data) {
    int file = openat(directory, name.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) return NO;
    BOOL success = fchmod(file, 0600) == 0;
    NSUInteger offset = 0;
    while (success && offset < data.length) {
        ssize_t written = write(file, (const char *)data.bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            success = NO;
        } else {
            offset += (NSUInteger)written;
        }
    }
    if (close(file)) success = NO;
    if (!success) unlinkat(directory, name.fileSystemRepresentation, 0);
    return success;
}

static void ReapDiagnosticTool(pid_t child) {
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

/* Run only the fixed system programs below. The camera PIDs are arguments,
 * while timeout and output-limit handling can only signal the tool we spawned.
 * Reaping waits off the caller's queue if the OS has not finished the tool yet.
 */
static NSString *RunDiagnosticTool(NSString *tool, NSArray<NSString *> *arguments,
                                  NSDictionary *identity, BOOL service, NSTimeInterval seconds,
                                  NSData * _Nullable * _Nonnull output) {
    *output = nil;
    int descriptors[2];
    if (pipe(descriptors)) return @"pipe_unavailable";
    pid_t child = 0;
    NSString *problem = nil;
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) || fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) ||
        fcntl(descriptors[0], F_SETFL, O_NONBLOCK)) problem = @"pipe_unavailable";

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    BOOL actionsReady = posix_spawn_file_actions_init(&actions) == 0;
    BOOL attributesReady = posix_spawnattr_init(&attributes) == 0;
    if (!problem && (!actionsReady || !attributesReady ||
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT) ||
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) ||
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) ||
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))) problem = @"tool_launch_failed";
    if (!problem) {
        char *argv[arguments.count + 2];
        argv[0] = (char *)tool.fileSystemRepresentation;
        for (NSUInteger i = 0; i < arguments.count; ++i) argv[i + 1] = (char *)arguments[i].UTF8String;
        argv[arguments.count + 1] = NULL;
        char *const environment[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", "TZ=UTC", NULL};
        if (!LiveExecutable(identity, service)) {
            problem = @"identity_stale";
        } else if (posix_spawn(&child, argv[0], &actions, &attributes, argv, environment)) {
            problem = @"tool_launch_failed";
        }
    }
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    close(descriptors[1]);
    if (problem) {
        close(descriptors[0]);
        return problem;
    }

    NSMutableData *data = [NSMutableData data];
    double deadline = Uptime() + seconds;
    BOOL done = NO, endOfPipe = NO;
    int exitStatus = 0;
    while (!done || !endOfPipe) {
        if (Uptime() >= deadline) {
            problem = @"tool_timeout";
            break;
        }
        unsigned char chunk[8192];
        ssize_t count = endOfPipe ? 0 : read(descriptors[0], chunk, sizeof chunk);
        if (count > 0) {
            if ((NSUInteger)count > GuardianDiagnosticToolLimit - data.length) {
                problem = @"output_limit";
                break;
            }
            [data appendBytes:chunk length:(NSUInteger)count];
        } else if (count == 0) {
            endOfPipe = YES;
        } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            problem = @"tool_output_unavailable";
            break;
        }
        if (!done) {
            pid_t waited = waitpid(child, &exitStatus, WNOHANG);
            if (waited == child) done = YES;
            else if (waited < 0 && errno != EINTR) {
                done = YES;
                problem = @"tool_wait_failed";
                break;
            }
        }
        if (count <= 0 && (!done || !endOfPipe)) {
            struct pollfd watch = {.fd = descriptors[0], .events = POLLIN};
            (void)poll(endOfPipe ? NULL : &watch, endOfPipe ? 0 : 1, 25);
        }
    }
    close(descriptors[0]);
    if (!done) {
        /* Until waitpid reaps it, this remains our child PID even if the tool
         * exits between the timeout check and kill. */
        kill(child, SIGKILL);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ReapDiagnosticTool(child); });
    }
    if (!LiveExecutable(identity, service)) return @"identity_changed";
    if (problem) return problem;
    if (!WIFEXITED(exitStatus) || WEXITSTATUS(exitStatus) != 0) return @"tool_failed";
    *output = data;
    return @"captured";
}

static NSString *SaveSample(int directory, NSString *name, NSDictionary * _Nullable identity, BOOL service) {
    if (!LiveExecutable(identity, service)) return @"target_unverified_or_stale";
    NSData *data = nil;
    NSString *result = RunDiagnosticTool(@"/usr/bin/sample", @[[identity[@"pid"] stringValue], @"2", @"5", @"-file", @"/dev/stdout"],
                                         identity, service, 7, &data);
    if (![result isEqual:@"captured"]) return result;
    if (!data.length) return @"no_sample";
    return SavePrivateArtifact(directory, name, data) ? @"captured" : @"file_write_failed";
}

static NSString *SaveProcessLog(int directory, NSString *name, NSDictionary * _Nullable identity, BOOL service, NSDate *attemptTime) {
    NSString *path = LiveExecutable(identity, service);
    if (!path) return @"target_unverified_or_stale";
    NSTimeInterval first = ceil(MAX(IdentityStartTime(identity), attemptTime.timeIntervalSince1970 - GuardianDiagnosticLogSeconds));
    NSTimeInterval last = floor(NSDate.date.timeIntervalSince1970);
    if (first >= last) return @"no_log_window";
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ssZ";
    NSString *start = [format stringFromDate:[NSDate dateWithTimeIntervalSince1970:first]];
    NSString *end = [format stringFromDate:[NSDate dateWithTimeIntervalSince1970:last]];
    NSPredicate *filter = [NSPredicate predicateWithFormat:@"processID == %@ AND processImagePath == %@ AND "
                           "(messageType == error OR messageType == fault OR subsystem == %@)",
                           identity[@"pid"], path, @"com.apple.imagecapture"];
    NSData *data = nil;
    NSString *result = RunDiagnosticTool(@"/usr/bin/log", @[@"show", @"--start", start, @"--end", end,
                                         @"--style", @"compact", @"--timezone", @"UTC", @"--info", @"--debug", @"--predicate", filter.predicateFormat],
                                         identity, service, 5, &data);
    if (![result isEqual:@"captured"]) return result;
    const unsigned char *bytes = data.bytes;
    /* Compact output starts with a header even when no messages matched. */
    const unsigned char *headerEnd = data.length ? memchr(bytes, '\n', data.length) : NULL;
    if (!headerEnd || (NSUInteger)(headerEnd - bytes + 1) == data.length) return @"no_matching_entries";
    return SavePrivateArtifact(directory, name, data) ? @"captured" : @"file_write_failed";
}

static NSString *SaveGuardianEvents(int root, int directory, NSDate *attemptTime) {
    int file = openat(root, "events.jsonl", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (file < 0) return errno == ENOENT ? @"no_matching_entries" : @"events_unavailable";
    struct stat attributes = {0};
    if (fstat(file, &attributes) || !S_ISREG(attributes.st_mode) || attributes.st_uid != geteuid() ||
        attributes.st_nlink != 1 || (attributes.st_mode & 077) || attributes.st_size < 0) {
        close(file);
        return @"events_unavailable";
    }
    NSUInteger length = (NSUInteger)MIN(attributes.st_size, (off_t)GuardianDiagnosticEventLimit);
    off_t offset = attributes.st_size - (off_t)length;
    NSMutableData *tail = [NSMutableData dataWithLength:length];
    NSUInteger copied = 0;
    while (copied < length) {
        ssize_t count = pread(file, (unsigned char *)tail.mutableBytes + copied, length - copied, offset + (off_t)copied);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        copied += (NSUInteger)count;
    }
    close(file);
    if (copied != length) return @"events_read_failed";
    if (!length) return @"no_matching_entries";

    NSISO8601DateFormatter *format = [NSISO8601DateFormatter new];
    format.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *start = [attemptTime dateByAddingTimeInterval:-GuardianDiagnosticLogSeconds];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSMutableData *events = [NSMutableData data];
    const unsigned char *bytes = tail.bytes;
    NSUInteger lineStart = 0;
    if (offset) {
        const unsigned char *next = memchr(bytes, '\n', length);
        lineStart = next ? (NSUInteger)(next - bytes + 1) : length;
    }
    while (lineStart < length) {
        const unsigned char *next = memchr(bytes + lineStart, '\n', length - lineStart);
        if (!next) break;
        NSUInteger lineEnd = (NSUInteger)(next - bytes);
        if (lineEnd > lineStart && lineEnd - lineStart <= 8192) {
            NSData *line = [tail subdataWithRange:NSMakeRange(lineStart, lineEnd - lineStart)];
            id row = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            id stamp = [row isKindOfClass:NSDictionary.class] ? row[@"time"] : nil;
            NSDate *when = [stamp isKindOfClass:NSString.class] ? [format dateFromString:stamp] : nil;
            if (when && [when compare:start] != NSOrderedAscending && [when compare:attemptTime] != NSOrderedDescending) {
                [events appendData:line];
                [events appendData:newline];
            }
        }
        lineStart = lineEnd + 1;
    }
    if (!events.length) return @"no_matching_entries";
    return SavePrivateArtifact(directory, @"guardian-events.jsonl", events) ? @"captured" : @"file_write_failed";
}

static NSData * _Nullable ReadRecentCrash(int reports, const char *name, NSDate *attemptTime) {
    int file = openat(reports, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (file < 0) return nil;
    struct stat attributes = {0};
    NSMutableData *data = nil;
    if (fstat(file, &attributes) == 0 && S_ISREG(attributes.st_mode) && attributes.st_uid == geteuid() &&
        attributes.st_nlink == 1 && !(attributes.st_mode & 077) && attributes.st_size > 0 &&
        attributes.st_size <= (off_t)GuardianDiagnosticCrashLimit &&
        attributes.st_mtimespec.tv_sec >= attemptTime.timeIntervalSince1970 - GuardianDiagnosticLogSeconds) {
        data = [NSMutableData dataWithLength:(NSUInteger)attributes.st_size];
        NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t count = read(file, (unsigned char *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (NSUInteger)count;
        }
        if (offset != data.length) data = nil;
    }
    close(file);
    return data;
}

static BOOL CrashMatchesIdentity(NSData *data, NSDictionary *identity, NSString *path, NSDate *attemptTime) {
    const unsigned char *bytes = data.bytes;
    const unsigned char *firstNewline = data.length ? memchr(bytes, '\n', data.length) : NULL;
    if (!firstNewline) return NO;
    NSUInteger headerLength = (NSUInteger)(firstNewline - bytes);
    id header = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(0, headerLength)] options:0 error:NULL];
    if (![header isKindOfClass:NSDictionary.class] || ![header[@"bundleID"] isEqual:@"isb-152.LUMIXTether"]) return NO;
    NSUInteger bodyOffset = headerLength + 1;
    id crash = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(bodyOffset, data.length - bodyOffset)] options:0 error:NULL];
    if (![crash isKindOfClass:NSDictionary.class] || ![crash[@"pid"] isEqual:identity[@"pid"]] ||
        ![crash[@"userID"] isEqual:identity[@"uid"]] || ![crash[@"procPath"] isKindOfClass:NSString.class] ||
        ![crash[@"procLaunch"] isKindOfClass:NSString.class] || ![crash[@"captureTime"] isKindOfClass:NSString.class] ||
        ![[(NSString *)crash[@"procPath"] stringByResolvingSymlinksInPath] isEqual:path.stringByResolvingSymlinksInPath]) return NO;
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSS Z";
    NSDate *launch = [format dateFromString:crash[@"procLaunch"]];
    NSDate *capture = [format dateFromString:crash[@"captureTime"]];
    /* Crash reports round the launch time, while proc_bsdinfo has microseconds. */
    return launch && capture && fabs(launch.timeIntervalSince1970 - IdentityStartTime(identity)) < 0.002 &&
        [capture timeIntervalSinceDate:attemptTime] >= -GuardianDiagnosticLogSeconds &&
        [capture timeIntervalSinceNow] <= 0 && [capture compare:launch] != NSOrderedAscending;
}

static NSString *SaveMatchingCrash(int directory, NSDictionary * _Nullable identity, NSDate *attemptTime) {
    NSString *path = CandidateExecutable(identity, NO);
    if (!path || LiveExecutable(identity, NO)) return @"not_applicable";
    NSString *reportsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DiagnosticReports"];
    int reports = open(reportsPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (reports < 0) return errno == ENOENT ? @"no_matching_entries" : @"crash_reports_unavailable";
    DIR *entries = fdopendir(reports);
    if (!entries) {
        close(reports);
        return @"crash_reports_unavailable";
    }
    NSString *result = @"no_matching_entries";
    /* ReportCrash usually writes after the process has disappeared. Wait at
     * most three seconds for a report from the verified process instance. */
    for (NSUInteger pass = 0; pass < 4; ++pass) {
        if (pass > 0) {
            (void)poll(NULL, 0, 1000);
            rewinddir(entries);
        }
        NSUInteger scanned = 0;
        struct dirent *entry;
        while (scanned < 4096 && (entry = readdir(entries))) {
            ++scanned;
            NSString *name = [NSString stringWithUTF8String:entry->d_name].lowercaseString;
            if ((![name hasPrefix:@"lumix tether-"] && ![name hasPrefix:@"lumixtether-"]) || ![name hasSuffix:@".ips"]) continue;
            NSData *data = ReadRecentCrash(reports, entry->d_name, attemptTime);
            if (!data || !CrashMatchesIdentity(data, identity, path, attemptTime)) continue;
            result = SavePrivateArtifact(directory, @"tether-crash.ips", data) ? @"captured" : @"file_write_failed";
            break;
        }
        if (![result isEqual:@"no_matching_entries"]) break;
        if (scanned >= 4096) {
            result = @"crash_scan_limit";
            break;
        }
    }
    closedir(entries);
    return result;
}

NSDictionary<NSString *, id> *GuardianCaptureDiagnostics(NSURL *logRoot, NSDictionary * _Nullable verifiedTetherIdentity,
                                                         NSDictionary * _Nullable confirmedCameraServiceIdentity) {
    NSDate *attemptTime = NSDate.date;
    if (!logRoot.isFileURL) return @{@"status": @"failed", @"reason": @"invalid_log_root", @"results": @{}};
    int root = OpenPrivateDirectoryAt(AT_FDCWD, logRoot.fileSystemRepresentation);
    if (root < 0) return @{@"status": @"failed", @"reason": @"log_root_unavailable", @"results": @{}};
    const char *containerName = "diagnostics";
    if (mkdirat(root, containerName, 0700) && errno != EEXIST) {
        close(root);
        return @{@"status": @"failed", @"reason": @"diagnostics_directory_unavailable", @"results": @{}};
    }
    int container = OpenPrivateDirectoryAt(root, containerName);
    NSString *attempt = NSUUID.UUID.UUIDString;
    int directory = -1;
    if (container >= 0 && mkdirat(container, attempt.fileSystemRepresentation, 0700) == 0)
        directory = OpenPrivateDirectoryAt(container, attempt.fileSystemRepresentation);
    if (container >= 0) close(container);
    if (directory < 0) {
        close(root);
        return @{@"status": @"failed", @"reason": @"attempt_directory_unavailable", @"results": @{}};
    }

    NSMutableDictionary<NSString *, NSString *> *results = [NSMutableDictionary dictionary];
    results[@"tether.sample.txt"] = SaveSample(directory, @"tether.sample.txt", verifiedTetherIdentity, NO);
    results[@"camera-service.sample.txt"] = SaveSample(directory, @"camera-service.sample.txt", confirmedCameraServiceIdentity, YES);
    results[@"tether.log.txt"] = SaveProcessLog(directory, @"tether.log.txt", verifiedTetherIdentity, NO, attemptTime);
    results[@"camera-service.log.txt"] = SaveProcessLog(directory, @"camera-service.log.txt", confirmedCameraServiceIdentity, YES, attemptTime);
    results[@"guardian-events.jsonl"] = SaveGuardianEvents(root, directory, attemptTime);
    results[@"tether-crash.ips"] = SaveMatchingCrash(directory, verifiedTetherIdentity, attemptTime);
    close(root);

    NSString *status = @"complete";
    for (NSString *result in results.allValues) {
        if (![result isEqual:@"captured"] && ![result isEqual:@"no_matching_entries"] &&
            ![result isEqual:@"not_applicable"]) status = @"partial";
    }
    NSISO8601DateFormatter *format = [NSISO8601DateFormatter new];
    format.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDictionary *report = @{@"schema_version": @1, @"attempt": attempt, @"time": [format stringFromDate:attemptTime],
                             @"status": status, @"results": [results copy]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (!json || !SavePrivateArtifact(directory, @"report.json", json)) {
        results[@"report.json"] = @"file_write_failed";
        status = @"partial";
    }
    close(directory);
    NSURL *outputURL = [[logRoot URLByAppendingPathComponent:@"diagnostics" isDirectory:YES] URLByAppendingPathComponent:attempt isDirectory:YES];
    return @{@"status": status, @"directory": outputURL, @"results": [results copy]};
}

NS_ASSUME_NONNULL_END
