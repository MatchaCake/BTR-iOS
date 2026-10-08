// BTR-iOS: rewrites playurl responses (JSON, raw protobuf and gRPC frames) so that the
// player's primary media address points at the in-process BTR proxy. Backup addresses are
// left untouched, so the player can still fall back to Bilibili's own CDN.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Return the replacement for `primary`, or nil to leave it alone.
typedef NSString *_Nullable (^BTRURLMapper)(NSString *primary, NSArray<NSString *> *backups);

@interface BTRRewriter : NSObject
/// Whether a request URL looks like a play address API (HTTP JSON or gRPC).
+ (BOOL)shouldInspectURL:(nullable NSURL *)url;
/// Rewrites a full response body. Returns nil when nothing changed or the body is not understood.
+ (nullable NSData *)rewriteResponseData:(NSData *)data
                             contentType:(nullable NSString *)contentType
                                  mapper:(BTRURLMapper)mapper
                                   count:(NSInteger *_Nullable)count;
+ (nullable NSData *)rewriteProtobuf:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *_Nullable)count;
+ (nullable NSData *)rewriteGRPC:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *_Nullable)count;
+ (nullable NSData *)rewriteJSON:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *_Nullable)count;
+ (nullable NSData *)gzipInflate:(NSData *)data;
+ (nullable NSData *)gzipDeflate:(NSData *)data;
@end

NS_ASSUME_NONNULL_END
