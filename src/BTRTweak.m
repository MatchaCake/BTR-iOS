// BTR-iOS entry point. Loaded by LiveContainer's TweakLoader (dlopen) before the guest app's
// main() runs.
#import <Foundation/Foundation.h>
#import "BTRCore.h"
#import "BTRHooks.h"
#import "BTRProxy.h"

void BTRInstallUI(void);

static BOOL IsBilibiliApp(NSString *bundleID) {
    NSString *b = bundleID.lowercaseString ?: @"";
    // 国内版 tv.danmaku.bilianime、HD 版 tv.danmaku.bilipad、国际版 com.bstar.intl 等
    return [b containsString:@"danmaku"] || [b containsString:@"bili"] || [b containsString:@"bstar"];
}

__attribute__((constructor)) static void BTRInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!IsBilibiliApp(bundleID)) {
            NSLog(@"[BTR] %@ 不是哔哩哔哩，BTR-iOS 不启用", bundleID);
            return;
        }
        BTRLog(@"BTR-iOS %@ 已加载：%@ %@", BTR_VERSION, bundleID,
               [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"");
        [BTRProxyServer.shared start];
        BTRInstallHooks();
        BTRInstallUI();
        // Daily background refresh of the signed node list, once the app is up.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [BTRNodeList.shared refreshSignedIfStale];
        });
    }
}
