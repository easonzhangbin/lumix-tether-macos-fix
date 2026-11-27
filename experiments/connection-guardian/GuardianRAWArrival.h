#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GuardianRAWArrivalResult : NSObject
@property(nonatomic, copy, readonly) NSString *relativePath;
@property(nonatomic, readonly) uint64_t fileSize;
- (instancetype)init NS_UNAVAILABLE;
@end

/* A read-only observer for the known DC-S1H 12000 × 8000 Pixel Shift RW2
 * layout. Scans the selected folder and its immediate YYYYMMDD folders for
 * case-insensitive .rw2 extensions. Does not follow symbolic links inside
 * the selected folder. Completion is structural, without decoding pixels.
 *
 * Initialize and poll on the same background queue. Initial file state is
 * the baseline. A nil poll result without an error means still waiting. */
@interface GuardianRAWArrival : NSObject
- (nullable instancetype)initWithDirectory:(NSURL *)directory
                                    error:(NSError *_Nullable *_Nullable)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable GuardianRAWArrivalResult *)checkForArrivalWithError:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
