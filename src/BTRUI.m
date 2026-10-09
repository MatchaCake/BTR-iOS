// BTR-iOS: floating BTR button and the settings / status panel inside the host app.
#import <UIKit/UIKit.h>
#import "BTRCore.h"
#import "BTRProxy.h"

#pragma mark - Helpers

static UIWindow *KeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return ((UIWindowScene *)scene).windows.firstObject;
    }
    return nil;
}

static UIViewController *TopController(void) {
    UIViewController *vc = KeyWindow().rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

static UIColor *BiliPink(void) { return [UIColor colorWithRed:0xfb / 255.0 green:0x72 / 255.0 blue:0x99 / 255.0 alpha:1]; }

#pragma mark - Log viewer

@interface BTRLogViewController : UIViewController
/// YES: shows the diagnostics (recent requests / protobuf replies / player addresses) instead of the log.
@property (nonatomic) BOOL diagnostics;
@end

static NSString *ShareHeader(void) {
    return [NSString stringWithFormat:@"BTR-iOS %@ / %@ %@ / iOS %@\n", BTR_VERSION,
            NSBundle.mainBundle.bundleIdentifier, [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
            UIDevice.currentDevice.systemVersion];
}

static NSString *StatsSummary(void) {
    BTRStats *st = BTRStats.shared;
    return [NSString stringWithFormat:@"接管 %lld 条 / %lld 次响应；检查过 %lld 次播放地址响应（其中 protobuf 层 %lld 次）；"
            @"播放器拿到 B 站媒体地址 %lld 次，其中已走 BTR %lld 次、播放器层改写 %lld 次；代理请求 %lld（回退 %lld）\n",
            [st get:@"rewrittenURLs"], [st get:@"rewrittenResponses"], [st get:@"inspectedResponses"], [st get:@"pbReplies"],
            [st get:@"playerURLs"], [st get:@"playerProxied"], [st get:@"playerRewritten"], [st get:@"proxyRequests"], [st get:@"fallbacks"]];
}

@implementation BTRLogViewController {
    UITextView *_text;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.diagnostics ? @"诊断" : @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _text = [[UITextView alloc] initWithFrame:self.view.bounds];
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _text.editable = NO;
    _text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:_text];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)],
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clear)],
    ];
    [self reload];
}
- (void)reload {
    _text.text = self.diagnostics ? [StatsSummary() stringByAppendingFormat:@"\n%@", [BTRDiag dump]] : BTRLogDump();
    if (_text.text.length) [_text scrollRangeToVisible:NSMakeRange(_text.text.length - 1, 1)];
}
- (void)clear {
    if (self.diagnostics) [BTRDiag reset];
    else BTRLogClear();
    [self reload];
}
- (void)share:(UIBarButtonItem *)sender {
    // Logs and diagnostics are always shared together: one file answers "which path does the app use".
    NSString *text = [NSString stringWithFormat:@"%@%@\n%@\n==== 日志 ====\n%@", ShareHeader(), StatsSummary(), [BTRDiag dump], BTRLogDump()];
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[ text ] applicationActivities:nil];
    a.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Settings panel

typedef NS_ENUM(NSInteger, BTRSection) { BTRSectionSwitches, BTRSectionCDN, BTRSectionStatus, BTRSectionDiag, BTRSectionNodes, BTRSectionMore, BTRSectionCount };

@interface BTRSettingsViewController : UITableViewController
@end

@implementation BTRSettingsViewController {
    NSTimer *_timer;
    NSArray<NSDictionary *> *_nodes;
    BOOL _updatingNodes;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"线程撕裂者 BTR";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _nodes = BTRProxyServer.shared.hostStatus;
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        typeof(self) s = weakSelf;
        if (!s) { [t invalidate]; return; }
        s->_nodes = BTRProxyServer.shared.hostStatus;
        [s.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(BTRSectionStatus, 3)] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return BTRSectionCount; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case BTRSectionSwitches: return @"加速";
        case BTRSectionCDN: return @"CDN 与线程";
        case BTRSectionStatus: return @"运行状态";
        case BTRSectionDiag: return @"诊断";
        case BTRSectionNodes: return @"CDN 节点";
        default: return @"更多";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == BTRSectionSwitches) return @"改动从下一次打开视频（下一次获取播放地址）开始生效。";
    if (section == BTRSectionCDN) return @"“更新节点列表”先读取我们每天实测、带签名的节点表（验签、未过期、不比已用的旧），失败时改读原项目 GitHub 仓库（再失败用 jsDelivr 镜像），立即生效；都失败时保留当前列表。只接受 upos-*/cn-*.bilivideo.com 和 upos-*.akamaized.net。每天也会在后台自动取一次签名节点表。";
    if (section == BTRSectionDiag) return @"播放一个视频后看这里：“播放地址回复”为 0 说明 App 没走被接管的接口；“播放器地址”里出现“已走 BTR”说明播放器在用本地代理。反馈问题时请在“诊断”页点分享，日志会一起导出。";
    if (section == BTRSectionMore) return @"移植自 MrTangLuyao/Bilibili-thread-ripper（MIT）。非官方实验项目，不绕过会员、登录、地区或清晰度限制。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case BTRSectionSwitches: return 3;
        case BTRSectionCDN: return BTRNodeList.shared.isBuiltin ? 5 : 6;
        case BTRSectionStatus: return 6;
        case BTRSectionDiag: return 3;
        case BTRSectionNodes: return MAX(1, (NSInteger)MIN(_nodes.count, 12));
        default: return 4;
    }
}

- (UITableViewCell *)cell:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = title;
    c.detailTextLabel.text = detail;
    return c;
}

- (UITableViewCell *)subtitleCell:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text = title;
    c.detailTextLabel.text = detail;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on tag:(NSInteger)tag {
    UITableViewCell *c = [self cell:title detail:nil];
    UISwitch *s = [UISwitch new];
    s.on = on;
    s.tag = tag;
    s.onTintColor = BiliPink();
    [s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = s;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    BTRSettings *s = BTRSettings.shared;
    BTRStats *st = BTRStats.shared;
    switch (ip.section) {
        case BTRSectionSwitches:
            if (ip.row == 0) return [self switchCell:@"启用多线程加速" on:s.enabled tag:0];
            if (ip.row == 1) return [self switchCell:@"同时加速音轨" on:s.accelerateAudio tag:1];
            return [self switchCell:@"显示悬浮球" on:s.floatingButton tag:2];
        case BTRSectionCDN: {
            UITableViewCell *c;
            if (ip.row == 0) c = [self cell:@"CDN 模式" detail:BTRCDNModeName(s.mode)];
            else if (ip.row == 1) c = [self cell:@"自定义节点" detail:s.customHosts.count ? [NSString stringWithFormat:@"%lu 个", (unsigned long)s.customHosts.count] : @"未设置"];
            else if (ip.row == 2) c = [self cell:@"线程数" detail:[NSString stringWithFormat:@"%ld", (long)s.threads]];
            else if (ip.row == 3) c = [self cell:@"分块大小" detail:[BTRMedia formatBytes:s.chunkKB * 1024]];
            else if (ip.row == 4) {
                c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                c.textLabel.text = _updatingNodes ? @"正在更新节点列表…" : @"更新节点列表";
                c.textLabel.textColor = BiliPink();
                c.detailTextLabel.text = BTRNodeList.shared.summary;
                c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                return c;
            } else {
                c = [self cell:@"恢复内置节点列表" detail:nil];
                return c;
            }
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case BTRSectionStatus: {
            if (ip.row == 0) return [self cell:@"本地代理" detail:BTRProxyServer.shared.port ? [NSString stringWithFormat:@"127.0.0.1:%u", BTRProxyServer.shared.port] : @"未启动"];
            if (ip.row == 1) return [self cell:@"接管的播放地址" detail:[NSString stringWithFormat:@"%lld 条 / %lld 次响应", [st get:@"rewrittenURLs"], [st get:@"rewrittenResponses"]]];
            if (ip.row == 2) return [self cell:@"代理请求" detail:[NSString stringWithFormat:@"%lld（回退 %lld）", [st get:@"proxyRequests"], [st get:@"fallbacks"]]];
            if (ip.row == 3) return [self cell:@"当前线程 / 峰值" detail:[NSString stringWithFormat:@"%lld / %lld", MAX(0, [st get:@"activeThreads"]), [st get:@"maxThreads"]]];
            if (ip.row == 4) return [self cell:@"已下载 / 已交付" detail:[NSString stringWithFormat:@"%@ / %@", [BTRMedia formatBytes:[st get:@"bytesDownloaded"]], [BTRMedia formatBytes:[st get:@"bytesServed"]]]];
            return [self cell:@"失败分段 / 备份请求" detail:[NSString stringWithFormat:@"%lld / %lld", [st get:@"pieceFailures"], [st get:@"hedges"]]];
        }
        case BTRSectionDiag: {
            if (ip.row == 0) return [self cell:@"检查过的播放地址回复" detail:[NSString stringWithFormat:@"%lld 次（protobuf %lld）", [st get:@"inspectedResponses"], [st get:@"pbReplies"]]];
            if (ip.row == 1) return [self cell:@"播放器地址" detail:[NSString stringWithFormat:@"%lld 条 · 已走 BTR %lld", [st get:@"playerURLs"], [st get:@"playerProxied"] + [st get:@"playerRewritten"]]];
            UITableViewCell *c = [self cell:@"最近的请求和播放地址" detail:nil];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case BTRSectionNodes: {
            if (!_nodes.count) return [self cell:@"还没有下载过" detail:nil];
            NSDictionary *n = _nodes[ip.row];
            double bps = [n[@"bps"] doubleValue];
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.textLabel.text = n[@"host"];
            c.textLabel.font = [UIFont systemFontOfSize:14];
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · 共 %@ · 进行中 %@", n[@"state"],
                                      bps > 0 ? [NSString stringWithFormat:@"%.1f Mbps", bps * 8 / 1e6] : @"--",
                                      [BTRMedia formatBytes:[n[@"bytes"] longLongValue]], n[@"inflight"]];
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            return c;
        }
        default: {
            UITableViewCell *c;
            if (ip.row == 0) c = [self cell:@"查看 / 分享日志" detail:nil];
            else if (ip.row == 1) c = [self cell:@"清零统计" detail:nil];
            else if (ip.row == 2) {
                // This tweak's own version (BTR_VERSION in BTRCore.h) and repo.
                c = [self subtitleCell:@"BTR-iOS" detail:[NSString stringWithFormat:@"v%@ · 作者 MatchaCake", BTR_VERSION]];
            } else {
                // Upstream project link. No version here: upstream releases independently.
                c = [self subtitleCell:@"原项目" detail:@"MrTangLuyao/Bilibili-thread-ripper"];
            }
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
    }
}

- (void)switchChanged:(UISwitch *)sender {
    BTRSettings *s = BTRSettings.shared;
    if (sender.tag == 0) s.enabled = sender.on;
    else if (sender.tag == 1) s.accelerateAudio = sender.on;
    else {
        s.floatingButton = sender.on;
        [NSNotificationCenter.defaultCenter postNotificationName:@"BTRButtonSettingChanged" object:nil];
    }
    BTRLog(@"设置已修改：%@ = %@", sender.tag == 0 ? @"启用" : sender.tag == 1 ? @"音轨加速" : @"悬浮球", sender.on ? @"开" : @"关");
}

- (void)choose:(NSString *)title options:(NSArray<NSString *> *)options from:(NSIndexPath *)ip handler:(void (^)(NSInteger))handler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [options enumerateObjectsUsingBlock:^(NSString *o, NSUInteger i, BOOL *stop) {
        [a addAction:[UIAlertAction actionWithTitle:o style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            handler((NSInteger)i);
            [self.tableView reloadData];
        }]];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    a.popoverPresentationController.sourceView = cell ?: self.view;
    a.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)updateNodeList {
    if (_updatingNodes) return;
    _updatingNodes = YES;
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [BTRNodeList.shared updateWithCompletion:^(BTRNodeUpdateResult *r) {
        typeof(self) s = weakSelf;
        if (!s) return;
        s->_updatingNodes = NO;
        [s.tableView reloadData];
        [s alert:r.ok ? @"节点列表" : @"节点列表更新失败" message:r.ok ? [NSString stringWithFormat:@"%@\n%@", r.message, BTRNodeList.shared.summary] : r.message];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    BTRSettings *s = BTRSettings.shared;
    if (ip.section == BTRSectionCDN) {
        if (ip.row == 0) {
            [self choose:@"CDN 模式" options:@[ @"大陆 CDN（推荐）", @"海外 CDN", @"原始地址（只做多线程）", @"自定义" ] from:ip handler:^(NSInteger i) {
                s.mode = (BTRCDNMode)i;
                BTRLog(@"CDN 模式：%@", BTRCDNModeName(s.mode));
            }];
        } else if (ip.row == 1) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自定义节点"
                                                                       message:@"只接受 B 站自己的节点：upos-*.bilivideo.com、cn-*.bilivideo.com、upos-*.akamaized.net，用逗号或换行分隔，最多 32 个。CDN 模式选“自定义”时生效，一个都没有时按大陆 CDN。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
                f.text = [s.customHosts componentsJoinedByString:@", "];
                f.placeholder = @"upos-sz-mirrorcos.bilivideo.com";
                f.autocapitalizationType = UITextAutocapitalizationTypeNone;
                f.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                NSString *text = a.textFields.firstObject.text ?: @"";
                NSMutableArray *hosts = [NSMutableArray array];
                for (NSString *part in [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，\n "]]) {
                    NSString *h = [BTRMedia normalizeHost:part];
                    if (h && [BTRNodeList isAllowedNodeHost:h] && ![hosts containsObject:h]) [hosts addObject:h];
                }
                s.customHosts = hosts;
                BTRLog(@"自定义节点：%@", [hosts componentsJoinedByString:@", "]);
                [self.tableView reloadData];
            }]];
            [self presentViewController:a animated:YES completion:nil];
        } else if (ip.row == 4) {
            [self updateNodeList];
        } else if (ip.row == 5) {
            [BTRNodeList.shared restoreBuiltin];
            [self.tableView reloadData];
            [self alert:@"已恢复内置节点列表" message:BTRNodeList.shared.summary];
        } else if (ip.row == 2) {
            NSArray *values = @[ @4, @8, @16, @32, @64 ];
            [self choose:@"线程数（同一分段的并发上限）" options:@[ @"4", @"8（推荐）", @"16", @"32", @"64" ] from:ip handler:^(NSInteger i) { s.threads = [values[i] integerValue]; }];
        } else if (ip.row == 3) {
            NSArray *values = @[ @256, @512, @1024, @2048, @4096 ];
            [self choose:@"分块大小" options:@[ @"256 KiB", @"512 KiB", @"1 MiB（推荐）", @"2 MiB", @"4 MiB" ] from:ip handler:^(NSInteger i) { s.chunkKB = [values[i] integerValue]; }];
        }
    } else if (ip.section == BTRSectionDiag && ip.row == 2) {
        BTRLogViewController *vc = [BTRLogViewController new];
        vc.diagnostics = YES;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.section == BTRSectionMore) {
        if (ip.row == 0) [self.navigationController pushViewController:[BTRLogViewController new] animated:YES];
        else if (ip.row == 1) { [BTRStats.shared reset]; [BTRDiag reset]; [tableView reloadData]; }
        else {
            NSString *url = ip.row == 2 ? @"https://github.com/MatchaCake/BTR-iOS" : @"https://github.com/MrTangLuyao/Bilibili-thread-ripper";
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }
    }
}

@end

#pragma mark - Floating button

@interface BTRFloatingController : NSObject
@end

@implementation BTRFloatingController {
    UIButton *_button;
}

+ (instancetype)shared {
    static BTRFloatingController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BTRFloatingController new]; });
    return s;
}

- (void)start {
    [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) { [self ensure]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"BTRButtonSettingChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [self ensure]; }];
    [self ensure];
}

- (UIButton *)button {
    if (_button) return _button;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 44, 44);
    b.layer.cornerRadius = 22;
    b.backgroundColor = [BiliPink() colorWithAlphaComponent:0.88];
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 4;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b setTitle:@"BTR" forState:UIControlStateNormal];
    [b addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    _button = b;
    return b;
}

- (void)place:(UIButton *)b in:(UIWindow *)w {
    BTRSettings *s = BTRSettings.shared;
    CGSize size = w.bounds.size;
    UIEdgeInsets safe = w.safeAreaInsets;
    double x = s.buttonX >= 0 ? s.buttonX : 1, y = s.buttonY >= 0 ? s.buttonY : 0.62;
    CGFloat minX = safe.left + 32, maxX = size.width - safe.right - 32;
    CGFloat minY = safe.top + 32, maxY = size.height - safe.bottom - 32;
    b.center = CGPointMake(minX + (maxX - minX) * x, minY + (maxY - minY) * y);
}

- (void)ensure {
    UIWindow *w = KeyWindow();
    UIButton *b = [self button];
    if (!BTRSettings.shared.floatingButton || !w) { [b removeFromSuperview]; return; }
    // Stay out of the way of anything presented on top (the BTR panel, full-screen player, sheets).
    b.hidden = w.rootViewController.presentedViewController != nil;
    if (b.superview != w) {
        [b removeFromSuperview];
        [w addSubview:b];
        [self place:b in:w];
    } else if (w.subviews.lastObject != b) {
        [w bringSubviewToFront:b];
    }
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *w = v.superview;
    if (!w) return;
    CGPoint d = [g translationInView:w];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:w];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        UIEdgeInsets safe = w.safeAreaInsets;
        CGSize size = w.bounds.size;
        CGFloat minY = safe.top + 32, maxY = size.height - safe.bottom - 32;
        BTRSettings.shared.buttonX = v.center.x < size.width / 2 ? 0 : 1; // snap to the nearest side
        BTRSettings.shared.buttonY = MAX(0, MIN(1, (v.center.y - minY) / MAX(1, maxY - minY)));
        [UIView animateWithDuration:0.2 animations:^{ [self place:(UIButton *)v in:(UIWindow *)w]; }];
    }
}

- (void)open {
    UIViewController *top = TopController();
    if (!top || ([top isKindOfClass:UINavigationController.class] && [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:BTRSettingsViewController.class])) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[BTRSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

@end

#pragma mark - Entry

void BTRInstallUI(void) {
    __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        [BTRFloatingController.shared start];
        // Three-finger long press anywhere opens the panel, even with the button hidden.
        UIWindow *w = KeyWindow();
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:BTRFloatingController.shared action:@selector(open)];
        g.numberOfTouchesRequired = 3;
        g.minimumPressDuration = 0.8;
        g.cancelsTouchesInView = NO;
        [w addGestureRecognizer:g];
#ifdef BTR_TESTING
        if (getenv("BTR_OPEN_PANEL")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [BTRFloatingController.shared open]; });
#endif
    }];
}
