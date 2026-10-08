// Simulator smoke test host: a tiny UIKit app that loads BTR-iOS.dylib the way LiveContainer's
// TweakLoader does (dlopen before UIApplicationMain), then exercises the hooks and the proxy
// with an AFNetworking-style delegate session against tests/range_server.py on the Mac.
#import <UIKit/UIKit.h>
#include <dlfcn.h>

static NSString *gAPI;

@interface Delegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@end
@implementation Delegate
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d { [self.data appendData:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:self.data options:0 error:nil];
    NSString *video = json[@"data"][@"dash"][@"video"][0][@"base_url"];
    NSLog(@"BTRSIM delegate base_url=%@", video);
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:video]];
    [r setValue:@"bytes=0-" forHTTPHeaderField:@"Range"];
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *res, NSError *err) {
        NSLog(@"BTRSIM proxy status=%ld bytes=%lu error=%@", (long)((NSHTTPURLResponse *)res).statusCode, (unsigned long)d.length, err);
    }] resume];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) Delegate *netDelegate;
@property (nonatomic, strong) NSURLSession *session;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 340, 40)];
    l.text = @"BTR simulator host";
    [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    self.netDelegate = [Delegate new];
    self.netDelegate.data = [NSMutableData data];
    self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self.netDelegate delegateQueue:nil];
    [[self.session dataTaskWithURL:[NSURL URLWithString:gAPI]] resume];
}
@end

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = SceneDelegate.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Loopback test media: use the addresses as handed out (multi-connection only).
        [NSUserDefaults.standardUserDefaults setInteger:2 forKey:@"BTRiOS.mode"];
        NSString *dylib = [NSBundle.mainBundle pathForResource:@"BTR-iOS" ofType:@"dylib"];
        void *h = dlopen(dylib.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        NSLog(@"BTRSIM dlopen %@ -> %p %s", dylib, h, h ? "" : dlerror());
        gAPI = [NSString stringWithFormat:@"http://127.0.0.1:%s/x/player/playurl?bvid=BV1", getenv("BTRSIM_PORT") ?: "18741"];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class));
    }
}
