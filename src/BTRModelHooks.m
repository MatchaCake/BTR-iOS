// BTR-iOS: hooks below the network layer.
//
// The official app fetches play addresses with gRPC-ObjC (GRPCStreamingProtoCall over Cronet /
// gRPC core), which never goes through NSURLSession, so the NSURLSession hooks in BTRHooks.m
// do not see PlayViewUnite. Every transport still ends in protobuf decoding, though:
// GPBMessage -initWithData:extensionRegistry:error: receives the raw reply bytes. Rewriting
// them there reuses the same generic protobuf rewriter, whatever the transport.
//
// As a fallback (and to show on device what the player really opens) the IJKPlayer DASH stream
// objects are hooked too; their selectors and type encodings come from a runtime class dump of
// the official app 9.12 on iOS 27. Every hook checks the type encoding before installing and is
// skipped (with a log line) when it does not match.
#import "BTRCore.h"
#import "BTRHooks.h"
#import "BTRProxy.h"
#import <objc/runtime.h>

#pragma mark - Helpers

static BOOL EncodingIs(Method m, const char *expected) {
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc) return NO;
    // Compare without the frame offsets: "v24@0:8@16" -> "v@:@".
    char buf[128];
    size_t n = 0;
    for (const char *p = enc; *p && n < sizeof buf - 1; p++)
        if (*p < '0' || *p > '9') buf[n++] = *p;
    buf[n] = 0;
    return strcmp(buf, expected) == 0;
}

/// Replaces `sel` of `cls` (as resolved on `cls`) when its encoding matches. Returns the old IMP.
static IMP Replace(NSString *clsName, NSString *selName, const char *encoding, IMP replacement) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return NULL;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { BTRLog(@"%@ 没有 %@，跳过", clsName, selName); return NULL; }
    if (!EncodingIs(m, encoding)) {
        BTRLog(@"%@ %@ 的签名是 %s，不是预期的 %s，跳过", clsName, selName, method_getTypeEncoding(m), encoding);
        return NULL;
    }
    // Only replace on the class itself, never on an inherited system implementation.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        return method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    }
    // The method was inherited: we added an override, call the inherited IMP as the original.
    return method_getImplementation(m);
}

static BOOL HasSuffix(const char *s, size_t len, const char *suffix) {
    size_t n = strlen(suffix);
    return len >= n && memcmp(s + len - n, suffix, n) == 0;
}

BOOL BTRIsPlayReplyClassName(const char *name) {
    if (!name) return NO;
    size_t len = strlen(name);
    if (len < 12 || len > 200 || !HasSuffix(name, len, "Reply")) return NO; // fast path for most messages
    if (strstr(name, "Live")) return NO;                                    // live streams are left alone
    return HasSuffix(name, len, "PlayViewUniteReply") || HasSuffix(name, len, "PlayViewReply") ||
           HasSuffix(name, len, "PlayURLReply") || HasSuffix(name, len, "PlayUrlReply");
}

#pragma mark - Protobuf replies (GPBMessage)

typedef id (*InitWithData)(id, SEL, NSData *, id, NSError **);
typedef void (*MergeFromData)(id, SEL, NSData *, id);
typedef BOOL (*MergeFromDataError)(id, SEL, NSData *, id, NSError **);
static InitWithData origInitWithData;
static MergeFromData origMergeFromData;
static MergeFromDataError origMergeFromDataError;

// initWithData: usually calls mergeFromData: internally; only the outermost call rewrites.
static __thread int gPBDepth;

static NSData *ReplyData(id self, NSData *data) {
    if (gPBDepth > 0 || ![data isKindOfClass:NSData.class] || !data.length) return data;
    Class c = object_getClass(self);
    const char *name = class_getName(c);
    if (!BTRIsPlayReplyClassName(name)) return data;
    NSString *label = @(name);
    [BTRDiag note:@"protobuf 播放回复" item:[NSString stringWithFormat:@"%@（%@）", label, [BTRMedia formatBytes:(int64_t)data.length]]];
    return BTRRewriteProtobufReply(data, label) ?: data;
}

static id HookInitWithData(id self, SEL _cmd, NSData *data, id registry, NSError **error) {
    data = ReplyData(self, data);
    gPBDepth++;
    id r = origInitWithData(self, _cmd, data, registry, error);
    gPBDepth--;
    return r;
}

static void HookMergeFromData(id self, SEL _cmd, NSData *data, id registry) {
    data = ReplyData(self, data);
    gPBDepth++;
    origMergeFromData(self, _cmd, data, registry);
    gPBDepth--;
}

static BOOL HookMergeFromDataError(id self, SEL _cmd, NSData *data, id registry, NSError **error) {
    data = ReplyData(self, data);
    gPBDepth++;
    BOOL r = origMergeFromDataError(self, _cmd, data, registry, error);
    gPBDepth--;
    return r;
}

static BOOL InstallProtobufHooks(void) {
    if (!NSClassFromString(@"GPBMessage")) return NO;
    if (!origInitWithData)
        origInitWithData = (InitWithData)Replace(@"GPBMessage", @"initWithData:extensionRegistry:error:", "@@:@@^@", (IMP)HookInitWithData);
    if (!origMergeFromData)
        origMergeFromData = (MergeFromData)Replace(@"GPBMessage", @"mergeFromData:extensionRegistry:", "v@:@@", (IMP)HookMergeFromData);
    if (!origMergeFromDataError) {
        Method m = class_getInstanceMethod(NSClassFromString(@"GPBMessage"), NSSelectorFromString(@"mergeFromData:extensionRegistry:error:"));
        if (m) origMergeFromDataError = (MergeFromDataError)Replace(@"GPBMessage", @"mergeFromData:extensionRegistry:error:", "B@:@@^@", (IMP)HookMergeFromDataError);
    }
    BTRLog(@"protobuf 接管：initWithData %@，mergeFromData %@，mergeFromData:error %@",
           origInitWithData ? @"✓" : @"✗", origMergeFromData ? @"✓" : @"✗", origMergeFromDataError ? @"✓" : @"-");
    return origInitWithData || origMergeFromData || origMergeFromDataError;
}

#pragma mark - Player objects (IJKPlayer)

static NSString *StringOf(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString];
    return nil;
}

id BTRProcessPlayerURL(id value, NSArray *backups, NSString *where, BOOL rewrite) {
    NSString *s = StringOf(value);
    if (!s.length) return value;
    NSURL *u = [NSURL URLWithString:s];
    BOOL proxied = [u.host isEqualToString:@"127.0.0.1"] && [u.path hasPrefix:@"/btr/"];
    BOOL media = !proxied && [BTRMedia isMediaURL:s];
    if (!proxied && !media) {
        // Not a Bilibili media address (local file, P2P scheme, ...): still useful to see.
        [BTRDiag note:@"播放器拿到的地址" item:[NSString stringWithFormat:@"%@ 其他：%@://%@/…/%@", where, u.scheme ?: @"?", u.host ?: @"", u.path.lastPathComponent ?: @""]];
        return value;
    }
    [BTRStats.shared add:@"playerURLs" value:1];
    if (proxied) {
        [BTRStats.shared add:@"playerProxied" value:1];
        [BTRDiag note:@"播放器拿到的地址" item:[NSString stringWithFormat:@"%@ 已走 BTR：%@", where, u.path.lastPathComponent]];
        return value;
    }
    NSMutableArray<NSString *> *b = [NSMutableArray array];
    for (id x in backups) { NSString *bs = StringOf(x); if (bs) [b addObject:bs]; }
    NSString *replacement = rewrite ? BTRDefaultMapper()(s, b) : nil;
    [BTRDiag note:@"播放器拿到的地址" item:[NSString stringWithFormat:@"%@ %@：%@/…/%@", where, replacement ? @"未走 BTR→已改写" : @"未走 BTR", u.host, u.path.lastPathComponent]];
    if (!replacement) return value;
    id out = [value isKindOfClass:NSURL.class] ? [NSURL URLWithString:replacement] : replacement;
    if (!out) return value;
    [BTRStats.shared add:@"playerRewritten" value:1];
    [BTRStats.shared add:@"rewrittenURLs" value:1];
    BTRLog(@"播放器层接管了一条地址（%@）：%@", where, u.path.lastPathComponent);
    return out;
}

typedef void (*SetObject)(id, SEL, id);
typedef id (*InitObject)(id, SEL, id);
typedef id (*DashItemInit)(id, SEL, int, int, id, long long, int, int);
typedef id (*DashBridgeInit)(id, SEL, long long, long long, long long, long long, id, id);

static SetObject origDashSetBaseUrl, origBridgeSetUrl, origItemSetUrl, origItemWillOpenUrl;
static InitObject origSegmentInitWithUrl;
static DashItemInit origDashItemInit;
static DashBridgeInit origDashBridgeInit;

static void HookDashSetBaseUrl(id self, SEL _cmd, id url) {
    origDashSetBaseUrl(self, _cmd, BTRProcessPlayerURL(url, nil, @"DashStreamItem", YES));
}

static id HookDashItemInit(id self, SEL _cmd, int streamId, int bandwidth, id baseUrl, long long fileSize, int streamType, int codecType) {
    return origDashItemInit(self, _cmd, streamId, bandwidth, BTRProcessPlayerURL(baseUrl, nil, @"DashStreamItem", YES), fileSize, streamType, codecType);
}

static void HookBridgeSetUrl(id self, SEL _cmd, id url) {
    id backups = nil;
    @try { if ([self respondsToSelector:@selector(backupUrls)]) backups = [self valueForKey:@"backupUrls"]; } @catch (NSException *e) {}
    origBridgeSetUrl(self, _cmd, BTRProcessPlayerURL(url, [backups isKindOfClass:NSArray.class] ? backups : nil, @"DashStreamBridge", YES));
}

static id HookDashBridgeInit(id self, SEL _cmd, long long mediaType, long long codecId, long long qn, long long bandwidth, id url, id backupUrls) {
    NSArray *b = [backupUrls isKindOfClass:NSArray.class] ? backupUrls : nil;
    return origDashBridgeInit(self, _cmd, mediaType, codecId, qn, bandwidth, BTRProcessPlayerURL(url, b, @"DashStreamBridge", YES), backupUrls);
}

// Observe only: what the player finally opens.
static void HookItemSetUrl(id self, SEL _cmd, id url) {
    BTRProcessPlayerURL(url, nil, @"PlayerItem.url", NO);
    origItemSetUrl(self, _cmd, url);
}

static void HookItemWillOpenUrl(id self, SEL _cmd, id data) {
    id url = data;
    if (data && !StringOf(data)) {
        @try { if ([data respondsToSelector:@selector(url)]) url = [data valueForKey:@"url"]; } @catch (NSException *e) { url = nil; }
    }
    BTRProcessPlayerURL(url, nil, @"willOpenUrl", NO);
    origItemWillOpenUrl(self, _cmd, data);
}

static id HookSegmentInitWithUrl(id self, SEL _cmd, id url) {
    BTRProcessPlayerURL(url, nil, @"AssetSegment", NO);
    return origSegmentInitWithUrl(self, _cmd, url);
}

static BOOL InstallPlayerHooks(void) {
    if (!NSClassFromString(@"IJKDashStreamItem") && !NSClassFromString(@"IJKMediaPlayerItem")) return NO;
#define HOOK(var, type, cls, sel, enc, fn) if (!var) var = (type)Replace(cls, sel, enc, (IMP)fn)
    HOOK(origDashSetBaseUrl, SetObject, @"IJKDashStreamItem", @"setBaseUrl:", "v@:@", HookDashSetBaseUrl);
    HOOK(origDashItemInit, DashItemInit, @"IJKDashStreamItem", @"initWithStreamId:bandwidth:baseUrl:fileSize:streamType:codecType:", "@@:ii@qii", HookDashItemInit);
    HOOK(origBridgeSetUrl, SetObject, @"IJKDashStreamBridge", @"setUrl:", "v@:@", HookBridgeSetUrl);
    HOOK(origDashBridgeInit, DashBridgeInit, @"IJKDashStreamBridge", @"initWithMediaType:codecId:qn:bandwidth:url:backupUrls:", "@@:qqqq@@", HookDashBridgeInit);
    HOOK(origItemSetUrl, SetObject, @"IJKMediaPlayerItem", @"setUrl:", "v@:@", HookItemSetUrl);
    HOOK(origItemWillOpenUrl, SetObject, @"IJKMediaPlayerItem", @"willOpenUrl:", "v@:@", HookItemWillOpenUrl);
    HOOK(origSegmentInitWithUrl, InitObject, @"IJKMediaAssetStreamSegment", @"initWithUrl:", "@@:@", HookSegmentInitWithUrl);
#undef HOOK
    BTRLog(@"播放器接管：DashStreamItem %@/%@，DashStreamBridge %@/%@，观察 PlayerItem %@/%@，Segment %@",
           origDashSetBaseUrl ? @"✓" : @"✗", origDashItemInit ? @"✓" : @"✗", origBridgeSetUrl ? @"✓" : @"✗", origDashBridgeInit ? @"✓" : @"✗",
           origItemSetUrl ? @"✓" : @"✗", origItemWillOpenUrl ? @"✓" : @"✗", origSegmentInitWithUrl ? @"✓" : @"✗");
    return YES;
}

#pragma mark - Entry

static NSLock *gInstallLock;
static BOOL gProtobufDone, gPlayerDone;

static void TryInstall(NSString *when) {
    [gInstallLock lock];
    if (!gProtobufDone) gProtobufDone = InstallProtobufHooks();
    if (!gPlayerDone) gPlayerDone = InstallPlayerHooks();
    BOOL pb = gProtobufDone, player = gPlayerDone;
    [gInstallLock unlock];
    if (!pb || !player)
        BTRLog(@"%@：%@%@", when, pb ? @"" : @"还没找到 GPBMessage（protobuf）；", player ? @"" : @"还没找到 IJKPlayer 类");
}

void BTRInstallModelHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInstallLock = [NSLock new];
        TryInstall(@"加载时");
        if (gProtobufDone && gPlayerDone) return;
        // The guest app's classes may not be registered yet when the tweak is loaded early.
        __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidFinishLaunchingNotification" object:nil queue:nil usingBlock:^(NSNotification *n) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            TryInstall(@"App 启动完成后");
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ TryInstall(@"主线程首次运行时"); });
    });
}
