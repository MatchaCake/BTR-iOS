#import "BTRRewriter.h"
#import "BTRCore.h"
#include <zlib.h>

#pragma mark - protobuf wire format helpers

typedef struct {
    uint32_t field;
    uint8_t wire;
    size_t tagStart;   // offset of the tag
    size_t valueStart; // offset of the value (after the length prefix for wire type 2)
    size_t valueLen;   // length for wire type 2
    size_t end;        // offset after the field
} BTRField;

static BOOL ReadVarint(const uint8_t *p, size_t len, size_t *pos, uint64_t *out) {
    uint64_t v = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (*pos >= len) return NO;
        uint8_t b = p[(*pos)++];
        v |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = v; return YES; }
    }
    return NO;
}

static void WriteVarint(NSMutableData *d, uint64_t v) {
    uint8_t buf[10];
    int n = 0;
    do {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if (v) b |= 0x80;
        buf[n++] = b;
    } while (v);
    [d appendBytes:buf length:n];
}

// Parses `len` bytes as a protobuf message. NO when the bytes are not a well-formed message.
static BOOL ParseMessage(const uint8_t *p, size_t len, BTRField **outFields, size_t *outCount) {
    size_t cap = 16, count = 0, pos = 0;
    BTRField *fields = malloc(cap * sizeof(BTRField));
    while (pos < len) {
        BTRField f = {0};
        f.tagStart = pos;
        uint64_t tag;
        if (!ReadVarint(p, len, &pos, &tag)) goto fail;
        f.field = (uint32_t)(tag >> 3);
        f.wire = tag & 7;
        if (f.field == 0 || (tag >> 3) > 0x1fffffff) goto fail;
        switch (f.wire) {
            case 0: { uint64_t ignored; if (!ReadVarint(p, len, &pos, &ignored)) goto fail; f.valueStart = f.tagStart; break; }
            case 1: if (len - pos < 8) goto fail; pos += 8; break;
            case 5: if (len - pos < 4) goto fail; pos += 4; break;
            case 2: {
                uint64_t l;
                if (!ReadVarint(p, len, &pos, &l) || l > len - pos) goto fail;
                f.valueStart = pos;
                f.valueLen = (size_t)l;
                pos += (size_t)l;
                break;
            }
            default: goto fail; // groups (3/4) and invalid wire types
        }
        f.end = pos;
        if (count == cap) { cap *= 2; fields = realloc(fields, cap * sizeof(BTRField)); }
        fields[count++] = f;
    }
    *outFields = fields;
    *outCount = count;
    return YES;
fail:
    free(fields);
    return NO;
}

static NSString *URLStringAt(const uint8_t *p, size_t len) {
    if (len < 12 || len > 4096 || memcmp(p, "http", 4) != 0) return nil;
    NSString *s = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
    return [BTRMedia isMediaURL:s] ? s : nil;
}

// Returns rewritten bytes for the message, nil when unchanged. *valid is NO when the bytes do
// not parse as a message (the caller then treats them as an opaque string/bytes value).
static NSData *RewriteMessage(const uint8_t *p, size_t len, int depth, BTRURLMapper mapper, NSInteger *count, BOOL *valid) {
    BTRField *fields = NULL;
    size_t n = 0;
    if (!ParseMessage(p, len, &fields, &n)) { *valid = NO; return nil; }
    *valid = YES;

    NSMutableDictionary<NSNumber *, NSData *> *replacements = [NSMutableDictionary dictionary];
    // Media URL strings of this message: index -> URL.
    NSMutableArray<NSNumber *> *urlIndexes = [NSMutableArray array];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];

    for (size_t i = 0; i < n; i++) {
        if (fields[i].wire != 2 || fields[i].valueLen == 0) continue;
        const uint8_t *v = p + fields[i].valueStart;
        NSString *url = URLStringAt(v, fields[i].valueLen);
        if (url) {
            [urlIndexes addObject:@(i)];
            [urls addObject:url];
            continue;
        }
        if (depth < 32 && fields[i].valueLen >= 2) {
            BOOL childValid = NO;
            NSData *child = RewriteMessage(v, fields[i].valueLen, depth + 1, mapper, count, &childValid);
            if (child) replacements[@(i)] = child;
        }
    }

    if (urls.count) {
        // Bilibili's media messages keep the primary address in a lower field number than the
        // backups (DashItem: base_url=2, backup_url=3; DashVideo: 1/2; ResponseUrl: url=4,
        // backup_url=5). The first occurrence of the lowest URL field is the primary.
        uint32_t minField = UINT32_MAX;
        for (NSNumber *idx in urlIndexes) minField = MIN(minField, fields[idx.unsignedLongValue].field);
        NSInteger primaryPos = -1;
        NSMutableArray<NSString *> *backups = [NSMutableArray array];
        for (NSUInteger k = 0; k < urlIndexes.count; k++) {
            if (primaryPos < 0 && fields[urlIndexes[k].unsignedLongValue].field == minField) primaryPos = (NSInteger)k;
            else [backups addObject:urls[k]];
        }
        NSString *replacement = mapper(urls[primaryPos], backups);
        if (replacement) {
            replacements[urlIndexes[primaryPos]] = [replacement dataUsingEncoding:NSUTF8StringEncoding];
            if (count) (*count)++;
        }
    }

    if (!replacements.count) { free(fields); return nil; }

    NSMutableData *out = [NSMutableData dataWithCapacity:len + 256];
    for (size_t i = 0; i < n; i++) {
        NSData *r = replacements[@(i)];
        if (!r) {
            [out appendBytes:p + fields[i].tagStart length:fields[i].end - fields[i].tagStart];
            continue;
        }
        size_t tagLen = 0, pos = fields[i].tagStart;
        uint64_t tag;
        ReadVarint(p, len, &pos, &tag);
        tagLen = pos - fields[i].tagStart;
        [out appendBytes:p + fields[i].tagStart length:tagLen];
        WriteVarint(out, r.length);
        [out appendData:r];
    }
    free(fields);
    return out;
}

#pragma mark - JSON

static NSArray<NSString *> *StringArray(id v) {
    if ([v isKindOfClass:NSString.class]) return @[ v ];
    if (![v isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id x in v) if ([x isKindOfClass:NSString.class]) [out addObject:x];
    return out;
}

static void RewriteJSONNode(id node, BTRURLMapper mapper, NSInteger *count, int depth) {
    if (depth > 48) return;
    if ([node isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d = node;
        NSString *primaryKey = nil;
        for (NSString *k in @[ @"base_url", @"baseUrl", @"url" ]) {
            if ([BTRMedia isMediaURL:d[k]]) { primaryKey = k; break; }
        }
        if (primaryKey) {
            NSString *primary = d[primaryKey];
            NSMutableArray *backups = [NSMutableArray array];
            for (NSString *k in @[ @"backup_url", @"backupUrl", @"backup_url_list" ]) [backups addObjectsFromArray:StringArray(d[k])];
            NSString *replacement = mapper(primary, backups);
            if (replacement) {
                for (NSString *k in @[ @"base_url", @"baseUrl", @"url" ])
                    if ([d[k] isEqual:primary]) d[k] = replacement;
                if (count) (*count)++;
            }
        }
        for (id key in d.allKeys) RewriteJSONNode(d[key], mapper, count, depth + 1);
    } else if ([node isKindOfClass:NSMutableArray.class]) {
        for (id item in (NSArray *)node) RewriteJSONNode(item, mapper, count, depth + 1);
    }
}

@implementation BTRRewriter

+ (BOOL)shouldInspectURL:(NSURL *)url {
    NSString *path = url.path.lowercaseString;
    if (!path.length) return NO;
    return [path rangeOfString:@"playurl"].location != NSNotFound ||
           [path rangeOfString:@"playview"].location != NSNotFound; // PlayView / PlayViewUnite
}

+ (NSData *)rewriteProtobuf:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *)count {
    if (!data.length) return nil;
    BOOL valid = NO;
    NSInteger c = 0;
    NSData *out = RewriteMessage(data.bytes, data.length, 0, mapper, &c, &valid);
    if (count) *count += c;
    return out;
}

+ (NSData *)rewriteGRPC:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *)count {
    const uint8_t *p = data.bytes;
    size_t len = data.length, pos = 0;
    // Validate the framing first: [flag:1][length:4 big endian][payload].
    while (pos < len) {
        if (len - pos < 5 || p[pos] > 1) return nil;
        uint32_t l = ((uint32_t)p[pos + 1] << 24) | ((uint32_t)p[pos + 2] << 16) | ((uint32_t)p[pos + 3] << 8) | p[pos + 4];
        if (l > len - pos - 5) return nil;
        pos += 5 + l;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:len + 512];
    BOOL changed = NO;
    pos = 0;
    while (pos < len) {
        uint8_t flag = p[pos];
        uint32_t l = ((uint32_t)p[pos + 1] << 24) | ((uint32_t)p[pos + 2] << 16) | ((uint32_t)p[pos + 3] << 8) | p[pos + 4];
        NSData *payload = [NSData dataWithBytesNoCopy:(void *)(p + pos + 5) length:l freeWhenDone:NO];
        NSData *plain = flag ? [self gzipInflate:payload] : payload;
        NSData *rewritten = plain ? [self rewriteProtobuf:plain mapper:mapper count:count] : nil;
        if (rewritten && flag) {
            NSData *packed = [self gzipDeflate:rewritten];
            if (!packed) { flag = 0; } else { rewritten = packed; }
        }
        NSData *body = rewritten ?: payload;
        if (rewritten) changed = YES;
        uint8_t header[5] = { flag, (uint8_t)(body.length >> 24), (uint8_t)(body.length >> 16), (uint8_t)(body.length >> 8), (uint8_t)body.length };
        [out appendBytes:header length:5];
        [out appendData:body];
        pos += 5 + l;
    }
    return changed ? out : nil;
}

+ (NSData *)rewriteJSON:(NSData *)data mapper:(BTRURLMapper)mapper count:(NSInteger *)count {
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (!obj) return nil;
    NSInteger c = 0;
    RewriteJSONNode(obj, mapper, &c, 0);
    if (count) *count += c;
    if (!c) return nil;
    NSJSONWritingOptions opts = 0;
    if (@available(iOS 13.0, macOS 10.15, *)) opts = NSJSONWritingWithoutEscapingSlashes;
    return [NSJSONSerialization dataWithJSONObject:obj options:opts error:nil];
}

+ (NSData *)rewriteResponseData:(NSData *)data contentType:(NSString *)contentType mapper:(BTRURLMapper)mapper count:(NSInteger *)count {
    if (data.length < 2 || data.length > 16 * 1024 * 1024) return nil;
    const uint8_t *p = data.bytes;
    NSString *ct = contentType.lowercaseString ?: @"";
    if ([ct containsString:@"grpc"]) return [self rewriteGRPC:data mapper:mapper count:count];
    // Skip leading whitespace for JSON detection.
    size_t i = 0;
    while (i < data.length && (p[i] == ' ' || p[i] == '\n' || p[i] == '\r' || p[i] == '\t')) i++;
    if (i < data.length && (p[i] == '{' || p[i] == '[')) return [self rewriteJSON:data mapper:mapper count:count];
    if (p[0] <= 1 && data.length >= 5) {
        NSData *g = [self rewriteGRPC:data mapper:mapper count:count];
        if (g) return g;
    }
    return [self rewriteProtobuf:data mapper:mapper count:count];
}

+ (NSData *)gzipInflate:(NSData *)data {
    if (!data.length) return data;
    z_stream s = {0};
    s.next_in = (Bytef *)data.bytes;
    s.avail_in = (uInt)data.length;
    if (inflateInit2(&s, 15 + 32) != Z_OK) return nil; // gzip or zlib
    NSMutableData *out = [NSMutableData dataWithLength:data.length * 4 + 1024];
    int r;
    do {
        if (s.total_out >= out.length) out.length += data.length * 2 + 1024;
        if (out.length > 64 * 1024 * 1024) { inflateEnd(&s); return nil; }
        s.next_out = (Bytef *)out.mutableBytes + s.total_out;
        s.avail_out = (uInt)(out.length - s.total_out);
        r = inflate(&s, Z_NO_FLUSH);
    } while (r == Z_OK);
    inflateEnd(&s);
    if (r != Z_STREAM_END) return nil;
    out.length = s.total_out;
    return out;
}

+ (NSData *)gzipDeflate:(NSData *)data {
    z_stream s = {0};
    if (deflateInit2(&s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:deflateBound(&s, data.length) + 64];
    s.next_in = (Bytef *)data.bytes;
    s.avail_in = (uInt)data.length;
    s.next_out = out.mutableBytes;
    s.avail_out = (uInt)out.length;
    int r = deflate(&s, Z_FINISH);
    deflateEnd(&s);
    if (r != Z_STREAM_END) return nil;
    out.length = s.total_out;
    return out;
}

@end
