// Host (macOS) tests for the platform-independent parts of BTR-iOS: CDN candidates, the
// JSON / protobuf / gRPC rewriter, the NSURLSession hooks and the multi-connection proxy.
// Run with tests/run.sh.
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import "../src/BTRCore.h"
#import "../src/BTRHooks.h"
#import "../src/BTRProxy.h"
#import "../src/BTRRewriter.h"

static int failures = 0, passes = 0;
#define CHECK(cond, ...) do { if (cond) { passes++; } else { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); } } while (0)

static const NSUInteger kSize = 7340033;
static uint16_t gOK, gSlow, gBad;

#pragma mark - helpers

static NSString *SHA(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

static NSData *Fetch(NSString *url, NSString *method, NSString *range, NSHTTPURLResponse **resp, NSURLSession *session) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method;
    r.timeoutInterval = 60;
    if (range) [r setValue:range forHTTPHeaderField:@"Range"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *out = nil;
    __block NSHTTPURLResponse *rr = nil;
    [[session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *res, NSError *e) {
        out = d;
        rr = (NSHTTPURLResponse *)res;
        if (e) fprintf(stderr, "  request error: %s\n", e.localizedDescription.UTF8String);
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (resp) *resp = rr;
    return out;
}

// Minimal protobuf reader for assertions: returns the string values of field `num`.
static NSArray<NSData *> *Strings(NSData *msg, uint32_t num) {
    NSMutableArray *out = [NSMutableArray array];
    const uint8_t *p = msg.bytes;
    size_t len = msg.length, pos = 0;
    while (pos < len) {
        uint64_t tag = 0; int sh = 0;
        while (1) { uint8_t b = p[pos++]; tag |= (uint64_t)(b & 0x7f) << sh; sh += 7; if (!(b & 0x80)) break; }
        uint32_t f = (uint32_t)(tag >> 3), w = tag & 7;
        if (w == 0) { while (p[pos++] & 0x80) {} }
        else if (w == 1) pos += 8;
        else if (w == 5) pos += 4;
        else {
            uint64_t l = 0; sh = 0;
            while (1) { uint8_t b = p[pos++]; l |= (uint64_t)(b & 0x7f) << sh; sh += 7; if (!(b & 0x80)) break; }
            if (f == num) [out addObject:[NSData dataWithBytes:p + pos length:(NSUInteger)l]];
            pos += l;
        }
    }
    return out;
}

static NSData *Sub(NSData *msg, uint32_t num) { return (NSData *)Strings(msg, num).firstObject; }
static NSString *Str(NSData *d) { return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil; }

static void Varint(NSMutableData *d, uint64_t v) {
    do { uint8_t b = v & 0x7f; v >>= 7; if (v) b |= 0x80; [d appendBytes:&b length:1]; } while (v);
}
static void PutString(NSMutableData *d, uint32_t f, NSData *s) { Varint(d, (f << 3) | 2); Varint(d, s.length); [d appendData:s]; }
static void PutVarint(NSMutableData *d, uint32_t f, uint64_t v) { Varint(d, (f << 3) | 0); Varint(d, v); }
static NSData *U(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

#pragma mark - fake app classes (stand-ins for the official app's protobuf runtime and IJKPlayer)

@interface GPBMessage : NSObject
@property (nonatomic, strong) NSData *raw;
@property (nonatomic) int merges;
- (instancetype)initWithData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error;
- (void)mergeFromData:(NSData *)data extensionRegistry:(id)registry;
@end
@implementation GPBMessage
- (instancetype)initWithData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error {
    if ((self = [super init])) [self mergeFromData:data extensionRegistry:registry]; // like protobuf-objc
    return self;
}
- (void)mergeFromData:(NSData *)data extensionRegistry:(id)registry {
    NSMutableData *m = [NSMutableData dataWithData:self.raw ?: [NSData data]];
    [m appendData:data];
    self.raw = m;
    self.merges++;
}
@end
@interface BAPIAppPlayeruniteV1PlayViewUniteReply : GPBMessage
@end
@implementation BAPIAppPlayeruniteV1PlayViewUniteReply
@end
@interface BAPIPgcGatewayPlayerV2PlayViewReply : GPBMessage
@end
@implementation BAPIPgcGatewayPlayerV2PlayViewReply
@end
@interface BAPIAppViewV1ViewReply : GPBMessage
@end
@implementation BAPIAppViewV1ViewReply
@end
@interface BAPIPgcGatewayPlayerV1LivePlayViewReply : GPBMessage
@end
@implementation BAPIPgcGatewayPlayerV1LivePlayViewReply
@end

@interface IJKDashStreamItem : NSObject
@property (nonatomic, copy) NSString *baseUrl;
- (instancetype)initWithStreamId:(int)streamId bandwidth:(int)bandwidth baseUrl:(NSString *)baseUrl fileSize:(long long)fileSize streamType:(int)streamType codecType:(int)codecType;
@end
@implementation IJKDashStreamItem
- (instancetype)initWithStreamId:(int)streamId bandwidth:(int)bandwidth baseUrl:(NSString *)baseUrl fileSize:(long long)fileSize streamType:(int)streamType codecType:(int)codecType {
    if ((self = [super init])) _baseUrl = [baseUrl copy]; // ivar, not the setter, like generated code often does
    return self;
}
@end
@interface IJKDashStreamBridge : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSArray *backupUrls;
- (instancetype)initWithMediaType:(long long)t codecId:(long long)c qn:(long long)q bandwidth:(long long)b url:(NSURL *)url backupUrls:(NSArray *)backups;
@end
@implementation IJKDashStreamBridge
- (instancetype)initWithMediaType:(long long)t codecId:(long long)c qn:(long long)q bandwidth:(long long)b url:(NSURL *)url backupUrls:(NSArray *)backups {
    if ((self = [super init])) { _url = url; _backupUrls = [backups copy]; }
    return self;
}
@end
@interface IJKMediaPlayerItem : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) id opened;
- (void)willOpenUrl:(id)data;
@end
@implementation IJKMediaPlayerItem
- (void)willOpenUrl:(id)data { self.opened = data; }
@end
@interface IJKMediaUrlOpenData : NSObject
@property (nonatomic, copy) NSString *url;
@end
@implementation IJKMediaUrlOpenData
@end
// Wrong signature on purpose: the hook must refuse to install.
@interface IJKMediaAssetStreamSegment : NSObject
@property (nonatomic) int value;
- (instancetype)initWithUrl:(int)value;
@end
@implementation IJKMediaAssetStreamSegment
- (instancetype)initWithUrl:(int)value { if ((self = [super init])) _value = value; return self; }
@end

#pragma mark - tests

static void TestCandidates(void) {
    NSString *mcdn = @"https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/11/22/333-1-100026.m4s?e=1&deadline=2&upsig=s";
    NSString *cos = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/333-1-100026.m4s?e=1&deadline=2&upsig=s";
    NSArray *c = [BTRMedia candidatesForPrimary:mcdn backups:@[ cos ] mode:BTRCDNModeMainland custom:@[]];
    CHECK(c.count == 8, @"mainland candidates = %lu", (unsigned long)c.count);
    CHECK([c.firstObject isEqualToString:cos], @"mainland original first: %@", c.firstObject);
    for (NSString *u in c) CHECK([u rangeOfString:@":4483"].location == NSNotFound && [u hasPrefix:@"https://upos-sz-"], @"bad candidate %@", u);
    CHECK([c containsObject:[cos stringByReplacingOccurrencesOfString:@"mirrorcos" withString:@"mirrorali"]], @"swap keeps path and query");

    NSString *aka = @"https://upos-hz-mirrorakam.akamaized.net/upgcxcode/11/22/333-1-100026.m4s?hdnts=x";
    NSArray *o = [BTRMedia candidatesForPrimary:aka backups:@[] mode:BTRCDNModeOverseas custom:@[]];
    CHECK(o.count == 5 && [o.firstObject isEqualToString:aka], @"overseas akamai-only: %@", o);
    NSArray *orig = [BTRMedia candidatesForPrimary:mcdn backups:@[ cos, @"https://evil.example.com/a.m4s" ] mode:BTRCDNModeOriginal custom:@[]];
    CHECK(orig.count == 2, @"original mode keeps only Bilibili originals: %@", orig);
    NSArray *custom = [BTRMedia candidatesForPrimary:mcdn backups:@[] mode:BTRCDNModeCustom custom:@[ @"upos-sz-mirrorhw.bilivideo.com", @"evil.com" ]];
    CHECK(custom.count == 1 && [custom.firstObject hasPrefix:@"https://upos-sz-mirrorhw.bilivideo.com/"], @"custom: %@", custom);
    CHECK([BTRMedia isAudioURL:@"https://a.bilivideo.com/x/333-1-30280.m4s?x"] && ![BTRMedia isAudioURL:mcdn], @"audio detection");
    CHECK(![BTRMedia isMediaURL:@"https://example.com/a.m4s"] && ![BTRMedia isMediaURL:@"https://upos-sz-mirrorcos.bilivideo.com/a.jpg"], @"media url filter");
    CHECK([[BTRMedia normalizeHost:@" HTTPS://Upos-SZ-mirrorcos.bilivideo.com/path "] isEqualToString:@"upos-sz-mirrorcos.bilivideo.com"], @"normalize host");
}

static BTRURLMapper TestMapper(void) {
    return ^NSString *(NSString *primary, NSArray<NSString *> *backups) {
        if ([BTRMedia isAudioURL:primary]) return nil;
        return [NSString stringWithFormat:@"http://127.0.0.1:1/btr/x.m4s?n=%lu", (unsigned long)backups.count];
    };
}

static void TestJSON(void) {
    NSString *v = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?a=1";
    NSString *b = @"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?a=1";
    NSString *a = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30280.m4s?a=1";
    NSDictionary *src = @{ @"data": @{ @"dash": @{ @"video": @[ @{ @"base_url": v, @"baseUrl": v, @"backup_url": @[ b ] } ],
                                                    @"audio": @[ @{ @"base_url": a, @"backup_url": @[] } ] },
                                       @"durl": @[ @{ @"url": [v stringByReplacingOccurrencesOfString:@".m4s" withString:@".flv"], @"backup_url": @[] } ] } };
    NSData *in = [NSJSONSerialization dataWithJSONObject:src options:0 error:nil];
    NSInteger count = 0;
    NSData *out = [BTRRewriter rewriteResponseData:in contentType:@"application/json" mapper:TestMapper() count:&count];
    NSDictionary *res = out ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
    CHECK(count == 2, @"json rewrite count %ld", (long)count);
    NSDictionary *video = res[@"data"][@"dash"][@"video"][0];
    CHECK([video[@"base_url"] isEqualToString:@"http://127.0.0.1:1/btr/x.m4s?n=1"] && [video[@"baseUrl"] isEqualToString:video[@"base_url"]], @"video rewritten: %@", video);
    CHECK([video[@"backup_url"][0] isEqualToString:b], @"backup untouched");
    CHECK([res[@"data"][@"dash"][@"audio"][0][@"base_url"] isEqualToString:a], @"audio untouched");
    CHECK([res[@"data"][@"durl"][0][@"url"] hasPrefix:@"http://127.0.0.1:1/"], @"durl rewritten");
    count = 0;
    NSData *none = [BTRRewriter rewriteResponseData:[@"{\"code\":0,\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding] contentType:nil mapper:TestMapper() count:&count];
    CHECK(none == nil && count == 0, @"unchanged json returns nil");
}

static NSData *SampleProto(NSString **videoOut) {
    NSString *v = @"https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/1/2/3-1-100026.m4s?deadline=9&upsig=z";
    NSString *b1 = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?deadline=9";
    NSString *b2 = @"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?deadline=9";
    NSString *a = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30280.m4s?deadline=9";
    NSMutableData *dashVideo = [NSMutableData data];
    PutString(dashVideo, 1, U(v)); PutString(dashVideo, 2, U(b1)); PutString(dashVideo, 2, U(b2)); PutVarint(dashVideo, 3, 2048000);
    NSMutableData *stream = [NSMutableData data];
    PutVarint(stream, 1, 80); PutString(stream, 2, dashVideo);
    NSMutableData *audio = [NSMutableData data];
    PutVarint(audio, 1, 30280); PutString(audio, 2, U(a)); PutString(audio, 3, U(a));
    // A long string field that must survive byte for byte.
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 40; i++) [text appendString:@"弹幕、字幕与清晰度 "];
    NSMutableData *vod = [NSMutableData data];
    PutVarint(vod, 1, 1); PutString(vod, 5, stream); PutString(vod, 6, audio); PutString(vod, 9, U(text));
    NSMutableData *reply = [NSMutableData data];
    PutString(reply, 1, vod); PutVarint(reply, 2, 7);
    if (videoOut) *videoOut = v;
    return reply;
}

static void TestProtobuf(void) {
    NSString *v = nil;
    NSData *reply = SampleProto(&v);
    NSInteger count = 0;
    NSData *out = [BTRRewriter rewriteProtobuf:reply mapper:TestMapper() count:&count];
    CHECK(out && count == 1, @"protobuf rewrite count %ld", (long)count);
    NSData *vod = Sub(out, 1), *stream = Sub(vod, 5), *dash = Sub(stream, 2);
    CHECK([Str(Sub(dash, 1)) isEqualToString:@"http://127.0.0.1:1/btr/x.m4s?n=2"], @"primary replaced: %@", Str(Sub(dash, 1)));
    CHECK(Strings(dash, 2).count == 2 && [Str(Strings(dash, 2)[0]) hasPrefix:@"https://upos-sz-mirrorcos"], @"backups untouched");
    CHECK([Sub(vod, 6) isEqualToData:Sub(Sub(reply, 1), 6)], @"audio message byte-identical");
    CHECK([Sub(vod, 9) isEqualToData:Sub(Sub(reply, 1), 9)], @"text field byte-identical");
    CHECK(out.length == reply.length - v.length + strlen("http://127.0.0.1:1/btr/x.m4s?n=2"), @"lengths rebuilt (%lu vs %lu)", (unsigned long)out.length, (unsigned long)reply.length);

    // gRPC frame, gzip compressed.
    NSData *gz = [BTRRewriter gzipDeflate:reply];
    NSMutableData *frame = [NSMutableData dataWithBytes:(uint8_t[]){ 1, (uint8_t)(gz.length >> 24), (uint8_t)(gz.length >> 16), (uint8_t)(gz.length >> 8), (uint8_t)gz.length } length:5];
    [frame appendData:gz];
    count = 0;
    NSData *g = [BTRRewriter rewriteResponseData:frame contentType:@"application/grpc" mapper:TestMapper() count:&count];
    CHECK(g && count == 1 && ((const uint8_t *)g.bytes)[0] == 1, @"grpc rewritten and still compressed");
    if (g) {
        const uint8_t *p = g.bytes;
        uint32_t l = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | p[4];
        CHECK(l == g.length - 5, @"grpc frame length");
        NSData *plain = [BTRRewriter gzipInflate:[g subdataWithRange:NSMakeRange(5, l)]];
        CHECK([plain isEqualToData:out], @"grpc payload equals protobuf rewrite");
    }
    // Garbage and unchanged bodies.
    CHECK([BTRRewriter rewriteResponseData:[NSData dataWithBytes:"\x00\x00\x00\x00\x09garbage!!" length:14] contentType:@"application/grpc" mapper:TestMapper() count:NULL] == nil, @"bad frame ignored");
    NSMutableData *plainMsg = [NSMutableData data];
    PutVarint(plainMsg, 1, 5); PutString(plainMsg, 2, U(@"hello"));
    CHECK([BTRRewriter rewriteProtobuf:plainMsg mapper:TestMapper() count:NULL] == nil, @"no url -> nil");
}

static void TestProxy(void) {
    BTRProxyServer *proxy = BTRProxyServer.shared;
    CHECK([proxy start] && proxy.port > 0, @"proxy started");
    BTRSettings *s = BTRSettings.shared;
    s.mode = BTRCDNModeOriginal;
    s.threads = 8;
    s.chunkKB = 256;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSString *path = @"/upgcxcode/11/22/333-1-100026.m4s?deadline=1999999999&upsig=abc";
    NSString *ok = [NSString stringWithFormat:@"http://127.0.0.1:%u%@", gOK, path];
    NSString *slow = [NSString stringWithFormat:@"http://localhost:%u%@", gSlow, path];
    NSString *bad = [NSString stringWithFormat:@"http://127.0.0.1:%u%@", gBad, path];
    NSData *reference = Fetch(ok, @"GET", nil, NULL, session);
    CHECK(reference.length == kSize, @"reference size %lu", (unsigned long)reference.length);

    NSString *purl = [proxy proxyURLForPrimary:ok backups:@[ slow, bad ]];
    NSString *expectPrefix = [NSString stringWithFormat:@"http://127.0.0.1:%u/btr/333-1-100026.m4s?u=", proxy.port];
    CHECK(([purl hasPrefix:expectPrefix] && [purl containsString:@"&deadline=1999999999"]), @"proxy url %@", purl);

    NSHTTPURLResponse *r = nil;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSData *full = Fetch(purl, @"GET", @"bytes=0-", &r, session);
    NSString *expectRange = [NSString stringWithFormat:@"bytes 0-%lu/%lu", kSize - 1, kSize];
    NSString *gotRange = [r valueForHTTPHeaderField:@"Content-Range"];
    CHECK((r.statusCode == 206 && [gotRange isEqualToString:expectRange]), @"open range headers %ld %@", (long)r.statusCode, gotRange);
    CHECK([SHA(full) isEqualToString:SHA(reference)], @"open range body matches (%lu bytes)", (unsigned long)full.length);
    printf("  open range through proxy: %.2fs, max threads %lld\n", CFAbsoluteTimeGetCurrent() - t0, [BTRStats.shared get:@"maxThreads"]);

    NSData *mid = Fetch(purl, @"GET", @"bytes=1000000-3000000", &r, session);
    CHECK(r.statusCode == 206 && [mid isEqualToData:[reference subdataWithRange:NSMakeRange(1000000, 2000001)]], @"middle range");
    NSData *tail = Fetch(purl, @"GET", [NSString stringWithFormat:@"bytes=%lu-%lu", kSize - 100, kSize + 5000], &r, session);
    CHECK(r.statusCode == 206 && [tail isEqualToData:[reference subdataWithRange:NSMakeRange(kSize - 100, 100)]], @"tail range clipped");
    NSData *small = Fetch(purl, @"GET", @"bytes=5-5", &r, session);
    CHECK(small.length == 1 && ((const uint8_t *)small.bytes)[0] == ((const uint8_t *)reference.bytes)[5], @"single byte");
    NSData *whole = Fetch(purl, @"GET", nil, &r, session);
    CHECK(r.statusCode == 200 && [whole isEqualToData:reference], @"no range -> 200 whole file");
    Fetch(purl, @"HEAD", nil, &r, session);
    CHECK(r.statusCode == 200 && [[r valueForHTTPHeaderField:@"Content-Length"] longLongValue] == (long long)kSize, @"HEAD");
    Fetch(purl, @"GET", [NSString stringWithFormat:@"bytes=%lu-", kSize + 10], &r, session);
    CHECK(r.statusCode == 416, @"beyond end -> 416 (%ld)", (long)r.statusCode);

    // Only refusing nodes: the player gets a 502 and falls back to its backup address.
    NSString *badOnly = [proxy proxyURLForPrimary:bad backups:@[]];
    Fetch(badOnly, @"GET", @"bytes=0-", &r, session);
    CHECK(r.statusCode == 502, @"all nodes refuse -> 502 (%ld)", (long)r.statusCode);
    CHECK([BTRStats.shared get:@"activeThreads"] >= 0, @"thread counter sane");
    for (NSDictionary *n in proxy.hostStatus) printf("  node %s: %s, %lld bytes\n", [n[@"host"] UTF8String], [n[@"state"] UTF8String], [n[@"bytes"] longLongValue]);
    CHECK([BTRProxyServer addressesFromProxyPath:@"/btr/x.m4s?u=bm90LWEtdXJs"] == nil, @"rejects non-media address");

    // A player that seeks closes the connection: every download of that request must stop.
    NSString *slowOnly = [proxy proxyURLForPrimary:slow backups:@[]];
    NSMutableArray *tasks = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:slowOnly]];
        [req setValue:[NSString stringWithFormat:@"bytes=%d-", i * 1000000] forHTTPHeaderField:@"Range"];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
        [tasks addObject:task];
        [task resume];
    }
    [NSThread sleepForTimeInterval:0.6];
    for (NSURLSessionDataTask *task in tasks) [task cancel];
    int64_t active = -1;
    for (int i = 0; i < 40 && active != 0; i++) { [NSThread sleepForTimeInterval:0.1]; active = [BTRStats.shared get:@"activeThreads"]; }
    CHECK(active == 0, @"downloads stop after the player disconnects (active %lld)", active);

    // Parallel requests through the slow node still return correct bytes.
    dispatch_group_t group = dispatch_group_create();
    __block int good = 0;
    NSLock *lock = [NSLock new];
    for (int i = 0; i < 4; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
            NSUInteger from = (NSUInteger)i * 1500000;
            NSData *got = Fetch(slowOnly, @"GET", [NSString stringWithFormat:@"bytes=%lu-%lu", from, from + 1499999], NULL, session);
            if ([got isEqualToData:[reference subdataWithRange:NSMakeRange(from, 1500000)]]) { [lock lock]; good++; [lock unlock]; }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    CHECK(good == 4, @"parallel requests correct (%d/4)", good);
}

@interface TestDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) dispatch_semaphore_t sem;
@property (nonatomic) NSInteger chunks;
@end
@implementation TestDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data { [self.data appendData:data]; self.chunks++; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { dispatch_semaphore_signal(self.sem); }
@end

static void TestHooks(void) {
    BTRSettings.shared.enabled = YES;
    BTRSettings.shared.accelerateAudio = NO;
    BTRInstallHooks();
    NSString *prefix = [NSString stringWithFormat:@"http://127.0.0.1:%u/btr/", BTRProxyServer.shared.port];
    NSString *api = [NSString stringWithFormat:@"http://127.0.0.1:%u/x/player/playurl?bvid=BV1", gOK];

    // Completion handler path.
    NSData *body = Fetch(api, @"GET", nil, NULL, NSURLSession.sharedSession);
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSString *video = json[@"data"][@"dash"][@"video"][0][@"base_url"];
    CHECK([video hasPrefix:prefix], @"completion path rewritten: %@", video);
    CHECK(![json[@"data"][@"dash"][@"audio"][0][@"base_url"] hasPrefix:prefix], @"audio left alone by default");
    NSArray *decoded = [BTRProxyServer addressesFromProxyPath:[video substringFromIndex:[video rangeOfString:@"/btr/"].location]];
    CHECK(decoded.count == 2 && [decoded[1] containsString:@"localhost"], @"proxy url carries backups: %@", decoded);

    // Delegate path (AFNetworking style).
    TestDelegate *d = [TestDelegate new];
    d.data = [NSMutableData data];
    d.sem = dispatch_semaphore_create(0);
    NSURLSession *ds = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:d delegateQueue:nil];
    [[ds dataTaskWithURL:[NSURL URLWithString:api]] resume];
    dispatch_semaphore_wait(d.sem, DISPATCH_TIME_FOREVER);
    json = [NSJSONSerialization JSONObjectWithData:d.data options:0 error:nil];
    CHECK([json[@"data"][@"dash"][@"video"][0][@"base_url"] hasPrefix:prefix], @"delegate path rewritten (%ld chunks)", (long)d.chunks);
    [ds finishTasksAndInvalidate];

    // gRPC over POST, delegate path, gzip frame.
    TestDelegate *g = [TestDelegate new];
    g.data = [NSMutableData data];
    g.sem = dispatch_semaphore_create(0);
    NSURLSession *gs = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:g delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/bilibili.app.playerunite.v1.Player/PlayViewUnite", gOK]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/grpc" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSData dataWithBytes:"\x00\x00\x00\x00\x00" length:5];
    [[gs dataTaskWithRequest:req] resume];
    dispatch_semaphore_wait(g.sem, DISPATCH_TIME_FOREVER);
    const uint8_t *p = g.data.bytes;
    BOOL framed = g.data.length > 5 && p[0] == 1;
    NSData *plain = framed ? [BTRRewriter gzipInflate:[g.data subdataWithRange:NSMakeRange(5, g.data.length - 5)]] : nil;
    NSData *dash = Sub(Sub(Sub(plain, 1), 5), 2);
    CHECK([Str(Sub(dash, 1)) hasPrefix:prefix], @"grpc delegate path rewritten: %@", Str(Sub(dash, 1)));
    CHECK([Str(Sub(Sub(Sub(plain, 1), 6), 2)) hasPrefix:@"http://127.0.0.1:"] && ![Str(Sub(Sub(Sub(plain, 1), 6), 2)) hasPrefix:prefix], @"grpc audio untouched");
    [gs finishTasksAndInvalidate];

    // The rewritten address really plays through the proxy.
    NSHTTPURLResponse *r = nil;
    NSData *head = Fetch(Str(Sub(dash, 1)), @"GET", @"bytes=0-1023", &r, NSURLSession.sharedSession);
    CHECK(r.statusCode == 206 && head.length == 1024, @"rewritten address serves media");

    // Disabled: nothing is touched.
    BTRSettings.shared.enabled = NO;
    body = Fetch(api, @"GET", nil, NULL, NSURLSession.sharedSession);
    json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    CHECK(![json[@"data"][@"dash"][@"video"][0][@"base_url"] hasPrefix:prefix], @"disabled -> untouched");
    BTRSettings.shared.enabled = YES;
}

static void TestModelHooks(void) {
    BTRSettings.shared.enabled = YES;
    BTRSettings.shared.accelerateAudio = NO;
    BTRInstallHooks(); // also installs the model hooks (idempotent)
    NSString *prefix = [NSString stringWithFormat:@"http://127.0.0.1:%u/btr/", BTRProxyServer.shared.port];

    CHECK(BTRIsPlayReplyClassName("BAPIAppPlayeruniteV1PlayViewUniteReply"), @"PlayViewUniteReply matches");
    CHECK(BTRIsPlayReplyClassName("BAPIAppPlayurlV1PlayURLReply"), @"PlayURLReply matches");
    CHECK(BTRIsPlayReplyClassName("BAPIPgcGatewayPlayerV2PlayViewReply"), @"PlayViewReply matches");
    CHECK(!BTRIsPlayReplyClassName("BAPIPgcGatewayPlayerV1LivePlayViewReply"), @"live reply ignored");
    CHECK(!BTRIsPlayReplyClassName("BAPIAppViewV1ViewReply") && !BTRIsPlayReplyClassName(NULL), @"other replies ignored");

    // gRPC-ObjC hands the decoded frame payload to +parseFromData:, i.e. -initWithData:extensionRegistry:error:.
    NSString *v = nil;
    NSData *reply = SampleProto(&v);
    int64_t pbBefore = [BTRStats.shared get:@"pbReplies"];
    BAPIAppPlayeruniteV1PlayViewUniteReply *m = [[BAPIAppPlayeruniteV1PlayViewUniteReply alloc] initWithData:reply extensionRegistry:nil error:NULL];
    NSData *dash = Sub(Sub(Sub(m.raw, 1), 5), 2);
    CHECK([Str(Sub(dash, 1)) hasPrefix:prefix], @"PlayViewUniteReply rewritten at protobuf level: %@", Str(Sub(dash, 1)));
    CHECK(m.merges == 1 && [BTRStats.shared get:@"pbReplies"] == pbBefore + 1, @"rewritten once, not again by the nested merge");
    NSArray *decoded = [BTRProxyServer addressesFromProxyPath:[Str(Sub(dash, 1)) substringFromIndex:prefix.length - 5]];
    CHECK(decoded.count == 3 && [decoded[0] isEqualToString:v], @"proxy url keeps primary + both backups: %@", decoded);
    CHECK(Strings(dash, 2).count == 2 && [Str(Strings(dash, 2)[0]) hasPrefix:@"https://upos-sz-mirrorcos"], @"backups untouched");
    CHECK([Sub(Sub(m.raw, 1), 6) isEqualToData:Sub(Sub(reply, 1), 6)], @"audio untouched by default");

    // mergeFromData: directly (some code paths parse into an existing message).
    BAPIPgcGatewayPlayerV2PlayViewReply *pgc = [BAPIPgcGatewayPlayerV2PlayViewReply new];
    [pgc mergeFromData:reply extensionRegistry:nil];
    CHECK([Str(Sub(Sub(Sub(Sub(pgc.raw, 1), 5), 2), 1)) hasPrefix:prefix], @"PlayViewReply rewritten via mergeFromData");

    // Other messages are byte-identical.
    BAPIAppViewV1ViewReply *other = [[BAPIAppViewV1ViewReply alloc] initWithData:reply extensionRegistry:nil error:NULL];
    CHECK([other.raw isEqualToData:reply], @"unrelated reply untouched");
    BAPIPgcGatewayPlayerV1LivePlayViewReply *live = [[BAPIPgcGatewayPlayerV1LivePlayViewReply alloc] initWithData:reply extensionRegistry:nil error:NULL];
    CHECK([live.raw isEqualToData:reply], @"live reply untouched");

    // Disabled: nothing changes.
    BTRSettings.shared.enabled = NO;
    BAPIAppPlayeruniteV1PlayViewUniteReply *off = [[BAPIAppPlayeruniteV1PlayViewUniteReply alloc] initWithData:reply extensionRegistry:nil error:NULL];
    CHECK([off.raw isEqualToData:reply], @"disabled -> protobuf untouched");
    BTRSettings.shared.enabled = YES;

    // Player fallback: an address that did not go through BTR is rewritten when the player gets it.
    NSString *cdn = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?deadline=9";
    NSString *audio = @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30280.m4s?deadline=9";
    IJKDashStreamItem *item = [[IJKDashStreamItem alloc] initWithStreamId:1 bandwidth:2 baseUrl:cdn fileSize:3 streamType:0 codecType:7];
    CHECK([item.baseUrl hasPrefix:prefix], @"DashStreamItem init rewritten: %@", item.baseUrl);
    item.baseUrl = cdn;
    CHECK([item.baseUrl hasPrefix:prefix], @"DashStreamItem setter rewritten");
    NSString *already = item.baseUrl;
    item.baseUrl = already;
    CHECK([item.baseUrl isEqualToString:already], @"already proxied address left alone");
    item.baseUrl = audio;
    CHECK([item.baseUrl isEqualToString:audio], @"audio left alone by default");
    item.baseUrl = @"https://example.com/a.m4s";
    CHECK([item.baseUrl isEqualToString:@"https://example.com/a.m4s"], @"non-Bilibili address left alone");

    NSString *backup = @"https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s?deadline=9";
    IJKDashStreamBridge *bridge = [[IJKDashStreamBridge alloc] initWithMediaType:1 codecId:7 qn:80 bandwidth:1 url:[NSURL URLWithString:cdn] backupUrls:@[ backup ]];
    CHECK([bridge.url isKindOfClass:NSURL.class] && [bridge.url.absoluteString hasPrefix:prefix], @"DashStreamBridge keeps NSURL type and is rewritten: %@", bridge.url);
    NSArray *bd = [BTRProxyServer addressesFromProxyPath:[bridge.url.absoluteString substringFromIndex:prefix.length - 5]];
    CHECK(bd.count == 2 && [bd[1] isEqualToString:backup], @"bridge backups carried: %@", bd);

    // Observe-only hooks never change what the player opens.
    IJKMediaPlayerItem *pi = [IJKMediaPlayerItem new];
    pi.url = cdn;
    CHECK([pi.url isEqualToString:cdn], @"PlayerItem.url observed, not changed");
    IJKMediaUrlOpenData *od = [IJKMediaUrlOpenData new];
    od.url = already;
    [pi willOpenUrl:od];
    CHECK(pi.opened == od && [od.url isEqualToString:already], @"willOpenUrl observed, not changed");
    IJKMediaAssetStreamSegment *seg = [[IJKMediaAssetStreamSegment alloc] initWithUrl:42];
    CHECK(seg.value == 42, @"hook with an unexpected signature is not installed");

    NSString *diag = [BTRDiag dump];
    CHECK([diag containsString:@"BAPIAppPlayeruniteV1PlayViewUniteReply"], @"diagnostics list protobuf replies");
    CHECK([diag containsString:@"willOpenUrl 已走 BTR"], @"diagnostics show the player opening a BTR address");
    CHECK([diag containsString:@"NSURLSession 请求"], @"diagnostics list NSURLSession requests");
    CHECK(![diag containsString:@"deadline="] && ![diag containsString:@"bvid="], @"diagnostics drop query strings");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: BTRTests okPort slowPort badPort\n"); return 2; }
        gOK = (uint16_t)atoi(argv[1]);
        gSlow = (uint16_t)atoi(argv[2]);
        gBad = (uint16_t)atoi(argv[3]);
        TestCandidates();
        TestJSON();
        TestProtobuf();
        TestProxy();
        TestHooks();
        TestModelHooks();
        printf("%d passed, %d failed\n", passes, failures);
        return failures ? 1 : 0;
    }
}
