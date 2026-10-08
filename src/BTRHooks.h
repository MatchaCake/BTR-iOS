// BTR-iOS: NSURLSession hooks that rewrite play address responses inside the host app.
#import <Foundation/Foundation.h>
#import "BTRRewriter.h"

NS_ASSUME_NONNULL_BEGIN

/// Installs the NSURLSession hooks (idempotent).
FOUNDATION_EXPORT void BTRInstallHooks(void);
/// The mapper used by the hooks: the BTR proxy address, or nil when the stream is left alone.
FOUNDATION_EXPORT BTRURLMapper BTRDefaultMapper(void);
/// Rewrites one response body and records statistics. nil when unchanged.
FOUNDATION_EXPORT NSData *_Nullable BTRRewriteBody(NSData *data, NSURLResponse *_Nullable response, NSURL *_Nullable url);

/// Rewrites a decoded playurl protobuf message (no gRPC framing) and records statistics.
/// `label` names the source for the log (e.g. the protobuf class). nil when unchanged.
FOUNDATION_EXPORT NSData *_Nullable BTRRewriteProtobufReply(NSData *data, NSString *label);

/// Hooks below the network layer, independent of how the app talks to its servers:
/// - GPBMessage decoding of PlayViewUnite / PlayView / PlayURL replies (the official app fetches
///   these over gRPC-ObjC, which does not use NSURLSession);
/// - IJKPlayer DASH stream objects, as a fallback and as a diagnostic of what the player opens.
/// Idempotent; classes that are not loaded yet are retried once the app has launched.
FOUNDATION_EXPORT void BTRInstallModelHooks(void);
/// Whether a protobuf class name is a play address reply (PlayViewUniteReply, PlayViewReply, PlayURLReply).
FOUNDATION_EXPORT BOOL BTRIsPlayReplyClassName(const char *_Nullable name);
/// Handles a media address handed to the player: records it for diagnostics and, when `rewrite`
/// is YES and the address is not proxied yet, returns the BTR proxy address (same type as `value`,
/// NSString or NSURL). Otherwise returns `value`.
FOUNDATION_EXPORT id _Nullable BTRProcessPlayerURL(id _Nullable value, NSArray *_Nullable backups, NSString *where, BOOL rewrite);

NS_ASSUME_NONNULL_END
