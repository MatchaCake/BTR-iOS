// BTR-iOS: in-process loopback HTTP proxy. The player asks it for a byte range of a media
// file; the proxy splits the range into pieces, fetches them in parallel from several CDN
// nodes (the BTR idea), checks each piece's position and length, and streams them back to
// the player in order.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BTRProxyServer : NSObject
+ (instancetype)shared;
/// Starts listening on 127.0.0.1 (idempotent). Returns NO when no port could be bound.
- (BOOL)start;
@property (nonatomic, readonly) uint16_t port;
/// The loopback URL that makes the player go through the proxy for `primary`.
- (nullable NSString *)proxyURLForPrimary:(NSString *)primary backups:(NSArray<NSString *> *)backups;
/// Decodes a proxy URL back into its primary and backup addresses (used by tests).
+ (nullable NSArray<NSString *> *)addressesFromProxyPath:(NSString *)pathAndQuery;
/// Per-node state for the status page: host, state, bps, bytes.
- (NSArray<NSDictionary *> *)hostStatus;
/// A new video: forget banned nodes (BTR resets its ban list per video).
- (void)resetBans;
@end

NS_ASSUME_NONNULL_END
