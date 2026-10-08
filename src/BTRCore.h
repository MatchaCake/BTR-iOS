// BTR-iOS: shared settings, logging, statistics and CDN candidate logic.
// The CDN host lists and candidate rules are ported from Bilibili-thread-ripper
// (src/cdn-resolver.js, src/range-core.js), MIT License, (c) 2026 Bilibili-thread-ripper contributors.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define BTR_VERSION @"0.1.0"

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

@interface BTRMedia : NSObject
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
