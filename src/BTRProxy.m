#import "BTRProxy.h"
#import "BTRCore.h"
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t kPreferredPort = 47823;
static const int64_t kFirstPieceBytes = 256 * 1024;
static const int64_t kWindowBytes = 48 * 1024 * 1024;
static const int kMaxPieceFailures = 6;
static const double kAttemptTimeout = 20.0;
static const double kMeasurementTTL = 90.0;
static const void *kAttemptKey = &kAttemptKey;

static double Now(void) { return CFAbsoluteTimeGetCurrent(); }

#pragma mark - Content-Range

typedef struct { int64_t start, end, total; BOOL ok; } BTRContentRange;

static BTRContentRange ParseContentRange(NSString *value) {
    BTRContentRange r = { 0, 0, -1, NO };
    if (!value) return r;
    long long s, e, t;
    char totalBuf[32] = {0};
    if (sscanf(value.UTF8String, "bytes %lld-%lld/%31s", &s, &e, totalBuf) < 3 || s < 0 || e < s) return r;
    r.start = s; r.end = e;
    if (strcmp(totalBuf, "*") != 0) {
        if (sscanf(totalBuf, "%lld", &t) != 1 || t <= e) return r;
        r.total = t;
    }
    r.ok = YES;
    return r;
}

#pragma mark - Host book (shared by all transfers)

@interface BTRHostInfo : NSObject
@property (nonatomic, copy) NSString *host;
@property (nonatomic) double bps, lastMeasured, blockedUntil;
@property (nonatomic) int failures, zeroStrikes, inflight;
@property (nonatomic) BOOL banned, everServed;
@property (nonatomic) int64_t bytes;
@end
@implementation BTRHostInfo
@end

@interface BTRHostBook : NSObject
@end

@implementation BTRHostBook {
    NSMutableDictionary<NSString *, BTRHostInfo *> *_hosts;
    NSLock *_lock;
    NSUInteger _cursor;
}

- (instancetype)init {
    if ((self = [super init])) { _hosts = [NSMutableDictionary dictionary]; _lock = [NSLock new]; }
    return self;
}

- (BTRHostInfo *)infoFor:(NSString *)url {
    NSString *h = [BTRMedia hostOf:url] ?: @"?";
    BTRHostInfo *i = _hosts[h];
    if (!i) { i = [BTRHostInfo new]; i.host = h; _hosts[h] = i; }
    return i;
}

static BOOL Fresh(BTRHostInfo *i, double now) { return i.bps > 0 && now - i.lastMeasured < kMeasurementTTL; }

// Picks the address for the next piece and counts it as in flight. Untested nodes get one
// trial piece each (BTR's warm-up and exploration slot); after that the measured nodes are
// loaded in proportion to their speed: the one expected to finish another piece first wins.
- (NSString *)pickFrom:(NSArray<NSString *> *)candidates exclude:(NSSet<NSString *> *)exclude {
    [_lock lock];
    double now = Now();
    NSMutableArray<NSString *> *pool = [NSMutableArray array];
    for (int pass = 0; pass < 3 && !pool.count; pass++) {
        for (NSString *u in candidates) {
            if ([exclude containsObject:u]) continue;
            BTRHostInfo *i = [self infoFor:u];
            if (pass < 2 && i.banned) continue;
            if (pass < 1 && i.blockedUntil > now) continue;
            [pool addObject:u];
        }
    }
    NSString *chosen = nil;
    if (pool.count) {
        NSUInteger n = pool.count, offset = _cursor++ % n;
        for (NSUInteger k = 0; k < n && !chosen; k++) {
            NSString *u = pool[(offset + k) % n];
            BTRHostInfo *i = [self infoFor:u];
            if (!Fresh(i, now) && i.inflight == 0) chosen = u;
        }
        if (!chosen) {
            // No idle untested node: the fastest measured one, else the least busy.
            NSString *best = nil;
            double bs = INFINITY;
            for (NSString *u in pool) {
                BTRHostInfo *i = [self infoFor:u];
                if (!Fresh(i, now)) continue;
                double score = (i.inflight + 1) / i.bps;
                if (score < bs) { bs = score; best = u; }
            }
            if (!best) {
                int least = INT_MAX;
                for (NSString *u in pool) {
                    BTRHostInfo *i = [self infoFor:u];
                    if (i.inflight < least) { least = i.inflight; best = u; }
                }
            }
            chosen = best;
        }
        [self infoFor:chosen].inflight += 1;
    }
    [_lock unlock];
    return chosen;
}

- (double)speedFor:(NSString *)url {
    [_lock lock];
    BTRHostInfo *i = [self infoFor:url];
    double r = Fresh(i, Now()) ? i.bps : 0;
    [_lock unlock];
    return r;
}

- (void)finished:(NSString *)url bytes:(int64_t)bytes seconds:(double)seconds ok:(BOOL)ok status:(NSInteger)status cancelled:(BOOL)cancelled {
    [_lock lock];
    BTRHostInfo *i = [self infoFor:url];
    i.inflight = MAX(0, i.inflight - 1);
    i.bytes += bytes;
    double now = Now();
    double bps = (bytes >= 128 * 1024 && seconds > 0.01) ? bytes / seconds : 0;
    if (bps > 0) {
        i.bps = i.bps > 0 && Fresh(i, now) ? i.bps * 0.65 + bps * 0.35 : bps;
        i.lastMeasured = now;
    }
    if (ok) {
        i.failures = 0;
        i.blockedUntil = 0;
        i.everServed = YES;
    } else if (!cancelled) {
        i.failures += 1;
        i.blockedUntil = now + MIN(60.0, 3.0 * (1 << MIN(i.failures, 4)));
        BOOL refused = status >= 400 && status < 500;
        // A 4xx from a node that serves other addresses blames the address, not the node.
        if (bytes == 0 && !(refused && i.everServed)) {
            i.zeroStrikes += 1;
            if (i.zeroStrikes >= 2 && !i.banned) {
                i.banned = YES;
                BTRLog(@"已停用 CDN 节点 %@：两次没有返回任何数据", i.host);
            }
        }
    }
    [_lock unlock];
}

- (void)resetBans {
    [_lock lock];
    for (BTRHostInfo *i in _hosts.allValues) { i.banned = NO; i.zeroStrikes = 0; i.failures = 0; i.blockedUntil = 0; }
    [_lock unlock];
}

- (NSArray<NSDictionary *> *)status {
    [_lock lock];
    double now = Now();
    NSMutableArray *out = [NSMutableArray array];
    for (BTRHostInfo *i in _hosts.allValues) {
        NSString *state = i.banned ? @"停用" : i.blockedUntil > now ? @"冷却" : Fresh(i, now) ? @"正常" : i.everServed ? @"待测" : @"未测";
        [out addObject:@{ @"host": i.host, @"state": state, @"bps": @(Fresh(i, now) ? i.bps : 0), @"bytes": @(i.bytes), @"inflight": @(i.inflight) }];
    }
    [_lock unlock];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"bytes"] compare:a[@"bytes"]]; }];
    return out;
}

@end

#pragma mark - Transfer model

@class BTRTransfer, BTRPiece;

@interface BTRAttempt : NSObject
@property (nonatomic, weak) BTRTransfer *transfer;
@property (nonatomic, strong) BTRPiece *piece;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic) double started;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSString *contentRange, *contentType;
@property (nonatomic) BOOL finished, cancelledByUs, rejected;
@end
@implementation BTRAttempt
@end

@interface BTRPiece : NSObject
@property (nonatomic) int64_t start, end;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) BOOL sent;
@property (nonatomic, strong) NSMutableArray<BTRAttempt *> *live;
@property (nonatomic, strong) NSMutableSet<NSString *> *failedURLs;
@property (nonatomic) int failures;
@end
@implementation BTRPiece
- (instancetype)init {
    if ((self = [super init])) { _live = [NSMutableArray array]; _failedURLs = [NSMutableSet set]; }
    return self;
}
@end

@interface BTRTransfer : NSObject
@property (nonatomic, strong) NSCondition *cond;
@property (nonatomic, copy) NSArray<NSString *> *candidates;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSString *cacheKey, *contentType, *error;
@property (nonatomic) NSInteger threads;
@property (nonatomic) int64_t chunk, rangeStart, rangeEnd, total;
@property (nonatomic, strong) NSMutableArray<BTRPiece *> *pieces;
@property (nonatomic, strong) NSMutableSet<NSString *> *refusedURLs;
@property (nonatomic) NSUInteger sendIndex;
@property (nonatomic) int live;
@property (nonatomic) BOOL failed, cancelled;
@end
@implementation BTRTransfer
@end

#pragma mark - Server

@interface BTRProxyServer () <NSURLSessionDataDelegate>
@end

@implementation BTRProxyServer {
    int _listenFD;
    uint16_t _port;
    BOOL _acceptThreadStarted;
    NSURLSession *_session;
    BTRHostBook *_book;
    NSMutableDictionary<NSString *, NSNumber *> *_totals;
    NSLock *_totalsLock;
}

+ (instancetype)shared {
    static BTRProxyServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BTRProxyServer new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _book = [BTRHostBook new];
        _totals = [NSMutableDictionary dictionary];
        _totalsLock = [NSLock new];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.HTTPMaximumConnectionsPerHost = 16;
        c.timeoutIntervalForRequest = 8;  // no data for 8 s: the node stalled
        c.timeoutIntervalForResource = 60;
        c.URLCache = nil;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        c.HTTPShouldSetCookies = NO;
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 1;
        q.name = @"BTR.fetch";
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:q];
    }
    return self;
}

- (uint16_t)port { return _port; }

- (void)resetBans { [_book resetBans]; }

- (NSArray<NSDictionary *> *)hostStatus { return [_book status]; }

#pragma mark Proxy URLs

static NSString *B64URL(NSString *s) {
    NSString *b = [[s dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    b = [b stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    b = [b stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [b stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *FromB64URL(NSString *s) {
    NSMutableString *b = [[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [b replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b.length)];
    while (b.length % 4) [b appendString:@"="];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b options:0];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

- (NSString *)proxyURLForPrimary:(NSString *)primary backups:(NSArray<NSString *> *)backups {
    if (!_port) return nil;
    NSURLComponents *orig = [NSURLComponents componentsWithString:primary];
    NSString *name = orig.percentEncodedPath.lastPathComponent ?: @"media.m4s";
    NSMutableString *u = [NSMutableString stringWithFormat:@"http://127.0.0.1:%u/btr/%@?u=%@", _port, name, B64URL(primary)];
    NSMutableArray<NSString *> *seen = [NSMutableArray arrayWithObject:primary];
    for (NSString *b in backups) {
        if (![BTRMedia isMediaURL:b] || [seen containsObject:b] || seen.count > 6) continue;
        [seen addObject:b];
        [u appendFormat:@"&b=%@", B64URL(b)];
    }
    for (NSURLQueryItem *item in orig.queryItems)
        if ([item.name isEqualToString:@"deadline"] && item.value) [u appendFormat:@"&deadline=%@", item.value];
    return u;
}

+ (NSArray<NSString *> *)addressesFromProxyPath:(NSString *)pathAndQuery {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:pathAndQuery]];
    if (![c.path hasPrefix:@"/btr/"]) return nil;
    NSString *primary = nil;
    NSMutableArray *backups = [NSMutableArray array];
    for (NSURLQueryItem *item in c.queryItems) {
        NSString *v = item.value ? FromB64URL(item.value) : nil;
        if (!v) continue;
        if ([item.name isEqualToString:@"u"]) primary = v;
        else if ([item.name isEqualToString:@"b"]) [backups addObject:v];
    }
    if (![BTRMedia isMediaURL:primary]) return nil;
    return [@[ primary ] arrayByAddingObjectsFromArray:backups];
}

#pragma mark Listening

- (int)bindPort:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in a = {0};
    a.sin_len = sizeof(a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(fd, 64) != 0) { close(fd); return -1; }
    socklen_t l = sizeof(a);
    getsockname(fd, (struct sockaddr *)&a, &l);
    _port = ntohs(a.sin_port);
    return fd;
}

- (BOOL)start {
    @synchronized(self) {
        if (_listenFD >= 0) return YES;
        int fd = [self bindPort:_port ?: kPreferredPort];
        if (fd < 0 && !_port) fd = [self bindPort:0];
        if (fd < 0) { BTRLog(@"代理无法监听端口：%s", strerror(errno)); return NO; }
        _listenFD = fd;
        BTRLog(@"本地代理已启动：127.0.0.1:%u", _port);
        if (!_acceptThreadStarted) {
            _acceptThreadStarted = YES;
            NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
            t.name = @"BTR.accept";
            [t start];
        }
        return YES;
    }
}

- (void)acceptLoop {
    for (;;) {
        @autoreleasepool {
            int lfd;
            @synchronized(self) { lfd = _listenFD; }
            if (lfd < 0) {
                usleep(500 * 1000);
                @synchronized(self) {
                    // iOS may reclaim the listening socket while the app is suspended. The
                    // rewritten addresses carry the port, so bind the same one again.
                    int fd = [self bindPort:_port];
                    if (fd >= 0) { _listenFD = fd; BTRLog(@"本地代理已重新监听 %u", _port); }
                }
                continue;
            }
            int c = accept(lfd, NULL, NULL);
            if (c < 0) {
                if (errno == EINTR) continue;
                BTRLog(@"代理 accept 失败（%s），重新监听", strerror(errno));
                @synchronized(self) { if (_listenFD == lfd) { close(lfd); _listenFD = -1; } }
                continue;
            }
            int one = 1;
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(handleConnection:) object:@(c)];
            t.name = @"BTR.conn";
            [t start];
        }
    }
}

#pragma mark Connection

static BOOL SendAll(int fd, const void *buf, size_t len, BTRTransfer *transfer) {
    const uint8_t *p = buf;
    while (len) {
        if (transfer.cancelled) return NO;
        struct pollfd pfd = { fd, POLLOUT, 0 };
        int r = poll(&pfd, 1, 1000);
        if (r < 0 && errno != EINTR) return NO;
        if (r <= 0) continue; // the player is not reading yet (its buffer is full): keep waiting
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return NO;
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            return NO;
        }
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static BOOL ClientGone(int fd) {
    struct pollfd pfd = { fd, POLLIN, 0 };
    if (poll(&pfd, 1, 0) <= 0) return NO;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return YES;
    char b;
    ssize_t n = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    return n == 0;
}

static void SendSimple(int fd, int code, NSString *reason) {
    NSString *s = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", code, reason];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, d.bytes, d.length, 0);
}

- (void)handleConnection:(NSNumber *)fdNumber {
    int fd = fdNumber.intValue;
    @autoreleasepool {
        struct timeval tv = { 15, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        NSMutableData *buf = [NSMutableData data];
        char tmp[4096];
        NSRange end = NSMakeRange(NSNotFound, 0);
        NSData *crlf = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        while (buf.length < 32768) {
            ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
            end = [buf rangeOfData:crlf options:0 range:NSMakeRange(0, buf.length)];
            if (end.location != NSNotFound) break;
        }
        if (end.location == NSNotFound) { close(fd); return; }
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
        NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        if (requestLine.count < 2) { SendSimple(fd, 400, @"Bad Request"); close(fd); return; }
        NSString *method = requestLine[0].uppercaseString;
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *k = [[lines[i] substringToIndex:colon.location] lowercaseString];
            NSString *v = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            headers[k] = v;
        }
        if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]) { SendSimple(fd, 405, @"Method Not Allowed"); close(fd); return; }
        NSArray<NSString *> *addresses = [BTRProxyServer addressesFromProxyPath:requestLine[1]];
        if (!addresses) { SendSimple(fd, 404, @"Not Found"); close(fd); return; }
        [self serve:fd method:method headers:headers addresses:addresses];
        close(fd);
    }
}

- (void)serve:(int)fd method:(NSString *)method headers:(NSDictionary<NSString *, NSString *> *)headers addresses:(NSArray<NSString *> *)addresses {
    BTRSettings *settings = BTRSettings.shared;
    NSString *primary = addresses.firstObject;
    NSArray *backups = [addresses subarrayWithRange:NSMakeRange(1, addresses.count - 1)];

    int64_t start = 0, end = -1;
    BOOL hasRange = NO;
    NSString *range = headers[@"range"];
    if (range.length) {
        long long s = -1, e = -1;
        int n = sscanf(range.UTF8String, "bytes=%lld-%lld", &s, &e);
        if (n >= 1 && s >= 0 && (n == 1 || e >= s)) { start = s; end = n == 2 ? e : -1; hasRange = YES; }
        else if (range.length) { SendSimple(fd, 416, @"Range Not Satisfiable"); return; } // suffix ranges are not used by players here
    }

    BTRTransfer *t = [BTRTransfer new];
    t.cond = [NSCondition new];
    NSMutableArray<NSString *> *candidates = [[BTRMedia candidatesForPrimary:primary backups:backups mode:settings.mode custom:settings.customHosts] mutableCopy];
    // Like BTR's startup candidates, the addresses Bilibili handed out stay in the race (last),
    // except in the custom mode, which keeps to the picked servers.
    if (settings.mode != BTRCDNModeCustom)
        for (NSString *u in addresses) if ([BTRMedia isMediaURL:u] && ![candidates containsObject:u]) [candidates addObject:u];
    t.candidates = candidates;
    NSMutableDictionary *fwd = [NSMutableDictionary dictionary];
    if (headers[@"user-agent"]) fwd[@"User-Agent"] = headers[@"user-agent"];
    if (headers[@"referer"]) fwd[@"Referer"] = headers[@"referer"];
    t.headers = fwd;
    t.cacheKey = [NSURLComponents componentsWithString:primary].percentEncodedPath ?: primary;
    t.threads = settings.threads;
    t.chunk = (int64_t)settings.chunkKB * 1024;
    t.rangeStart = start;
    t.rangeEnd = end;
    [_totalsLock lock];
    NSNumber *cached = _totals[t.cacheKey];
    [_totalsLock unlock];
    t.total = cached ? cached.longLongValue : -1;
    t.pieces = [NSMutableArray array];
    t.refusedURLs = [NSMutableSet set];
    if (t.total >= 0 && start >= t.total) {
        NSString *s = [NSString stringWithFormat:@"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%lld\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", t.total];
        send(fd, s.UTF8String, strlen(s.UTF8String), 0);
        return;
    }
    [BTRStats.shared add:@"proxyRequests" value:1];

    NSData *first = [self waitForPiece:0 transfer:t fd:fd];
    if (!first) {
        BTRLog(@"首段下载失败，交回播放器使用备用地址：%@", t.error ?: @"连接已关闭");
        [BTRStats.shared add:@"fallbacks" value:1];
        if (!t.cancelled) SendSimple(fd, 502, @"Bad Gateway");
        [self cancelTransfer:t];
        return;
    }
    [t.cond lock];
    int64_t total = t.total;
    int64_t last = (end < 0 || end >= total) ? total - 1 : end;
    NSString *type = t.contentType ?: ([BTRMedia isAudioURL:primary] ? @"audio/mp4" : @"video/mp4");
    [t.cond unlock];
    int64_t length = last - start + 1;
    NSMutableString *h = [NSMutableString string];
    if (hasRange) {
        [h appendFormat:@"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes %lld-%lld/%lld\r\n", start, last, total];
    } else {
        [h appendString:@"HTTP/1.1 200 OK\r\n"];
    }
    [h appendFormat:@"Content-Type: %@\r\nContent-Length: %lld\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\nX-BTR: %@\r\n\r\n", type, length, BTR_VERSION];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!SendAll(fd, hd.bytes, hd.length, t)) { [self cancelTransfer:t]; return; }
    if ([method isEqualToString:@"HEAD"]) { [self cancelTransfer:t]; return; }

    int64_t sent = 0;
    NSData *piece = first;
    NSUInteger index = 0;
    while (piece) {
        size_t n = (size_t)MIN((int64_t)piece.length, length - sent);
        if (!SendAll(fd, piece.bytes, n, t)) break;
        sent += n;
        [BTRStats.shared add:@"bytesServed" value:(int64_t)n];
        if (sent >= length) break;
        piece = [self waitForPiece:++index transfer:t fd:fd];
    }
    if (sent < length && !t.cancelled) BTRLog(@"传输中断：已交付 %@ / %@（%@）", [BTRMedia formatBytes:sent], [BTRMedia formatBytes:length], t.error ?: @"播放器关闭了连接");
    [self cancelTransfer:t];
}

#pragma mark Scheduling (called with t.cond locked)

- (int64_t)effectiveEnd:(BTRTransfer *)t {
    if (t.total < 0) return t.rangeEnd;
    return t.rangeEnd < 0 ? t.total - 1 : MIN(t.rangeEnd, t.total - 1);
}

- (BTRPiece *)pieceAt:(NSUInteger)index transfer:(BTRTransfer *)t {
    while (t.pieces.count <= index) {
        BTRPiece *p = [BTRPiece new];
        int64_t limit = [self effectiveEnd:t];
        if (!t.pieces.count) {
            p.start = t.rangeStart;
            p.end = t.rangeStart + kFirstPieceBytes - 1;
        } else {
            if (limit < 0) return nil; // size unknown until the first piece arrives
            p.start = t.pieces.lastObject.end + 1;
            p.end = p.start + t.chunk - 1;
        }
        if (limit >= 0) {
            if (p.start > limit) return nil;
            p.end = MIN(p.end, limit);
        }
        [t.pieces addObject:p];
    }
    return t.pieces[index];
}

- (NSUInteger)windowFor:(BTRTransfer *)t {
    NSUInteger byBytes = (NSUInteger)MAX(4, kWindowBytes / MAX(t.chunk, 1));
    return MIN((NSUInteger)t.threads + 2, byBytes);
}

- (void)schedule:(BTRTransfer *)t {
    if (t.failed || t.cancelled) return;
    NSUInteger window = [self windowFor:t];
    while (t.live < t.threads) {
        BTRPiece *next = nil;
        for (NSUInteger i = t.sendIndex; i < t.sendIndex + window; i++) {
            BTRPiece *p = [self pieceAt:i transfer:t];
            if (!p) break;
            if (!p.data && !p.sent && !p.live.count) { next = p; break; }
        }
        if (!next || ![self startAttemptFor:next transfer:t hedge:NO]) break;
        // The first piece decides how soon playback starts: race two nodes for it.
        if (next == t.pieces.firstObject && t.candidates.count > 1) [self startAttemptFor:next transfer:t hedge:YES];
    }
}

- (BOOL)startAttemptFor:(BTRPiece *)p transfer:(BTRTransfer *)t hedge:(BOOL)hedge {
    NSMutableSet *exclude = [t.refusedURLs mutableCopy];
    for (BTRAttempt *a in p.live) [exclude addObject:a.url];
    NSMutableSet *withFailed = [exclude mutableCopy];
    [withFailed unionSet:p.failedURLs];
    NSString *url = [_book pickFrom:t.candidates exclude:withFailed];
    if (!url && !hedge) url = [_book pickFrom:t.candidates exclude:exclude];
    if (!url) {
        if (!p.live.count && !hedge) { t.failed = YES; t.error = t.error ?: @"没有可用的下载地址"; }
        return NO;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", p.start, p.end] forHTTPHeaderField:@"Range"];
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [t.headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
    BTRAttempt *a = [BTRAttempt new];
    a.transfer = t;
    a.piece = p;
    a.url = url;
    a.data = [NSMutableData dataWithCapacity:(NSUInteger)(p.end - p.start + 1)];
    a.started = Now();
    a.task = [_session dataTaskWithRequest:req];
    objc_setAssociatedObject(a.task, kAttemptKey, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [p.live addObject:a];
    t.live += 1;
    [BTRStats.shared add:@"activeThreads" value:1];
    [BTRStats.shared setMax:@"maxThreads" value:[BTRStats.shared get:@"activeThreads"]];
    if (hedge) [BTRStats.shared add:@"hedges" value:1];
    [a.task resume];
    __weak BTRAttempt *weakA = a;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAttemptTimeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BTRAttempt *s = weakA;
        if (s && !s.finished) [s.task cancel];
    });
    return YES;
}

// A piece that is late gets a second copy from another node; the first to arrive wins.
- (void)maybeHedge:(BTRPiece *)p transfer:(BTRTransfer *)t {
    if (p.data || p.live.count != 1 || t.live >= t.threads + 4) return;
    BTRAttempt *a = p.live.firstObject;
    int64_t len = p.end - p.start + 1;
    if ((int64_t)a.data.length * 10 >= len * 8) return;
    double bps = [_book speedFor:a.url];
    double delay = bps > 0 ? MAX(1.5, 3.0 * len / bps) : 2.5;
    if (Now() - a.started < delay) return;
    [self startAttemptFor:p transfer:t hedge:YES];
}

- (NSData *)waitForPiece:(NSUInteger)index transfer:(BTRTransfer *)t fd:(int)fd {
    [t.cond lock];
    NSData *result = nil;
    for (;;) {
        if (t.cancelled || t.failed) break;
        t.sendIndex = index;
        BTRPiece *p = [self pieceAt:index transfer:t];
        if (!p) break;
        if (p.data) {
            result = p.data;
            p.data = nil;
            p.sent = YES;
            t.sendIndex = index + 1;
            [self schedule:t];
            break;
        }
        [self schedule:t];
        [self maybeHedge:p transfer:t];
        if (t.failed) break;
        [t.cond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        if (ClientGone(fd)) { t.cancelled = YES; break; }
    }
    [t.cond unlock];
    return result;
}

- (void)cancelTransfer:(BTRTransfer *)t {
    [t.cond lock];
    t.cancelled = YES;
    for (BTRPiece *p in t.pieces) {
        p.data = nil;
        for (BTRAttempt *a in p.live) { a.cancelledByUs = YES; [a.task cancel]; }
    }
    [t.cond unlock];
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BTRAttempt *a = objc_getAssociatedObject(task, kAttemptKey);
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    a.status = [http isKindOfClass:NSHTTPURLResponse.class] ? http.statusCode : 0;
    a.contentRange = [http isKindOfClass:NSHTTPURLResponse.class] ? [http valueForHTTPHeaderField:@"Content-Range"] : nil;
    a.contentType = [http isKindOfClass:NSHTTPURLResponse.class] ? [http valueForHTTPHeaderField:@"Content-Type"] : nil;
    BTRContentRange cr = ParseContentRange(a.contentRange);
    if (a.status != 206 || !cr.ok || cr.start != a.piece.start || cr.end > a.piece.end) {
        // Never accept a whole file or a misplaced range into the player.
        a.rejected = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    BTRAttempt *a = objc_getAssociatedObject(task, kAttemptKey);
    [a.data appendData:data];
    [BTRStats.shared add:@"bytesDownloaded" value:(int64_t)data.length];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    BTRAttempt *a = objc_getAssociatedObject(task, kAttemptKey);
    objc_setAssociatedObject(task, kAttemptKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!a) return;
    BTRTransfer *t = a.transfer;
    BTRPiece *p = a.piece;
    [BTRStats.shared add:@"activeThreads" value:-1];
    double seconds = Now() - a.started;
    if (!t) { [_book finished:a.url bytes:(int64_t)a.data.length seconds:seconds ok:NO status:a.status cancelled:YES]; return; }

    [t.cond lock];
    a.finished = YES;
    [p.live removeObject:a];
    t.live -= 1;
    BTRContentRange cr = ParseContentRange(a.contentRange);
    BOOL clipped = cr.ok && cr.end < p.end && cr.total > 0 && cr.end == cr.total - 1;
    BOOL valid = !error && !a.rejected && a.status == 206 && cr.ok && cr.start == p.start &&
                 (cr.end == p.end || clipped) && (int64_t)a.data.length == cr.end - cr.start + 1;
    if (valid) {
        [_book finished:a.url bytes:(int64_t)a.data.length seconds:seconds ok:YES status:a.status cancelled:NO];
        if (!p.data && !p.sent) {
            p.end = cr.end;
            p.data = a.data;
            if (cr.total > 0 && t.total < 0) {
                t.total = cr.total;
                [_totalsLock lock];
                if (_totals.count > 512) [_totals removeAllObjects];
                _totals[t.cacheKey] = @(cr.total);
                [_totalsLock unlock];
            }
            if (!t.contentType && a.contentType.length) t.contentType = a.contentType;
            for (BTRAttempt *other in p.live) { other.cancelledByUs = YES; [other.task cancel]; }
        }
    } else if (a.cancelledByUs || t.cancelled) {
        [_book finished:a.url bytes:(int64_t)a.data.length seconds:seconds ok:NO status:a.status cancelled:YES];
    } else {
        [_book finished:a.url bytes:(int64_t)a.data.length seconds:seconds ok:NO status:a.status cancelled:NO];
        [BTRStats.shared add:@"pieceFailures" value:1];
        if (a.status >= 400 && a.status < 500) [t.refusedURLs addObject:a.url];
        [p.failedURLs addObject:a.url];
        p.failures += 1;
        NSString *why = (error && !a.rejected) ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld，Content-Range %@", (long)a.status, a.contentRange ?: @"无"];
        BTRLog(@"一小段没下载下来：节点 %@，已收到 %@，原因：%@", [BTRMedia hostOf:a.url], [BTRMedia formatBytes:(int64_t)a.data.length], why);
        if (!p.data && !p.sent && !p.live.count && p.failures >= kMaxPieceFailures) {
            t.failed = YES;
            t.error = why;
        }
    }
    a.data = nil;
    a.piece = nil;
    [self schedule:t];
    [t.cond broadcast];
    [t.cond unlock];
}

@end
