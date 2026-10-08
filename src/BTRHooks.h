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

NS_ASSUME_NONNULL_END
