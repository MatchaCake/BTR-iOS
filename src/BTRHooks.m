#import "BTRHooks.h"
#import "BTRCore.h"
#import "BTRProxy.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const void *kBufferKey = &kBufferKey;

typedef void (^BTRCompletion)(NSData *, NSURLResponse *, NSError *);

#pragma mark - Rewriting

BTRURLMapper BTRDefaultMapper(void) {
    return ^NSString *(NSString *primary, NSArray<NSString *> *backups) {
        BTRSettings *s = BTRSettings.shared;
        if (!s.enabled || [BTRMedia isLiveURL:primary]) return nil;
        if ([BTRMedia isAudioURL:primary] && !s.accelerateAudio) return nil;
        return [BTRProxyServer.shared proxyURLForPrimary:primary backups:backups];
    };
}

NSData *BTRRewriteBody(NSData *data, NSURLResponse *response, NSURL *url) {
    if (!BTRSettings.shared.enabled || !data.length) return nil;
    NSString *ct = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Type"] : response.MIMEType;
    NSInteger count = 0;
    NSData *out = nil;
    @try {
        out = [BTRRewriter rewriteResponseData:data contentType:ct mapper:BTRDefaultMapper() count:&count];
    } @catch (NSException *e) {
        BTRLog(@"改写播放地址时出错：%@", e.reason);
        out = nil;
    }
    [BTRStats.shared add:@"inspectedResponses" value:1];
    if (out && count > 0) {
        [BTRStats.shared add:@"rewrittenResponses" value:1];
        [BTRStats.shared add:@"rewrittenURLs" value:count];
        [BTRProxyServer.shared resetBans];
        BTRLog(@"已接管 %ld 条播放地址：%@（%@，%@）", (long)count, url.path.lastPathComponent ?: @"?", ct ?: @"无类型", [BTRMedia formatBytes:(int64_t)data.length]);
        return out;
    }
    BTRLog(@"播放地址响应没有可接管的地址：%@（%@，%@）", url.path.lastPathComponent ?: @"?", ct ?: @"无类型", [BTRMedia formatBytes:(int64_t)data.length]);
    return nil;
}

static BTRCompletion Wrap(NSURL *url, BTRCompletion handler) {
    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *out = data;
        if (data.length && !error) out = BTRRewriteBody(data, response, url) ?: data;
        handler(out, response, error);
    };
}

#pragma mark - Runtime helpers

static BOOL ClassDefines(Class c, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == sel;
    free(list);
    return found;
}

static Class DefiningClass(Class c, SEL sel) {
    for (; c; c = class_getSuperclass(c)) if (ClassDefines(c, sel)) return c;
    return Nil;
}

static IMP SwizzleDefining(Class start, SEL sel, IMP replacement) {
    Class d = DefiningClass(start, sel);
    if (!d) { BTRLog(@"找不到要接管的方法 %@", NSStringFromSelector(sel)); return NULL; }
    return method_setImplementation(class_getInstanceMethod(d, sel), replacement);
}

#pragma mark - Completion handler tasks

typedef id (*TaskReqCH)(id, SEL, NSURLRequest *, BTRCompletion);
typedef id (*TaskURLCH)(id, SEL, NSURL *, BTRCompletion);
typedef id (*UploadCH)(id, SEL, NSURLRequest *, NSData *, BTRCompletion);
typedef id (*TaskReq)(id, SEL, NSURLRequest *);
typedef id (*TaskURL)(id, SEL, NSURL *);
typedef id (*Upload)(id, SEL, NSURLRequest *, NSData *);
typedef id (*SessionFactory)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);

static TaskReqCH origTaskReqCH;
static TaskURLCH origTaskURLCH;
static UploadCH origUploadCH;
static TaskReq origTaskReq;
static TaskURL origTaskURL;
static Upload origUpload;
static SessionFactory origFactory;

static id HookTaskReqCH(id self, SEL _cmd, NSURLRequest *req, BTRCompletion handler) {
    if (handler && [BTRRewriter shouldInspectURL:req.URL]) handler = Wrap(req.URL, handler);
    return origTaskReqCH(self, _cmd, req, handler);
}

static id HookTaskURLCH(id self, SEL _cmd, NSURL *url, BTRCompletion handler) {
    if (handler && [BTRRewriter shouldInspectURL:url]) handler = Wrap(url, handler);
    return origTaskURLCH(self, _cmd, url, handler);
}

static id HookUploadCH(id self, SEL _cmd, NSURLRequest *req, NSData *body, BTRCompletion handler) {
    if (handler && [BTRRewriter shouldInspectURL:req.URL]) handler = Wrap(req.URL, handler);
    return origUploadCH(self, _cmd, req, body, handler);
}

#pragma mark - Delegate tasks (AFNetworking and friends)

static NSMutableDictionary<NSValue *, NSValue *> *gRecvOrig, *gCompOrig;
static NSMutableSet<NSValue *> *gSkipped;
static NSLock *gHookLock;

static NSValue *Key(Class c) { return [NSValue valueWithPointer:(__bridge const void *)c]; }

static BOOL IsSystemClass(Class c) {
    const char *image = class_getImageName(c);
    if (!image) return YES;
    return strncmp(image, "/System/", 8) == 0 || strncmp(image, "/usr/lib/", 9) == 0 ||
           strstr(image, "/System/Library/") != NULL;
}

static IMP FindOrig(NSDictionary<NSValue *, NSValue *> *table, id self, NSString *tlsKey, Class *found) {
    NSMutableDictionary *td = NSThread.currentThread.threadDictionary;
    NSValue *after = td[tlsKey];
    Class c = after ? class_getSuperclass((__bridge Class)after.pointerValue) : object_getClass(self);
    [gHookLock lock];
    IMP imp = NULL;
    for (; c; c = class_getSuperclass(c)) {
        NSValue *v = table[Key(c)];
        if (v) { imp = (IMP)v.pointerValue; *found = c; break; }
    }
    [gHookLock unlock];
    return imp;
}

static void HookRecv(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    NSMutableData *buffer = objc_getAssociatedObject(task, kBufferKey);
    if (buffer) { [buffer appendData:data]; return; }
    NSString *tls = [NSString stringWithFormat:@"BTR.recv.%p", self];
    NSMutableDictionary *td = NSThread.currentThread.threadDictionary;
    id previous = td[tls];
    Class found = Nil;
    IMP imp = FindOrig(gRecvOrig, self, tls, &found);
    if (!imp) return;
    td[tls] = Key(found);
    ((void (*)(id, SEL, id, id, id))imp)(self, _cmd, session, task, data);
    td[tls] = previous;
}

static void HookComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSMutableData *buffer = objc_getAssociatedObject(task, kBufferKey);
    if (buffer) {
        objc_setAssociatedObject(task, kBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSData *out = buffer;
        if (!error && buffer.length) out = BTRRewriteBody(buffer, task.response, task.originalRequest.URL) ?: buffer;
        // Hand the whole body over in one piece; the hook no longer buffers this task.
        if (out.length) ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, @selector(URLSession:dataTask:didReceiveData:), session, task, out);
    }
    NSString *tls = [NSString stringWithFormat:@"BTR.comp.%p", self];
    NSMutableDictionary *td = NSThread.currentThread.threadDictionary;
    id previous = td[tls];
    Class found = Nil;
    IMP imp = FindOrig(gCompOrig, self, tls, &found);
    if (!imp) return;
    td[tls] = Key(found);
    ((void (*)(id, SEL, id, id, id))imp)(self, _cmd, session, task, error);
    td[tls] = previous;
}

static BOOL HookDelegateClass(Class cls) {
    if (!cls) return NO;
    SEL recv = @selector(URLSession:dataTask:didReceiveData:);
    SEL comp = @selector(URLSession:task:didCompleteWithError:);
    Class dr = DefiningClass(cls, recv), dc = DefiningClass(cls, comp);
    if (!dr || !dc) return NO;
    [gHookLock lock];
    BOOL ok = NO;
    if ([gSkipped containsObject:Key(cls)]) goto done;
    if (IsSystemClass(dr) || IsSystemClass(dc)) { [gSkipped addObject:Key(cls)]; goto done; }
    if (!gRecvOrig[Key(dr)]) {
        IMP o = method_setImplementation(class_getInstanceMethod(dr, recv), (IMP)HookRecv);
        gRecvOrig[Key(dr)] = [NSValue valueWithPointer:(const void *)o];
        BTRLog(@"已接管网络代理类 %s 的数据回调", class_getName(dr));
    }
    if (!gCompOrig[Key(dc)]) {
        IMP o = method_setImplementation(class_getInstanceMethod(dc, comp), (IMP)HookComplete);
        gCompOrig[Key(dc)] = [NSValue valueWithPointer:(const void *)o];
    }
    ok = YES;
done:
    [gHookLock unlock];
    return ok;
}

static BOOL DelegateIsHooked(id delegate) {
    if (!delegate) return NO;
    Class dr = DefiningClass(object_getClass(delegate), @selector(URLSession:dataTask:didReceiveData:));
    Class dc = DefiningClass(object_getClass(delegate), @selector(URLSession:task:didCompleteWithError:));
    if (!dr || !dc) return NO;
    [gHookLock lock];
    BOOL r = gRecvOrig[Key(dr)] != nil && gCompOrig[Key(dc)] != nil;
    [gHookLock unlock];
    return r;
}

static id Mark(NSURLSession *session, NSURLSessionTask *task, NSURL *url) {
    if (task && [BTRRewriter shouldInspectURL:url]) {
        if (DelegateIsHooked(session.delegate)) {
            objc_setAssociatedObject(task, kBufferKey, [NSMutableData data], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            BTRLog(@"播放地址请求走了未接管的代理（%s）：%@", session.delegate ? object_getClassName(session.delegate) : "无", url.path.lastPathComponent);
        }
    }
    return task;
}

static id HookTaskReq(NSURLSession *self, SEL _cmd, NSURLRequest *req) {
    return Mark(self, origTaskReq(self, _cmd, req), req.URL);
}

static id HookTaskURL(NSURLSession *self, SEL _cmd, NSURL *url) {
    return Mark(self, origTaskURL(self, _cmd, url), url);
}

static id HookUpload(NSURLSession *self, SEL _cmd, NSURLRequest *req, NSData *body) {
    return Mark(self, origUpload(self, _cmd, req, body), req.URL);
}

static id HookFactory(id self, SEL _cmd, NSURLSessionConfiguration *config, id delegate, NSOperationQueue *queue) {
    if (delegate && delegate != (id)BTRProxyServer.shared) HookDelegateClass(object_getClass(delegate));
    return origFactory(self, _cmd, config, delegate, queue);
}

void BTRInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecvOrig = [NSMutableDictionary dictionary];
        gCompOrig = [NSMutableDictionary dictionary];
        gSkipped = [NSMutableSet set];
        gHookLock = [NSLock new];
        Class session = NSClassFromString(@"__NSURLSessionLocal") ?: NSURLSession.class;
        origTaskReqCH = (TaskReqCH)SwizzleDefining(session, @selector(dataTaskWithRequest:completionHandler:), (IMP)HookTaskReqCH);
        origTaskURLCH = (TaskURLCH)SwizzleDefining(session, @selector(dataTaskWithURL:completionHandler:), (IMP)HookTaskURLCH);
        origUploadCH = (UploadCH)SwizzleDefining(session, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)HookUploadCH);
        origTaskReq = (TaskReq)SwizzleDefining(session, @selector(dataTaskWithRequest:), (IMP)HookTaskReq);
        origTaskURL = (TaskURL)SwizzleDefining(session, @selector(dataTaskWithURL:), (IMP)HookTaskURL);
        origUpload = (Upload)SwizzleDefining(session, @selector(uploadTaskWithRequest:fromData:), (IMP)HookUpload);
        Method factory = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:));
        origFactory = (SessionFactory)method_setImplementation(factory, (IMP)HookFactory);
        BTRLog(@"NSURLSession 接管已安装（%s）", class_getName(session));
    });
}
