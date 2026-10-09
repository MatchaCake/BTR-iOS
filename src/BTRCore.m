#import "BTRCore.h"
#import <Security/Security.h>

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
        if (n && [BTRNodeList isAllowedNodeHost:n] && ![out containsObject:n] && out.count < 32) [out addObject:n];
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

#pragma mark - Diagnostics

static NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *gDiag;
static NSMutableArray<NSString *> *gDiagKinds;
static NSLock *gDiagLock;
static const NSUInteger kDiagPerKind = 40;

@implementation BTRDiag
+ (void)setup {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gDiag = [NSMutableDictionary dictionary]; gDiagKinds = [NSMutableArray array]; gDiagLock = [NSLock new]; });
}
+ (void)note:(NSString *)kind item:(NSString *)item {
    if (!kind.length || !item.length) return;
    [self setup];
    if (item.length > 160) item = [[item substringToIndex:160] stringByAppendingString:@"…"];
    [gDiagLock lock];
    NSMutableArray *list = gDiag[kind];
    if (!list) { list = gDiag[kind] = [NSMutableArray array]; [gDiagKinds addObject:kind]; }
    NSMutableDictionary *hit = nil;
    for (NSMutableDictionary *e in list) if ([e[@"item"] isEqualToString:item]) { hit = e; break; }
    if (hit) {
        hit[@"count"] = @([hit[@"count"] longLongValue] + 1);
        [list removeObject:hit];
    } else {
        hit = [@{ @"item": item, @"count": @1 } mutableCopy];
    }
    hit[@"time"] = NSDate.date;
    [list addObject:hit]; // most recent last
    if (list.count > kDiagPerKind) [list removeObjectsInRange:NSMakeRange(0, list.count - kDiagPerKind)];
    [gDiagLock unlock];
}
+ (void)noteURL:(NSURL *)url kind:(NSString *)kind {
    if (!url) return;
    NSString *host = url.host ?: @"?";
    if (url.port) host = [host stringByAppendingFormat:@":%@", url.port];
    [self note:kind item:[host stringByAppendingString:url.path.length ? url.path : @"/"]];
}
+ (NSString *)dump {
    [self setup];
    static NSDateFormatter *fmt;
    NSMutableString *s = [NSMutableString string];
    [gDiagLock lock];
    if (!fmt) { fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss"; }
    for (NSString *kind in gDiagKinds) {
        NSArray *list = gDiag[kind];
        [s appendFormat:@"== %@（最近 %lu 项，新的在前）==\n", kind, (unsigned long)list.count];
        for (NSDictionary *e in list.reverseObjectEnumerator)
            [s appendFormat:@"%@ ×%@ %@\n", [fmt stringFromDate:e[@"time"]], e[@"count"], e[@"item"]];
        [s appendString:@"\n"];
    }
    [gDiagLock unlock];
    return s.length ? s : @"还没有观察到任何请求。打开一个视频播放几秒后再来看。\n";
}
+ (void)reset {
    [self setup];
    [gDiagLock lock];
    [gDiag removeAllObjects];
    [gDiagKinds removeAllObjects];
    [gDiagLock unlock];
}
@end

#pragma mark - Media / CDN

@implementation BTRMedia

+ (NSArray<NSString *> *)mainlandHosts { return BTRNodeList.shared.mainland; }
+ (NSArray<NSString *> *)overseasHosts { return BTRNodeList.shared.overseas; }

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
    // Signed addresses only ever go to Bilibili's own named nodes (no *.bilivideo.cn / mcdn).
    if (![[self normalizeHost:h] isEqualToString:h] || ![BTRNodeList isAllowedNodeHost:h]) return nil;
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
    if (mode == BTRCDNModeCustom)
        for (NSString *h in customHosts) {
            NSString *n = [self normalizeHost:h];
            if (n && [BTRNodeList isAllowedNodeHost:n]) AddUnique(custom, n);
        }
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

#pragma mark - Node list update

@implementation BTRNodeUpdateResult
@end

static NSString *const kNodesKey = @"BTRiOS.nodes";
static NSString *const kMaxSignedVersionKey = @"BTRiOS.nodes.maxSignedVersion";
static NSString *const kLastAutoRefreshKey = @"BTRiOS.nodes.lastAutoRefresh";
static const NSUInteger kMaxNodesPerList = 32;
static const NSUInteger kMaxSourceBytes = 512 * 1024;
static const NSUInteger kMaxSignedBytes = 64 * 1024;
static NSString *const kSignedLabel = @"签名列表";
// ECDSA P-256 public key of MatchaCake/btr-cdn-list (X9.63 uncompressed point).
static NSString *const kSignedListKeyB64 = @"BI8Hu7gO0/M8LWSbdL9Bpyl/k+9MYijJsHJ3JHciSZcueerxh0KnzY0b0M6A/1woozzMsWasQJG8F+6N7KFUoiQ=";

@implementation BTRNodeList {
    NSUserDefaults *_d;
    NSArray<NSString *> *_mainland, *_overseas;
    NSDate *_updatedAt;
    NSString *_source;
    int64_t _version;
    NSData *_signedListKey;
}

+ (instancetype)shared {
    static BTRNodeList *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[BTRNodeList alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
    return s;
}

/// Upstream BTR's nodes plus the ones verified working on 2026-10-09 (probed from Singapore and
/// GitHub Actions with a real signed address; see btr-cdn-list).
+ (NSArray<NSString *> *)builtinMainland {
    return @[ @"upos-sz-mirrorali.bilivideo.com", @"upos-sz-mirrorhw.bilivideo.com", @"upos-sz-mirrorbos.bilivideo.com",
              @"upos-sz-mirror08c.bilivideo.com", @"upos-sz-mirrorbd.bilivideo.com", @"upos-sz-mirror14b.bilivideo.com",
              @"upos-sz-estgoss.bilivideo.com", @"upos-sz-mirrorcos.bilivideo.com", @"upos-sz-mirroralib.bilivideo.com",
              @"upos-sz-mirrorhwb.bilivideo.com", @"upos-sz-mirrorhwo1.bilivideo.com", @"upos-sz-mirrorhwdisp.bilivideo.com",
              @"upos-sz-mirror08h.bilivideo.com", @"upos-sz-mirror08ct.bilivideo.com", @"upos-sz-mirrorcosb.bilivideo.com",
              @"upos-sz-mirrorcoso1.bilivideo.com", @"upos-sz-estghw.bilivideo.com", @"upos-sz-estgcos.bilivideo.com",
              @"upos-sz-upcdnbda2.bilivideo.com", @"upos-tf-all-hw.bilivideo.com", @"upos-tf-all-tx.bilivideo.com",
              @"upos-tf-all-ali.bilivideo.com" ];
}

/// The *ov nodes, then Hong Kong (cn-hk-eq-01-07 does not resolve).
+ (NSArray<NSString *> *)builtinOverseas {
    return @[ @"upos-sz-mirrorcosov.bilivideo.com", @"upos-sz-mirroraliov.bilivideo.com", @"cn-hk-eq-01-01.bilivideo.com",
              @"cn-hk-eq-01-02.bilivideo.com", @"cn-hk-eq-01-03.bilivideo.com", @"cn-hk-eq-01-04.bilivideo.com",
              @"cn-hk-eq-01-05.bilivideo.com", @"cn-hk-eq-01-06.bilivideo.com", @"cn-hk-eq-01-08.bilivideo.com",
              @"cn-hk-eq-01-09.bilivideo.com", @"cn-hk-eq-01-10.bilivideo.com", @"cn-hk-eq-01-11.bilivideo.com",
              @"cn-hk-eq-01-12.bilivideo.com", @"cn-hk-eq-01-13.bilivideo.com", @"cn-hk-eq-01-14.bilivideo.com" ];
}

+ (NSArray<NSURL *> *)sourceURLs {
    return @[ [NSURL URLWithString:@"https://raw.githubusercontent.com/MrTangLuyao/Bilibili-thread-ripper/main/src/cdn-resolver.js"],
              [NSURL URLWithString:@"https://fastly.jsdelivr.net/gh/MrTangLuyao/Bilibili-thread-ripper@main/src/cdn-resolver.js"],
              [NSURL URLWithString:@"https://cdn.jsdelivr.net/gh/MrTangLuyao/Bilibili-thread-ripper@main/src/cdn-resolver.js"] ];
}

+ (NSURL *)signedListURL { return [NSURL URLWithString:@"https://static.matchacake.net/c/n1.json"]; }

+ (BOOL)isAllowedNodeHost:(NSString *)host {
    if (![host isKindOfClass:NSString.class] || !host.length || host.length > 253) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^(?:(?:upos|cn)-[a-z0-9]+(?:-[a-z0-9]+)*\\.bilivideo\\.com|upos-[a-z0-9]+(?:-[a-z0-9]+)*\\.akamaized\\.net)$"
                                                       options:0 error:nil];
    });
    return [re firstMatchInString:host options:0 range:NSMakeRange(0, host.length)] != nil;
}

/// Clean, de-duplicated list or nil when any entry is not an allowed node / the size is off.
static NSArray<NSString *> *ValidList(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id h in raw) {
        if (![BTRNodeList isAllowedNodeHost:h]) return nil;
        if (![out containsObject:h]) [out addObject:h];
    }
    return (out.count >= 1 && out.count <= kMaxNodesPerList) ? out : nil;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)parseUpstreamSource:(NSString *)text error:(NSString **)error {
    NSString *(^fail)(NSString *) = ^NSString *(NSString *why) { if (error) *error = why; return nil; };
    if (![text isKindOfClass:NSString.class] || !text.length) return (id)fail(@"内容为空");
    if (text.length > kMaxSourceBytes) return (id)fail(@"内容过大");
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSRegularExpression *quoted = [NSRegularExpression regularExpressionWithPattern:@"\"([^\"\\n]*)\"|'([^'\\n]*)'" options:0 error:nil];
    for (NSArray *pair in @[ @[ @"MAINLAND_HOSTS", @"mainland" ], @[ @"OVERSEAS_HOSTS", @"overseas" ] ]) {
        NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*(?:Object\\.freeze\\(\\s*)?\\[([^\\]]*)\\]", pair[0]];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (!m) return (id)fail([NSString stringWithFormat:@"没找到 %@，原项目文件格式可能变了", pair[0]]);
        NSString *body = [text substringWithRange:[m rangeAtIndex:1]];
        NSMutableArray *hosts = [NSMutableArray array];
        for (NSTextCheckingResult *q in [quoted matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
            NSRange r = [q rangeAtIndex:1].location != NSNotFound ? [q rangeAtIndex:1] : [q rangeAtIndex:2];
            [hosts addObject:[body substringWithRange:r]];
        }
        for (NSString *h in hosts)
            if (![self isAllowedNodeHost:h]) return (id)fail([NSString stringWithFormat:@"%@ 里有不是 B 站节点的主机：%@", pair[0], h]);
        NSArray *list = ValidList(hosts);
        if (!list) return (id)fail([NSString stringWithFormat:@"%@ 为空或超过 %lu 个", pair[0], (unsigned long)kMaxNodesPerList]);
        out[pair[1]] = list;
    }
    return out;
}

static NSDate *ParseISODate(id v) {
    if (![v isKindOfClass:NSString.class]) return nil;
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSISO8601DateFormatter new]; });
    @synchronized (f) { return [f dateFromString:v]; }
}

static BOOL VerifyES256(NSData *message, NSData *derSignature, NSData *x963Key) {
    if (x963Key.length != 65 || !derSignature.length) return NO;
    NSDictionary *attrs = @{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                             (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
                             (__bridge id)kSecAttrKeySizeInBits: @256 };
    CFErrorRef err = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)x963Key, (__bridge CFDictionaryRef)attrs, &err);
    if (!key) {
        if (err) CFRelease(err);
        return NO;
    }
    BOOL ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                    (__bridge CFDataRef)message, (__bridge CFDataRef)derSignature, &err);
    if (err) CFRelease(err);
    CFRelease(key);
    return ok;
}

#define SIGNED_FAIL(...) do { if (error) *error = (__VA_ARGS__); return nil; } while (0)
+ (NSDictionary *)parseSignedList:(NSData *)data now:(NSDate *)now minVersion:(int64_t)minVersion key:(NSData *)x963Key error:(NSString **)error {
    if (![data isKindOfClass:NSData.class] || !data.length) SIGNED_FAIL(@"内容为空");
    if (data.length > kMaxSignedBytes) SIGNED_FAIL(@"内容过大");
    NSDictionary *env = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![env isKindOfClass:NSDictionary.class]) SIGNED_FAIL(@"不是签名列表");
    if (![env[@"format"] isEqual:@"btr-cdn-list/1"] || ![env[@"alg"] isEqual:@"ES256"]) SIGNED_FAIL(@"签名列表格式不认识");
    NSString *payloadText = env[@"payload"];
    NSString *sigText = env[@"signature"];
    if (![payloadText isKindOfClass:NSString.class] || ![sigText isKindOfClass:NSString.class] || !payloadText.length) SIGNED_FAIL(@"签名列表不完整");
    NSData *payloadData = [payloadText dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:sigText options:0];
    if (!VerifyES256(payloadData, sig, x963Key)) SIGNED_FAIL(@"签名无效");

    NSDictionary *p = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
    if (![p isKindOfClass:NSDictionary.class] || ![p[@"kind"] isEqual:@"btr-cdn-nodes"]) SIGNED_FAIL(@"签名列表内容不认识");
    if (![p[@"version"] isKindOfClass:NSNumber.class] || [p[@"version"] longLongValue] <= 0) SIGNED_FAIL(@"版本号无效");
    int64_t version = [p[@"version"] longLongValue];
    NSDate *updated = ParseISODate(p[@"updated_at"]), *expires = ParseISODate(p[@"expires_at"]);
    if (!updated || !expires || [expires compare:updated] != NSOrderedDescending) SIGNED_FAIL(@"时间字段无效");
    if ([now compare:expires] != NSOrderedAscending) SIGNED_FAIL([NSString stringWithFormat:@"列表已过期（%@）", p[@"expires_at"]]);
    if (version < minVersion) SIGNED_FAIL([NSString stringWithFormat:@"版本 %lld 比已用过的 %lld 旧", version, minVersion]);

    NSDictionary *groups = p[@"groups"];
    if (![groups isKindOfClass:NSDictionary.class]) SIGNED_FAIL(@"缺少分组");
    NSArray *known = @[ @"mainland", @"overseas", @"hk", @"akamai" ];
    for (NSString *k in groups) if (![known containsObject:k]) SIGNED_FAIL([NSString stringWithFormat:@"未知分组 %@", k]);
    NSMutableDictionary<NSString *, NSArray *> *g = [NSMutableDictionary dictionary];
    for (NSString *name in known) {
        NSArray *list = groups[name];
        if (![list isKindOfClass:NSArray.class]) SIGNED_FAIL([NSString stringWithFormat:@"缺少分组 %@", name]);
        for (id h in list) {
            BOOL ok = [self isAllowedNodeHost:h];
            if (ok && [name isEqualToString:@"akamai"]) ok = [h hasSuffix:@".akamaized.net"];
            else if (ok) ok = [h hasSuffix:@".bilivideo.com"] && (![name isEqualToString:@"hk"] || [h hasPrefix:@"cn-hk-"]);
            if (!ok) {
                NSString *shown = [h isKindOfClass:NSString.class] ? h : [h description];
                SIGNED_FAIL([NSString stringWithFormat:@"%@ 里有不允许的主机：%@", name, shown.length > 80 ? [shown substringToIndex:80] : shown]);
            }
        }
        g[name] = list;
    }
    NSArray *m = ValidList(g[@"mainland"]);
    NSArray *o = ValidList([g[@"overseas"] arrayByAddingObjectsFromArray:g[@"hk"]]);
    if (!m) SIGNED_FAIL([NSString stringWithFormat:@"大陆节点为空或超过 %lu 个", (unsigned long)kMaxNodesPerList]);
    if (!o) SIGNED_FAIL([NSString stringWithFormat:@"海外节点为空或超过 %lu 个", (unsigned long)kMaxNodesPerList]);
    return @{ @"mainland": m, @"overseas": o, @"version": @(version), @"expiresAt": expires };
}
#undef SIGNED_FAIL

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _d = defaults;
        _signedListKey = [[NSData alloc] initWithBase64EncodedString:kSignedListKeyB64 options:0];
        [self load];
    }
    return self;
}

- (NSData *)signedListKey { @synchronized (self) { return _signedListKey; } }
- (void)setSignedListKey:(NSData *)key { @synchronized (self) { _signedListKey = [key copy]; } }

- (void)load {
    NSDictionary *saved = [_d objectForKey:kNodesKey];
    NSArray *m = nil, *o = nil;
    if ([saved isKindOfClass:NSDictionary.class]) {
        m = ValidList(saved[@"mainland"]);
        o = ValidList(saved[@"overseas"]);
        if (!m || !o) BTRLog(@"保存的节点列表无效，改用内置列表");
    }
    @synchronized (self) {
        if (m && o) {
            _mainland = m;
            _overseas = o;
            _updatedAt = [saved[@"updatedAt"] isKindOfClass:NSDate.class] ? saved[@"updatedAt"] : nil;
            _source = [saved[@"source"] isKindOfClass:NSString.class] ? saved[@"source"] : nil;
            _version = [saved[@"version"] isKindOfClass:NSNumber.class] ? [saved[@"version"] longLongValue] : 0;
        } else {
            _mainland = BTRNodeList.builtinMainland;
            _overseas = BTRNodeList.builtinOverseas;
            _updatedAt = nil;
            _source = nil;
            _version = 0;
        }
    }
}

- (NSArray<NSString *> *)mainland { @synchronized (self) { return _mainland; } }
- (NSArray<NSString *> *)overseas { @synchronized (self) { return _overseas; } }
- (NSDate *)updatedAt { @synchronized (self) { return _updatedAt; } }
- (NSString *)sourceHost { @synchronized (self) { return _source; } }
- (BOOL)isBuiltin { @synchronized (self) { return _updatedAt == nil; } }
- (int64_t)version { @synchronized (self) { return _version; } }
- (int64_t)maxSignedVersion { return [[_d objectForKey:kMaxSignedVersionKey] longLongValue]; }

static NSInteger Missing(NSArray *from, NSArray *in) {
    NSInteger n = 0;
    for (id x in from) if (![in containsObject:x]) n++;
    return n;
}

- (BTRNodeUpdateResult *)applyMainland:(NSArray<NSString *> *)mainland overseas:(NSArray<NSString *> *)overseas source:(NSString *)sourceHost {
    return [self applyMainland:mainland overseas:overseas source:sourceHost version:0 expiresAt:nil];
}

- (BTRNodeUpdateResult *)applyMainland:(NSArray<NSString *> *)mainland overseas:(NSArray<NSString *> *)overseas source:(NSString *)sourceHost
                               version:(int64_t)version expiresAt:(NSDate *)expiresAt {
    BTRNodeUpdateResult *r = [BTRNodeUpdateResult new];
    NSArray *m = ValidList(mainland), *o = ValidList(overseas);
    if (!m || !o) {
        r.message = @"节点列表无效，未修改当前列表。";
        return r;
    }
    NSArray *oldM = self.mainland, *oldO = self.overseas;
    NSDate *now = NSDate.date;
    NSMutableDictionary *rec = [@{ @"mainland": m, @"overseas": o, @"updatedAt": now, @"source": sourceHost ?: @"" } mutableCopy];
    if (version > 0) {
        rec[@"version"] = @(version);
        if (expiresAt) rec[@"expiresAt"] = expiresAt;
    }
    @synchronized (self) {
        [_d setObject:rec forKey:kNodesKey];
        if (version > [[_d objectForKey:kMaxSignedVersionKey] longLongValue]) [_d setObject:@(version) forKey:kMaxSignedVersionKey];
        _mainland = m;
        _overseas = o;
        _updatedAt = now;
        _source = sourceHost;
        _version = version;
    }
    r.ok = YES;
    r.added = Missing(m, oldM) + Missing(o, oldO);
    r.removed = Missing(oldM, m) + Missing(oldO, o);
    r.message = [NSString stringWithFormat:@"%@：大陆 %lu 个、海外 %lu 个，新增 %ld、移除 %ld。%@",
                 r.added || r.removed ? @"已更新" : @"已是最新", (unsigned long)m.count, (unsigned long)o.count,
                 (long)r.added, (long)r.removed, sourceHost.length ? [@"来源：" stringByAppendingString:sourceHost] : @""];
    BTRLog(@"节点列表%@", r.message);
    return r;
}

- (void)restoreBuiltin {
    [_d removeObjectForKey:kNodesKey];
    [self load];
    BTRLog(@"已恢复内置节点列表");
}

- (void)updateFromURLs:(NSArray<NSURL *> *)urls completion:(void (^)(BTRNodeUpdateResult *))completion {
    [self updateFromSignedURL:nil upstreamURLs:urls completion:completion];
}

- (void)updateFromSignedURL:(NSURL *)signedURL upstreamURLs:(NSArray<NSURL *> *)urls completion:(void (^)(BTRNodeUpdateResult *))completion {
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 10;
    cfg.timeoutIntervalForResource = 20;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableArray<NSArray *> *sources = [NSMutableArray array];
    if (signedURL) [sources addObject:@[ signedURL, @YES ]];
    for (NSURL *u in urls) [sources addObject:@[ u, @NO ]];
    [self trySources:sources index:0 session:session errors:[NSMutableArray array] completion:^(BTRNodeUpdateResult *r) {
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
    }];
}

- (void)trySources:(NSArray<NSArray *> *)sources index:(NSUInteger)i session:(NSURLSession *)session errors:(NSMutableArray<NSString *> *)errors
        completion:(void (^)(BTRNodeUpdateResult *))completion {
    if (i >= sources.count) {
        BTRNodeUpdateResult *r = [BTRNodeUpdateResult new];
        r.message = [NSString stringWithFormat:@"更新失败，继续使用当前列表。\n%@", [errors componentsJoinedByString:@"\n"]];
        BTRLog(@"节点列表更新失败：%@", [errors componentsJoinedByString:@"；"]);
        completion(r);
        return;
    }
    NSURL *url = sources[i][0];
    BOOL isSigned = [sources[i][1] boolValue];
    NSString *label = url.host.length ? url.host : url.lastPathComponent;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *why = nil;
        NSDictionary *lists = nil;
        BOOL fileOK = NO;
#ifdef BTR_TESTING
        fileOK = url.isFileURL; // host tests read fixtures from disk
#endif
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err) why = err.localizedDescription;
        else if (!fileOK && status != 200) why = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        else if (data.length > (isSigned ? kMaxSignedBytes : kMaxSourceBytes)) why = @"内容过大";
        else if (isSigned) {
            NSString *parseError = nil;
            lists = [BTRNodeList parseSignedList:data now:NSDate.date minVersion:self.maxSignedVersion key:self.signedListKey error:&parseError];
            if (!lists) why = parseError ?: @"无法解析";
        } else {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *parseError = nil;
            lists = [BTRNodeList parseUpstreamSource:text error:&parseError];
            if (!lists) why = parseError ?: @"无法解析";
        }
        if (lists) {
            NSString *source = isSigned ? [NSString stringWithFormat:@"%@ v%@（%@）", kSignedLabel, lists[@"version"], label] : label;
            BTRNodeUpdateResult *r = [self applyMainland:lists[@"mainland"] overseas:lists[@"overseas"] source:source
                                                 version:[lists[@"version"] longLongValue] expiresAt:lists[@"expiresAt"]];
            if (r.ok && errors.count) r.message = [r.message stringByAppendingFormat:@"\n（%@）", [errors componentsJoinedByString:@"；"]];
            completion(r);
        } else {
            [errors addObject:[NSString stringWithFormat:@"%@%@：%@", isSigned ? [kSignedLabel stringByAppendingString:@" "] : @"", label, why]];
            [self trySources:sources index:i + 1 session:session errors:errors completion:completion];
        }
    }] resume];
}

- (void)updateWithCompletion:(void (^)(BTRNodeUpdateResult *))completion {
    [self updateFromSignedURL:BTRNodeList.signedListURL upstreamURLs:BTRNodeList.sourceURLs completion:completion];
}

- (void)refreshSignedIfStale {
    NSDate *last = [_d objectForKey:kLastAutoRefreshKey];
    if ([last isKindOfClass:NSDate.class] && -[last timeIntervalSinceNow] < 24 * 3600) return;
    [_d setObject:NSDate.date forKey:kLastAutoRefreshKey];
    [self updateFromSignedURL:BTRNodeList.signedListURL upstreamURLs:@[] completion:^(BTRNodeUpdateResult *r) {}];
}

- (NSString *)summary {
    NSArray *m = self.mainland, *o = self.overseas;
    NSDate *at = self.updatedAt;
    NSString *counts = [NSString stringWithFormat:@"大陆 %lu / 海外 %lu", (unsigned long)m.count, (unsigned long)o.count];
    if (!at) return [@"内置 · " stringByAppendingString:counts];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [NSString stringWithFormat:@"%@ 更新 · %@", [fmt stringFromDate:at], counts];
}

@end
