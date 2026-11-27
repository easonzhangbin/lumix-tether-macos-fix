#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Capture local evidence on a worker queue. The caller supplies a freshly verified
 * Panasonic process identity and the confirmed current S1H system-service owner.
 * Identities contain pid, uid, real_uid, start_seconds, start_microseconds and
 * path (or executable for the inspector's owner_process). Either may be absent.
 * Returns status (complete, partial or failed), artifact results and, when an
 * attempt directory was created, its URL in directory. No camera commands are sent.
 */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GuardianCaptureDiagnostics(
    NSURL *logRoot, NSDictionary * _Nullable verifiedTetherIdentity,
    NSDictionary * _Nullable confirmedCameraServiceIdentity);

NS_ASSUME_NONNULL_END
