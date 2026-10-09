## 使用说明（简版）

1. **准备**：装好 LiveContainer（主 LiveContainer，蓝色图标），在里面安装**已解密**的哔哩哔哩 IPA；下载本页的 `BTR-iOS.dylib` 到“文件” App。
2. **放入 dylib**：LiveContainer → **模块（Tweaks）** → `+` → **新建文件夹（New folder）**，比如 `BTR` → 进入文件夹 → `+` → **导入模块（Import Tweak）** → 选 `BTR-iOS.dylib`。也可以在“文件” App 里拷到 `LiveContainer/Tweaks/BTR/`。
3. **绑定文件夹**：长按哔哩哔哩 → **设置（Settings）** → **模块文件夹（Tweak Folder）** 选 `BTR`。灰色不可选时先 **转换为私有App（Convert to Private App）**，设置完可再转回共享。不要打开“不注入TweakLoader / 不加载TweakLoader”。
4. **确认**：启动后屏幕右侧出现粉色 **BTR** 悬浮球即成功（点它或三指长按 0.8 秒打开面板，“更多 → 原项目”显示版本号）。播放视频几秒后看“诊断”：“检查过的播放地址回复”和“播放器地址 · 已走 BTR”大于 0 说明在走加速；仍为 0 请在“最近的请求和播放地址”页点分享，把诊断和日志发来。
5. **节点列表**：面板“CDN 与线程”里点 **更新节点列表**，会从原项目仓库读取最新的大陆 / 海外节点表并立即生效；读取失败时继续用当前列表，也可以点“恢复内置节点列表”。
6. **更新 / 停用**：更新时在 `BTR` 文件夹里左滑删除旧 dylib 再导入新的，重启 App。临时停用：面板关掉“启用多线程加速”；完全停用：模块文件夹选 **无（None）** 或删除 dylib。

完整说明见 [README](https://github.com/MatchaCake/BTR-iOS#使用说明livecontainer)。
