// BTR-iOS: shared settings, logging, statistics and CDN candidate logic.
// The CDN host lists and candidate rules are ported from Bilibili-thread-ripper
// (src/cdn-resolver.js, src/range-core.js), MIT License, (c) 2026 Bilibili-thread-ripper contributors.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define BTR_VERSION @"0.1.3"

typedef NS_ENUM(NSInteger, BTRCDNMode) {
    BTRCDNModeMainland = 0, // 大陆 CDN（BTR 默认）
    BTRCDNModeOverseas = 1, // 海外 CDN
    BTRCDNModeOriginal = 2, // 只用 B 站下发的原始地址，仅做多线程
    BTRCDNModeCustom = 3,   // 自定义节点；为空时按大陆 CDN
};

FOUNDATION_EXPORT NSString *BTRCDNModeName(BTRCDNMode mode);

@interface BTRSettings : NSObject
+ (instancetype)shared;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic) BOOL enabled;          // 默认 YES
@property (nonatomic) BOOL accelerateAudio;  // 默认 NO
@property (nonatomic) BOOL floatingButton;   // 默认 YES
@property (nonatomic) BTRCDNMode mode;       // 默认大陆
@property (nonatomic) NSInteger threads;     // 4/8/16/32/64，默认 8
@property (nonatomic) NSInteger chunkKB;     // 256..4096，默认 1024
@property (nonatomic, copy) NSArray<NSString *> *customHosts;
@property (nonatomic) double buttonX;        // 0..1，<0 表示未设置
@property (nonatomic) double buttonY;
@end

FOUNDATION_EXPORT void BTRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *BTRLogDump(void);
FOUNDATION_EXPORT void BTRLogClear(void);

@interface BTRStats : NSObject
+ (instancetype)shared;
- (void)add:(NSString *)key value:(int64_t)value;
- (void)setMax:(NSString *)key value:(int64_t)value;
- (void)set:(NSString *)key value:(int64_t)value;
- (int64_t)get:(NSString *)key;
- (void)reset;
@end

/// On-device diagnostics: which requests / protobuf replies / player addresses the tweak saw.
/// Only host + path are kept (never query strings, cookies or bodies).
@interface BTRDiag : NSObject
/// Records one observation under `kind`; repeated items are counted instead of duplicated.
+ (void)note:(NSString *)kind item:(NSString *)item;
/// Records a URL as "host/path" (query dropped).
+ (void)noteURL:(nullable NSURL *)url kind:(NSString *)kind;
/// Text report of the most recent observations of every kind.
+ (NSString *)dump;
+ (void)reset;
@end

/// Result of one "更新节点列表" attempt.
@interface BTRNodeUpdateResult : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic) NSInteger added;    // hosts new to a list (mainland + overseas)
@property (nonatomic) NSInteger removed;  // hosts dropped from a list
@property (nonatomic, copy) NSString *message; // Chinese, shown to the user
@end

/// The mainland / overseas CDN node lists. Sources, in order: our signed list (MatchaCake/
/// btr-cdn-list, probed daily; ECDSA P-256 signature checked with the embedded public key, must
/// not be expired nor older than a version already used) → upstream BTR's src/cdn-resolver.js
/// (GitHub, then jsDelivr mirrors) → the last good lists kept on disk → the built-in lists.
@interface BTRNodeList : NSObject
+ (instancetype)shared;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (class, readonly) NSArray<NSString *> *builtinMainland;
@property (class, readonly) NSArray<NSString *> *builtinOverseas;
/// Upstream file on raw.githubusercontent.com first, then jsDelivr mirrors.
@property (class, readonly) NSArray<NSURL *> *sourceURLs;
/// Our signed list.
@property (class, readonly) NSURL *signedListURL;
/// X9.63 public key (65 bytes) the signed list must verify against; the embedded one by default.
@property (copy) NSData *signedListKey;
@property (readonly) NSArray<NSString *> *mainland;
@property (readonly) NSArray<NSString *> *overseas;
@property (readonly) BOOL isBuiltin;
@property (readonly, nullable) NSDate *updatedAt;
@property (readonly, nullable) NSString *sourceHost;
/// Version of the signed list in use (0 for upstream / built-in lists).
@property (readonly) int64_t version;
/// Highest signed version ever applied; never decreases (not even on restoreBuiltin).
@property (readonly) int64_t maxSignedVersion;
/// Only Bilibili's own node names: upos-*.bilivideo.com, cn-*.bilivideo.com, upos-*.akamaized.net.
/// Never *.bilivideo.cn (<IP>.mcdn.bilivideo.cn names can point at third-party machines).
+ (BOOL)isAllowedNodeHost:(NSString *)host;
/// Extracts MAINLAND_HOSTS / OVERSEAS_HOSTS from upstream cdn-resolver.js. Returns
/// @{ @"mainland": …, @"overseas": … } or nil with a reason. Every entry must pass
/// isAllowedNodeHost, each list must have 1…32 entries.
+ (nullable NSDictionary<NSString *, NSArray<NSString *> *> *)parseUpstreamSource:(NSString *)text error:(NSString *_Nullable *_Nullable)error;
/// Verifies and parses our signed list. Returns @{ mainland, overseas (= overseas + hk groups),
/// version (NSNumber), expiresAt (NSDate) } or nil with a reason.
+ (nullable NSDictionary *)parseSignedList:(NSData *)data now:(NSDate *)now minVersion:(int64_t)minVersion
                                       key:(NSData *)x963Key error:(NSString *_Nullable *_Nullable)error;
/// Validates, persists and applies new lists (takes effect for the next segment request).
- (BTRNodeUpdateResult *)applyMainland:(NSArray<NSString *> *)mainland overseas:(NSArray<NSString *> *)overseas source:(nullable NSString *)sourceHost;
- (BTRNodeUpdateResult *)applyMainland:(NSArray<NSString *> *)mainland overseas:(NSArray<NSString *> *)overseas source:(nullable NSString *)sourceHost
                               version:(int64_t)version expiresAt:(nullable NSDate *)expiresAt;
- (void)restoreBuiltin;
/// Tries upstream `urls` in order; completion runs on the main queue.
- (void)updateFromURLs:(NSArray<NSURL *> *)urls completion:(void (^)(BTRNodeUpdateResult *result))completion;
/// Tries the signed list (if any), then upstream `urls` in order; completion runs on the main queue.
- (void)updateFromSignedURL:(nullable NSURL *)signedURL upstreamURLs:(NSArray<NSURL *> *)urls
                 completion:(void (^)(BTRNodeUpdateResult *result))completion;
/// "更新节点列表": signed list, then upstream.
- (void)updateWithCompletion:(void (^)(BTRNodeUpdateResult *result))completion;
/// At most once a day, quietly fetch only the signed list in the background; failures keep the
/// current lists.
- (void)refreshSignedIfStale;
/// "内置 · 大陆 8 / 海外 4" or "10-09 09:30 更新 · 大陆 8 / 海外 4".
- (NSString *)summary;
@end

@interface BTRMedia : NSObject
/// Current lists (BTRNodeList.shared): the updated ones if any, else the built-in ones.
@property (class, readonly) NSArray<NSString *> *mainlandHosts;
@property (class, readonly) NSArray<NSString *> *overseasHosts;
+ (BOOL)isMediaURL:(nullable NSString *)url;
+ (BOOL)isAudioURL:(NSString *)url;
+ (BOOL)isLiveURL:(NSString *)url;
+ (BOOL)isAkamaiURL:(NSString *)url;
+ (nullable NSString *)hostOf:(NSString *)url;
+ (nullable NSString *)normalizeHost:(nullable NSString *)value;
+ (nullable NSString *)swapHost:(NSString *)url to:(NSString *)host allowAkamai:(BOOL)allowAkamai;
/// BTR representationUrls(): the URLs a piece may be fetched from, in preference order.
+ (NSArray<NSString *> *)candidatesForPrimary:(NSString *)primary
                                      backups:(NSArray<NSString *> *)backups
                                         mode:(BTRCDNMode)mode
                                       custom:(NSArray<NSString *> *)custom;
+ (NSString *)formatBytes:(int64_t)bytes;
@end

NS_ASSUME_NONNULL_END
