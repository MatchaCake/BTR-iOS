# BTR-iOS

这是哔哩哔哩官方 iOS App 的 **LiveContainer tweak**，把
[Bilibili 线程撕裂者（BTR）](https://github.com/MrTangLuyao/Bilibili-thread-ripper) 的思路带到 iPhone 和 iPad 上：
它把视频切成小块，多条连接、多个 CDN 节点同时下载，再按顺序交给 App 自带的播放器。
主要解决海外看冷门视频、4K 和高码率视频时的卡顿。

> **非官方、实验性质。** 本项目不绕过会员、登录、地区、清晰度、审核状态、DRM 或媒体签名限制，
> 只加速你本来就有权播放的媒体字节，也不上传任何数据。0.1.1 已在真机上验证可用
> （哔哩哔哩 9.12.0、iOS 27.0、LiveContainer），其他版本未测，详见下文“验证状态”。

<img src="docs/panel.png" width="300" alt="BTR 设置面板（iOS 模拟器截图）">

## 工作原理

```text
哔哩哔哩 App ──(gRPC PlayViewUnite / PlayView、JSON playurl)──> B 站接口
      │                       ▲
      │      NSURLSession 钩子：把响应里视频流的主地址改成 http://127.0.0.1:47823/btr/…，
      │      备用地址（backup_url）保持原样
      ▼
App 自带播放器 ──Range 请求──> BTR 本地代理（进程内，只监听 127.0.0.1）
                                 │  把请求的区间切成小块（首块 256 KiB，之后按设置的分块大小）
                                 ├─ 节点 A ─┐
                                 ├─ 节点 B ─┼─ 校验每一块的 Content-Range 和长度，按顺序写回播放器
                                 └─ 节点 C ─┘
```

- **改写播放地址**：接管 `NSURLSession` 的 completion handler 任务，以及 AFNetworking 这类
  delegate 任务（代理类在会话创建时被接管，响应先缓存，改写后一次性交给原代理）。
  路径里包含 `playurl` 或 `PlayView` 的响应会被检查，支持：
  - gRPC 帧（含 gzip 压缩帧，改写后重新 gzip）；
  - 不依赖 `.proto` 定义的通用 protobuf 改写：递归解析消息，改写后重建所有外层长度前缀，
    没改动的字段逐字节保留。同一消息里**字段号最小**的媒体 URL 是主地址（`DashVideo.base_url=1`、
    `DashItem.base_url=2`、`ResponseUrl.url=4`），其余都是备用地址；
  - JSON（`base_url`、`baseUrl`、`url`）。
- **protobuf 层接管（0.1.1 起，主路径）**：官方 App 用 gRPC-ObjC（`GRPCStreamingProtoCall`，底层是 Cronet / gRPC core）
  请求 `PlayViewUnite` / `PlayView`，**不经过 `NSURLSession`**，所以上面的钩子在真机上看不到这些响应。
  0.1.1 改为接管 `GPBMessage -initWithData:extensionRegistry:error:` / `-mergeFromData:extensionRegistry:`：
  只对类名以 `PlayViewUniteReply`、`PlayViewReply`、`PlayURLReply` 结尾的回复（不含 `Live`），
  在解码前用同一个通用 protobuf 改写器改字节，与传输层无关。
- **播放器层兜底**：`IJKDashStreamItem`（`setBaseUrl:`、`initWithStreamId:…baseUrl:…`）和
  `IJKDashStreamBridge`（`setUrl:`、`initWithMediaType:…url:backupUrls:`）拿到还没走 BTR 的 B 站媒体地址时改成代理地址；
  `IJKMediaPlayerItem` 的 `setUrl:` / `willOpenUrl:` 只记录，不修改。每个钩子安装前都核对方法签名，不符就跳过并写日志。
- **诊断**：面板的“诊断”区显示检查过的播放地址回复次数、播放器拿到的地址是否已走 BTR；
  “最近的请求和播放地址”页列出最近看到的 `NSURLSession` 请求（只记主机和路径，不记参数）、
  protobuf 播放回复和播放器地址，分享时会连同日志一起导出。
- **本地代理**：移植 BTR 的 CDN 规则：大陆 / 海外节点表、用非 akamai 地址做模板换节点、
  只有 akamai 地址时用它做模板、两次 0 字节失败停用节点（4xx 只怪地址不怪节点）、失败后冷却退避、
  测速有效期 90 秒。调度方式：没测过的节点各先分一块试速度，之后按“谁最快能再交一块”分配；
  快要交给播放器的那块迟到时，向另一个节点再发一份（hedge），先到的为准；首块同时向两个节点竞速。
  B 站下发的原始地址也会排在最后参与下载。
- **安全回退**：首块在所有节点都失败时，代理返回 HTTP 502，播放器会改用 B 站给的备用地址，不会卡死；
  CDN 返回 200 整文件或错位的区间时，那一块直接丢弃，不会交给播放器。
- **默认只加速视频轨**。音轨很小，加速收益低；需要时可以在面板里打开。直播流（`live-bvc`）不处理。

## 使用说明（LiveContainer）

下面的界面名称来自 LiveContainer 上游源码和[官方 Tweaks 文档](https://livecontainer.github.io/docs/guides/tweaks)
（2026-09 的 main 分支），中文界面的写法附英文原名。不同版本的 LiveContainer 可能略有出入。

### 1. 准备

- 已经装好 [LiveContainer](https://github.com/LiveContainer/LiveContainer)（需要 iOS / iPadOS 15+，
  通过 AltStore / SideStore 安装），并且用的是主 LiveContainer（蓝色图标），不是 LiveContainer2。
  官方文档说明只有主 LiveContainer 和私有 App 能管理 tweak。
- 一份**已解密**的哔哩哔哩 IPA（App Store 下载的 IPA 是加密的，LiveContainer 跑不了）。在 LiveContainer
  的 App 列表点右上角 `+`，选这个 IPA 安装。国内版、HD 版、国际版（`com.bstar.intl`）都会启用；
  bundle ID 不含 `bili`、`danmaku`、`bstar` 的 App 里，BTR 什么也不做。
- 从 [Releases](../../releases/latest) 下载最新的 `BTR-iOS.dylib` 到“文件” App（每个版本发布一次，标签为
  `v<版本号>`，例如 `v0.1.1`，说明里附有对应提交和 SHA-256）。也可以从 [Actions](../../actions) 下载
  `BTR-iOS-dylib` 构件，或者在本机执行 `./build.sh`，得到 `build/BTR-iOS.dylib`。

### 2. 建一个 tweak 文件夹并放入 dylib

建议给哔哩哔哩单独建一个文件夹，不要直接放在 Tweaks 根目录：根目录是**全局**文件夹，里面的 tweak 会加载到
LiveContainer 里的所有 App。

**方法 A：在 LiveContainer 里导入（推荐）**

1. 打开 LiveContainer 底部的 **模块（Tweaks）** 标签。
2. 点右上角 `+` → **新建文件夹（New folder）**，起个名字，比如 `BTR`。
3. 点进 `BTR` 文件夹，再点右上角 `+` → **导入模块（Import Tweak）**，在文件选择器里选 `BTR-iOS.dylib`。

**方法 B：用“文件” App 拷贝**

LiveContainer 开启了文件共享，它的 Documents 目录会出现在“文件” App 的“我的 iPhone / 我的 iPad”下
（文件夹名一般就是 LiveContainer）。私有 App 用的 tweak 在其中的 `Tweaks` 文件夹里：

1. 先按方法 A 的第 1–2 步在 LiveContainer 里建好 `BTR` 文件夹（这样它一定会出现在选择列表里）。
2. 在“文件” App 里把 `BTR-iOS.dylib` 拷贝到 `LiveContainer/Tweaks/BTR/`。

用“文件” App 放进去的 dylib 不需要手动签名：LiveContainer 每次启动 App 前都会检查 tweak 文件，
文件有变化或签名失效时自动重新签名。

### 3. 让哔哩哔哩使用这个文件夹

1. 回到 App 列表，**长按**哔哩哔哩 → **设置（Settings）**。
2. 在“数据”一栏点 **模块文件夹（Tweak Folder）**，选 `BTR`（默认是“无 / None”）。
3. 如果这一项是灰色、点不动，说明这个 App 是共享 App（shared）。先点同一栏里的
   **转换为私有App（Convert to Private App）**，设置好模块文件夹后，需要的话再点
   **转换为共享App（Convert to Shared App）** 转回去，官方文档说明转回后 tweak 仍然有效。
4. 同一页面里 **不注入TweakLoader（Don't Inject TweakLoader）** 和 **不加载TweakLoader（Don't Load TweakLoader）**
   都要保持关闭，否则所有 tweak 都不会加载。

### 4. 启动并确认生效

1. 在 LiveContainer 里启动哔哩哔哩。第一次启动前 LiveContainer 会用自己的证书给 tweak 签名；
   如果提示签名无效，在 **模块（Tweaks）** 标签点右上角的签名按钮（签名图标）强制重签，
   或在 App 设置里点 **强制重新签名（Force Sign）**。
2. 屏幕右侧出现粉色 **BTR** 悬浮球就说明加载成功。悬浮球可以拖动；全屏播放器、弹出页等内容盖在上面时会自动隐藏。
   点悬浮球打开设置面板；悬浮球看不到时，**三指长按**屏幕约 0.8 秒也能打开。
3. 面板最下面“更多”一栏的“BTR-iOS”一行显示本 tweak 的版本号（例如 `v0.1.5`），可以用来确认装的是哪个版本；
   点它打开本项目仓库。下面的“原项目”一行点开是原项目 MrTangLuyao/Bilibili-thread-ripper 的仓库（不显示版本号）。

**怎么判断在工作**：播放一个视频后打开面板，满足下面几条就说明加速在走：

- “检查过的播放地址回复”括号里的 protobuf 次数大于 0（每打开一个视频一般 +1）；
- “播放器地址”里“已走 BTR”的条数大于 0，而且占大多数；
- “代理请求”大于 0，括号里的回退次数为 0 或很少；“CDN 节点”一栏里有多个节点在下载。

作为参考，真机实测（0.1.1，哔哩哔哩 9.12.0，iOS 27.0）看了两个视频：protobuf 层改写 2/2 次成功，
播放器拿到的 BTR 地址 354 条（另有 20 条在播放器层补改），代理请求 15 次、回退 0 次，分块从约 7 个 CDN 节点并行下载。
第一个视频开头偶尔会有几条 `akamaized.net` 原始地址比 protobuf 改写早约 200 毫秒到达播放器，
会显示为“未走 BTR→已改写”，由播放器层补改，属正常现象。

**怎么看诊断**：先正常打开一个视频播放几秒，再打开面板。

- “运行状态”一栏：
  - **接管的播放地址**：被改成走本地代理的视频流数量。大于 0 说明加速在工作。
  - **代理请求**（括号里是回退次数）、**当前线程 / 峰值**、**已下载 / 已交付**、**失败分段 / 备份请求**：
    代理的实际下载情况。回退次数多说明经常改用 B 站的备用地址。
- “诊断”一栏：
  - **检查过的播放地址回复**：BTR 看到的播放地址响应次数，括号里是在 protobuf 层看到的次数。
    播放后还是 0，说明这个版本的 App 没走 BTR 接管的路径。
  - **播放器地址**：播放器拿到的 B 站媒体地址条数和其中“已走 BTR”的条数。“已走 BTR”大于 0 说明播放器正在用本地代理。
  - **最近的请求和播放地址**：点进去能看到最近的 `NSURLSession 请求`（只记主机和路径）、`protobuf 播放回复`、
    `播放器拿到的地址`（标有“已走 BTR”“未走 BTR→已改写”或“未走 BTR”）。右上角分享按钮会把诊断和完整日志一起导出，
    “清空”只清这一页。
- “CDN 节点”一栏：每个节点的状态、速度、累计下载量和进行中的请求数。
- 反馈问题时，请在“最近的请求和播放地址”页点分享，把导出的文字一起发来
  （日志不含 Cookie，但会记录节点主机名和请求路径，分享前请自行检查）。

### 5. 更新和停用

**更新到新版本**

1. 从 [Releases](../../releases/latest) 下载新的 `BTR-iOS.dylib`。
2. LiveContainer → **模块（Tweaks）** → `BTR` 文件夹，把旧的 `BTR-iOS.dylib` **左滑 → 删除（Delete）**，
   再 `+` → **导入模块（Import Tweak）** 导入新的；或者在“文件” App 里直接覆盖 `Tweaks/BTR/BTR-iOS.dylib`。
3. 完全退出哔哩哔哩（在多任务界面划掉 LiveContainer），重新启动。LiveContainer 发现文件变了会自动重新签名。
4. 打开面板，确认“更多”一栏“BTR-iOS”一行的版本号已经变成新版本。

**停用**

- **临时停用加速**：面板里关掉“启用多线程加速”，从下一个视频开始不再改写播放地址；dylib 仍会加载。
  只想隐藏悬浮球可以关掉“显示悬浮球”（之后用三指长按打开面板）。
- **完全不加载**：长按哔哩哔哩 → **设置（Settings）** → **模块文件夹（Tweak Folder）** 选 **无（None）**，
  或者在 **模块（Tweaks）** 标签里把 `BTR-iOS.dylib`（或整个 `BTR` 文件夹）左滑删除，然后重新启动 App。

## 设置

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| 启用多线程加速 | 开 | 关掉后不再改写播放地址，从下一个视频开始生效 |
| 同时加速音轨 | 关 | |
| CDN 模式 | 大陆 CDN | 也可以选海外 CDN；“原始地址”只用 B 站给的地址做多线程；“自定义”只用你填的节点 |
| 自定义节点 | 空 | 只接受 `upos-*.bilivideo.com`、`cn-*.bilivideo.com`、`upos-*.akamaized.net`，最多 32 个，为空时按大陆 CDN |
| 线程数 | 8 | 一个请求同时下载的块数上限，可选 4 / 8 / 16 / 32 / 64 |
| 分块大小 | 1 MiB | 可选 256 KiB 到 4 MiB；为了控制内存，预取窗口最多 48 MiB |
| 更新节点列表 | 内置列表 | 0.1.2 起；0.1.3 起先读我们的签名节点表，再读原项目仓库（见下文）；0.1.4 起签名表有主地址和镜像两个地址；立即生效，不用重启 |
| 恢复内置节点列表 | | 更新过之后才出现，回到 dylib 自带的节点表 |

**节点列表**（0.1.4）：内置大陆 22 个（原版 8 个 + 2026-10-09 实测可用的 14 个）、海外 15 个（`*ov` + `cn-hk-eq-01-*`）。
取列表的顺序是 **我们的签名节点表（主地址 `btr-cdn-list.matchacake0v0.com` → 镜像 `static.matchacake.net`，同一份签名文件）→ 原项目仓库 → 上次成功的列表 → 内置列表**：

- 签名节点表每天由 GitHub Actions 用真实签名地址实测后自动发布；dylib 内置公钥（ECDSA P-256）验签，
  过期（14 天）、版本比已用过的旧、或含不允许的主机都会被拒绝。dylib 启动后每天在后台自动取一次（只取签名表，失败就保持当前列表）。
- 点 **更新节点列表** 时先取签名表，失败再依次从 `raw.githubusercontent.com`、`fastly.jsdelivr.net`、`cdn.jsdelivr.net`
  读取原项目的 [`src/cdn-resolver.js`](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/main/src/cdn-resolver.js)；弹窗显示来源和新增 / 移除了几个。
- 只接受 `upos-*.bilivideo.com`、`cn-*.bilivideo.com` 和 `upos-*.akamaized.net`。不再接受 `*.bilivideo.cn`：
  其中的 `<IP>.mcdn.bilivideo.cn` 可能指向第三方机器，签名地址不应发过去。每组 1–32 个，有一个不合格就整份不用；保存的列表损坏或含不允许的主机时自动退回内置列表。

面板里能看到接管了多少播放地址、代理请求数、回退次数、当前和峰值线程、已下载和已交付的字节数，
以及每个 CDN 节点的状态和速度（各项含义见上文“怎么看诊断”）。**日志**页可以分享完整日志，反馈问题时请附上
（日志不含 Cookie；为了排障会记录节点主机名，分享前请自行检查）。

## 构建与测试

只需要 Xcode 命令行工具，不需要 Theos：

```bash
./build.sh          # 生成 build/BTR-iOS.dylib（arm64，iOS 14+，ad-hoc 签名）
./tests/run.sh      # macOS 上的主机测试：CDN 规则、节点列表更新、JSON / protobuf / gRPC 改写、NSURLSession 钩子、本地代理
./tests/sim/run.sh  # iOS 模拟器冒烟测试：模仿 TweakLoader 用 dlopen 加载，走一遍完整链路并截图
```

主机测试会在本机起三个回环测试服务器（快、慢、全部 403），检查的内容包括：开放区间、中间区间、
越界裁剪、单字节、无 Range 返回 200、HEAD、416、全部节点拒绝时返回 502、播放器断开后下载全部停止、
并发请求的数据正确。GitHub Actions 每次推送都会跑主机测试，并把 dylib 作为 artifact 上传。

**发布新版本**：版本号只在 `src/BTRCore.h` 的 `BTR_VERSION` 里定义（面板和日志显示的就是它）。
改大这个版本号并推到 main，构建和测试通过后 CI 自动发布 `v<版本号>` Release（标题 `BTR-iOS <版本号>`，
附件 `BTR-iOS.dylib`，并设为 Latest）。版本号没变的推送只构建、不发布；CI 也会检查 dylib 里确实带着这个版本号。

## 验证状态

| 项目 | 状态 |
| --- | --- |
| arm64 iOS dylib 编译（Xcode clang，`-Wall -Wextra` 无警告） | ✅ 本机通过 |
| 改写器、钩子、代理的主机测试 | ✅ 本机通过 |
| iOS 模拟器：dlopen 加载、钩子安装、delegate 会话的 playurl 改写、经代理取回 7 MiB 完整数据、悬浮球和设置面板 | ✅ 本机通过（iOS 27 模拟器） |
| LiveContainer 真机加载 | ✅ 真机通过（0.1.1，iOS 27.0） |
| 真实哔哩哔哩 App 的接口经过被接管的 NSURLSession 方法 | ❌ 0.1.0 真机测试：播放地址走 gRPC-ObjC，不经过 NSURLSession。0.1.1 改为在 protobuf 解码层和 IJKPlayer 层接管 |
| protobuf / IJKPlayer 层接管在真机生效 | ✅ 真机通过（哔哩哔哩 9.12.0 `tv.danmaku.bilianime`）：`PlayViewUniteReply` 改写 2/2 次成功，播放器拿到 BTR 地址 354 条，另有 20 条由播放器层补改 |
| 播放器接受 `http://127.0.0.1` 地址并通过代理播放 | ✅ 真机通过：代理请求 15 次，回退 0 次 |
| 真实 B 站 CDN 上的多节点并行下载 | ✅ 真机通过：分块从约 7 个 CDN 节点并行下载（没有做系统的测速对比） |
| 其他哔哩哔哩版本（HD 版、国际版、更旧或更新的版本） | ⚠️ 未验证 |
| 0.1.2“更新节点列表”：解析原项目文件、域名校验、保存与恢复、多来源回退 | ✅ 主机测试通过；面板显示在模拟器里确认过；真机未测，国内网络能否连上 GitHub / jsDelivr 未测 |
| 0.1.3 签名节点表：验签、过期 / 版本检查、分组映射、回退顺序、每日后台刷新 | ✅ 主机测试通过（含用线上实际发布的列表验签）；真机未测；新增节点在大陆的速度未实测 |
| 0.1.4 签名表主地址改为 matchacake0v0.com，原地址作镜像（主地址失败再试镜像，再到原项目仓库） | ✅ 主机测试通过；两个地址本机实测返回同一份有效签名列表；真机未测，国内网络能否连上两个地址未测 |
| 0.1.5 面板“更多”：“BTR-iOS”一行单独显示本 tweak 版本号、作者 MatchaCake 和本项目链接；“原项目”一行只链接原项目，不再显示版本号 | ✅ 主机测试和 arm64 编译通过；真机未测 |

## 已知限制和风险

- **App 更新可能让它失效**：接口路径、protobuf 结构、网络库，或者播放器对地址的校验一变，就可能失效。
  失效时一般表现为“没有接管”（面板里“接管的播放地址”一直是 0），不会改坏响应。
  遇到这种情况请导出日志。
- **App 可能不走被接管的路径**：如果某个版本的哔哩哔哩用自研网络栈（例如 Cronet 或自己的 socket）
  请求播放地址，钩子就看不到这些响应。如果播放器自己有地址白名单，或者用 HTTPDNS 替换主机名，
  也可能拒绝回环地址。9.12.0 上这些都没有发生；其他版本需要真机日志确认。
- **ATS**：回环地址是 `http://`。LiveContainer 自己的 Info.plist 允许任意加载和本地网络，
  9.12.0 真机上播放器能正常访问本地代理；其他环境未验证。
- **风控**：BTR 的做法是把同一个带签名的地址拿到其他官方节点上做多连接 Range 下载，
  请求量会比原生播放器多，存在被 B 站限速或风控的可能。实测时一个伪造签名的请求在真实大陆节点上
  返回过 `HTTP 959`，这类拒绝会正常计入失败并触发回退。
- **后台**：iOS 挂起 App 时可能回收监听 socket。代理会在同一个端口（默认 47823，被占用时随机）重新监听；
  如果端口在重启后变化，旧的播放地址会失效，App 会重新获取。
- **离线缓存**：哔哩哔哩的离线下载如果也用了改写后的地址，就会经过本地代理，只在 App 运行期间有效。
- 不支持直播加速，也不支持 BTR 网页版的“全接管”播放器。

## 致谢与许可证

- 核心思路、CDN 节点表、候选地址和节点停用规则来自
  [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)
  （MIT，© 2026 Bilibili-thread-ripper contributors）以及
  [Bilibili-thread-ripper-desktop](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop)（MIT，© 2026 LouieTang）。
  感谢原作者。
- 关于官方 App 网络栈的社区公开研究：MinamiHashiRun0 的
  [BiliRawPackFast](https://github.com/MinamiHashiRun0/BiliRawPackFast) 和
  [BiliAccelerator](https://github.com/MinamiHashiRun0/BiliAccelerator)。本项目没有复制它们的代码。
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的 TweakLoader 负责加载本 tweak。

本项目采用 MIT 协议，见 [LICENSE](LICENSE)，其中保留了原项目的版权声明。
