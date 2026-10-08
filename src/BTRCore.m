#import "BTRCore.h"

NSString *BTRCDNModeName(BTRCDNMode mode) {
    switch (mode) {
        case BTRCDNModeMainland: return @"大陆 CDN";
        case BTRCDNModeOverseas: return @"海外 CDN";
        case BTRCDNModeOriginal: return @"原始地址";
        case BTRCDNModeCustom: return @"自定义";
    }
    return @"大陆 CDN";
}

#pragma mark - Settings

static NSString *const kPrefix = @"BTRiOS.";

@implementation BTRSettings {
    NSUserDefaults *_d;
}

+ (instancetype)shared {
    static BTRSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[BTRSettings alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
    return s;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _d = defaults;
    return self;
}

- (id)obj:(NSString *)k { return [_d objectForKey:[kPrefix stringByAppendingString:k]]; }
- (void)setObj:(id)v key:(NSString *)k { [_d setObject:v forKey:[kPrefix stringByAppendingString:k]]; }
- (BOOL)boolFor:(NSString *)k def:(BOOL)def { id v = [self obj:k]; return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def; }

- (BOOL)enabled { return [self boolFor:@"enabled" def:YES]; }
- (void)setEnabled:(BOOL)v { [self setObj:@(v) key:@"enabled"]; }
- (BOOL)accelerateAudio { return [self boolFor:@"audio" def:NO]; }
- (void)setAccelerateAudio:(BOOL)v { [self setObj:@(v) key:@"audio"]; }
- (BOOL)floatingButton { return [self boolFor:@"button" def:YES]; }
- (void)setFloatingButton:(BOOL)v { [self setObj:@(v) key:@"button"]; }

- (BTRCDNMode)mode {
    NSInteger m = [[self obj:@"mode"] integerValue];
    return (m >= BTRCDNModeMainland && m <= BTRCDNModeCustom) ? (BTRCDNMode)m : BTRCDNModeMainland;
}
- (void)setMode:(BTRCDNMode)v { [self setObj:@(v) key:@"mode"]; }

- (NSInteger)threads {
    NSInteger t = [[self obj:@"threads"] integerValue];
    return (t == 4 || t == 8 || t == 16 || t == 32 || t == 64) ? t : 8;
}
- (void)setThreads:(NSInteger)v { [self setObj:@(v) key:@"threads"]; }

- (NSInteger)chunkKB {
    NSInteger c = [[self obj:@"chunk"] integerValue];
    return (c == 256 || c == 512 || c == 1024 || c == 2048 || c == 4096) ? c : 1024;
}
- (void)setChunkKB:(NSInteger)v { [self setObj:@(v) key:@"chunk"]; }

- (NSArray<NSString *> *)customHosts {
    NSArray *raw = [self obj:@"custom"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id h in raw) {
        NSString *n = [h isKindOfClass:NSString.class] ? [BTRMedia normalizeHost:h] : nil;
        if (n && ![out containsObject:n] && out.count < 32) [out addObject:n];
    }
    return out;
}
- (void)setCustomHosts:(NSArray<NSString *> *)v { [self setObj:v ?: @[] key:@"custom"]; }

- (double)buttonX { id v = [self obj:@"bx"]; return v ? [v doubleValue] : -1; }
- (void)setButtonX:(double)v { [self setObj:@(v) key:@"bx"]; }
- (double)buttonY { id v = [self obj:@"by"]; return v ? [v doubleValue] : -1; }
- (void)setButtonY:(double)v { [self setObj:@(v) key:@"by"]; }
@end

#pragma mark - Log

static NSMutableArray<NSString *> *gLog;
static NSLock *gLogLock;

void BTRLog(NSString *format, ...) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLog = [NSMutableArray array]; gLogLock = [NSLock new]; });
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[BTR] %@", msg);
    static NSDateFormatter *fmt;
    [gLogLock lock];
    if (!fmt) { fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss.SSS"; }
    [gLog addObject:[NSString stringWithFormat:@"%@ %@", [fmt stringFromDate:NSDate.date], msg]];
    if (gLog.count > 600) [gLog removeObjectsInRange:NSMakeRange(0, gLog.count - 500)];
    [gLogLock unlock];
}

NSString *BTRLogDump(void) {
    BTRLog(@"导出日志");
    [gLogLock lock];
    NSString *s = [gLog componentsJoinedByString:@"\n"];
    [gLogLock unlock];
    return s;
}

void BTRLogClear(void) {
    [gLogLock lock];
    [gLog removeAllObjects];
    [gLogLock unlock];
}

#pragma mark - Stats

@implementation BTRStats {
    NSMutableDictionary<NSString *, NSNumber *> *_v;
    NSLock *_lock;
}
+ (instancetype)shared {
    static BTRStats *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BTRStats new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) { _v = [NSMutableDictionary dictionary]; _lock = [NSLock new]; }
    return self;
}
- (void)add:(NSString *)key value:(int64_t)value {
    [_lock lock]; _v[key] = @(_v[key].longLongValue + value); [_lock unlock];
}
- (void)setMax:(NSString *)key value:(int64_t)value {
    [_lock lock]; if (value > _v[key].longLongValue) _v[key] = @(value); [_lock unlock];
}
- (void)set:(NSString *)key value:(int64_t)value {
    [_lock lock]; _v[key] = @(value); [_lock unlock];
}
- (int64_t)get:(NSString *)key {
    [_lock lock]; int64_t r = _v[key].longLongValue; [_lock unlock]; return r;
}
- (void)reset {
    [_lock lock]; int64_t active = _v[@"activeThreads"].longLongValue; [_v removeAllObjects]; _v[@"activeThreads"] = @(active); [_lock unlock];
}
@end

#pragma mark - Media / CDN

@implementation BTRMedia

+ (NSArray<NSString *> *)mainlandHosts {
    return @[ @"upos-sz-mirrorali.bilivideo.com", @"upos-sz-mirrorhw.bilivideo.com", @"upos-sz-mirrorbos.bilivideo.com",
              @"upos-sz-mirror08c.bilivideo.com", @"upos-sz-mirrorbd.bilivideo.com", @"upos-sz-mirror14b.bilivideo.com",
              @"upos-sz-estgoss.bilivideo.com", @"upos-sz-mirrorcos.bilivideo.com" ];
}

+ (NSArray<NSString *> *)overseasHosts {
    return @[ @"upos-sz-mirrorcosov.bilivideo.com", @"upos-sz-mirroraliov.bilivideo.com",
              @"cn-hk-eq-01-01.bilivideo.com", @"cn-hk-eq-01-03.bilivideo.com" ];
}

static NSRegularExpression *MediaHostRE(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?:^|\\.)(?:bilivideo\\.(?:com|cn|net)|akamaized\\.net|szbdyd\\.com|hdslb\\.com|xycdn\\.com|mountaintoys\\.cn|nexusedgeio\\.com|ahdohpiechei\\.com)$"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return re;
}

static BOOL MatchesHost(NSString *host) {
#ifdef BTR_TESTING
    // Host tests serve media from loopback servers.
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) return YES;
#endif
    return host.length && [MediaHostRE() firstMatchInString:host options:0 range:NSMakeRange(0, host.length)] != nil;
}

+ (BOOL)isMediaURL:(NSString *)url {
    if (![url isKindOfClass:NSString.class] || url.length < 12 || url.length > 4096) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    if (!c) return NO;
    NSString *scheme = c.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return NO;
    NSString *path = c.percentEncodedPath.lowercaseString;
    if (!([path hasSuffix:@".m4s"] || [path hasSuffix:@".mp4"] || [path hasSuffix:@".flv"])) return NO;
    return MatchesHost(c.host.lowercaseString);
}

+ (BOOL)isAudioURL:(NSString *)url {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 30216/30232/30280 普通音轨，30250 杜比，30251 Hi-Res
        re = [NSRegularExpression regularExpressionWithPattern:@"-302(?:16|32|80|50|51|5\\d)\\.m4s" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSString *path = [NSURLComponents componentsWithString:url].percentEncodedPath ?: @"";
    return [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil;
}

+ (BOOL)isLiveURL:(NSString *)url {
    return [url rangeOfString:@"/live-bvc/"].location != NSNotFound || [url rangeOfString:@"live-bvc"].location != NSNotFound;
}

+ (NSString *)hostOf:(NSString *)url {
    return [NSURLComponents componentsWithString:url].host.lowercaseString;
}

+ (BOOL)isAkamaiURL:(NSString *)url {
    return [[self hostOf:url] hasSuffix:@".akamaized.net"];
}

+ (NSString *)normalizeHost:(NSString *)value {
    NSString *text = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!text.length || text.length > 253) return nil;
    if ([text rangeOfString:@"://"].location == NSNotFound) text = [@"https://" stringByAppendingString:text];
    NSString *host = [NSURLComponents componentsWithString:text].host.lowercaseString;
    if (!host.length) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[a-z\\d](?:[a-z\\d-]*[a-z\\d])?(?:\\.[a-z\\d](?:[a-z\\d-]*[a-z\\d])?)+$" options:0 error:nil];
    });
    if (![re firstMatchInString:host options:0 range:NSMakeRange(0, host.length)]) return nil;
    return MatchesHost(host) ? host : nil;
}

+ (NSString *)swapHost:(NSString *)url to:(NSString *)host allowAkamai:(BOOL)allowAkamai {
    if (!allowAkamai && [self isAkamaiURL:url]) return nil;
    NSString *h = host.lowercaseString;
    if (![[self normalizeHost:h] isEqualToString:h]) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    if (!c) return nil;
    c.scheme = @"https";
    c.host = h;
    c.port = nil; // 去掉 PCDN 的 :4483 之类端口
    return c.string;
}

static void AddUnique(NSMutableArray *list, NSString *value) {
    if (value && ![list containsObject:value]) [list addObject:value];
}

+ (NSArray<NSString *> *)candidatesForPrimary:(NSString *)primary backups:(NSArray<NSString *> *)backups mode:(BTRCDNMode)mode custom:(NSArray<NSString *> *)customHosts {
    NSMutableArray<NSString *> *originals = [NSMutableArray array];
    for (NSString *u in [@[ primary ?: @"" ] arrayByAddingObjectsFromArray:backups ?: @[]])
        if ([self isMediaURL:u]) AddUnique(originals, u);
    if (mode == BTRCDNModeOriginal || !originals.count) return originals;

    NSMutableArray<NSString *> *custom = [NSMutableArray array];
    if (mode == BTRCDNModeCustom) for (NSString *h in customHosts) AddUnique(custom, [self normalizeHost:h]);
    NSArray<NSString *> *hosts = custom.count ? custom : (mode == BTRCDNModeOverseas ? self.overseasHosts : self.mainlandHosts);

    NSString *donor = nil;
    for (NSString *u in originals) if (![self isAkamaiURL:u]) { donor = u; break; }

    // 和 BTR 一样：有非 akamaized.net 的地址时用它做模板换节点；只有 akamai 地址时才拿 akamai 地址做模板。
    NSMutableArray<NSString *> *synthetic = [NSMutableArray array];
    for (NSString *h in hosts) {
        if (donor) {
            NSString *s = [self swapHost:donor to:h allowAkamai:NO];
            if ([self isMediaURL:s]) AddUnique(synthetic, s);
        } else {
            for (NSString *u in originals) {
                NSString *s = [self swapHost:u to:h allowAkamai:YES];
                if ([self isMediaURL:s]) AddUnique(synthetic, s);
            }
        }
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray *mainland = self.mainlandHosts;
    for (NSString *u in originals) {
        NSString *h = [self hostOf:u];
        BOOL allowed = custom.count ? [custom containsObject:h]
                     : mode == BTRCDNModeOverseas ? ![mainland containsObject:h]
                     : [mainland containsObject:h];
        if (allowed) AddUnique(out, u);
    }
    for (NSString *s in synthetic) AddUnique(out, s);
    return out.count ? out : originals;
}

+ (NSString *)formatBytes:(int64_t)bytes {
    double b = (double)bytes;
    if (b < 1024) return [NSString stringWithFormat:@"%lld B", bytes];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KiB", b / 1024];
    if (b < 1024.0 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MiB", b / 1048576];
    return [NSString stringWithFormat:@"%.2f GiB", b / 1073741824];
}

@end
