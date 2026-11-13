#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Local metadata only. recordEvent never performs file I/O on the caller's
 * queue. Unknown fields, free text and paths are discarded. flush is a
 * synchronous barrier for tests and final shutdown after camera work settles. */
@interface GuardianEventLog : NSObject
@property(nonatomic, readonly) NSURL *fileURL;
@property(atomic, readonly, nullable) NSString *errorDescription;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields;
- (void)flush;
@end
NS_ASSUME_NONNULL_END
