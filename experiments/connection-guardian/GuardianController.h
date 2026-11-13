#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* All operations are asynchronous. Updates and stop completion run on main.
 * Resource directory contains s1h_iousbhost_probe and s1h_camera_service.
 * Snapshot keys: state, message_zh, message_en, desired_running,
 * device_present, tether_running, can_force_restart, can_force_quit,
 * ending_session, session_ended, tether_observation_valid,
 * inspection_observation_valid, capture_state, shooting_verified, busy, retry_count,
 * log_directory; inspection contains the last read-only service snapshot.
 * start is explicit opt-in to bounded service recovery while Tether is absent.
 * pause/stopTool leave Tether alone. Reconnect first requests normal quit.
 * endSession first disables recovery, waits for this tool's bounded work,
 * then requests a verified normal Tether quit and remains passive. Timeout
 * needs separate forceQuit consent. No automatic force or session relaunch.
 * capture_state never certifies shooting readiness; running Tether is unknown.
 */
@interface GuardianController : NSObject
- (instancetype)initWithResourceDirectory:(NSURL *)directory
                                 onUpdate:(void (^)(NSDictionary *snapshot))onUpdate;
- (void)start;
- (void)pause;
- (void)reconnect;
- (void)endSession;
- (void)forceRestart;
- (void)forceQuit;
- (void)openTether;
- (void)stopTool;
- (void)stopToolWithCompletion:(dispatch_block_t)completion;
@end
NS_ASSUME_NONNULL_END
