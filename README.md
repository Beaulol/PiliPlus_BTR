# PiliPlus BTR Turbo

中文 | [English](README.en.md)

基于 PiliPlus 的 Android 衍生客户端，将 Bilibili-thread-ripper（BTR）的多连接下载与调度思路接入原生播放器，改善部分海外线路下视频起播慢、缓冲频繁的问题。

客户端基于 PiliPlus 2.1.6.2，当前发布版本为 **1.0.1**。对应源码见 [v1.0.1 分支](https://github.com/Beaulol/PiliPlus_BTR/tree/v1.0.1)，修改记录见 [version1.0.1.txt](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/version1.0.1.txt)。

## 本项目做了什么

- **接入 Android BTR 模块**：使用 Dart 实现本地 HTTP 代理，将下载的数据按顺序交给 mpv，继续使用 PiliPlus 的播放器、画质、音轨和弹幕功能。
- **实现并发下载与调度**：多 Range 分块、多 CDN 候选、连接复用、音视频共享并发上限、超时重试与失败回退。
- **提供两种工作模式**：兼容模式按播放器请求并发下载；全接管（增强调度）增加分块缓存、滚动预取、慢块补救与拖动后旧任务清理。
- **根据缓冲调整并发**：自动线程模式在缓冲不足时增加并发、缓冲充足时降低，并受用户设置的上限约束。
- **完善播放页设置**：在视频内调整 BTR 开关、工作模式、自动线程、并发上限和节点分组，应用后从当前进度重载；横屏支持上下滚动。
- **增加运行状态与速度显示**：加载图标下方显示 KB/s 或 MB/s，设置面板展示活动连接、缓冲余量和缓存状态，并提供本机 USB 日志采集脚本。

核心下载策略参考原版 BTR，Android 模块使用 Dart 重新实现。这里的“全接管”指增强下载调度，解码和播放时间线仍由 mpv 管理。

## 使用

1. 在视频播放页打开 **⋮ → BTR 加速设置**。
2. 开启“多线程加速”，选择工作模式、自动线程、并发上限和原始／大陆／海外节点。
3. 点击“应用”，视频从当前进度重新加载，设置同时保存为默认值。

BTR 默认关闭。正式版名称为 **PiliPlus BTR Turbo**，测试版名称为 **BTR Debugger**；两版可同时安装，账号与设置各自保存。

当前主要验证 Android ARM64 点播播放。直播、离线视频、投屏和 EDL 多段视频使用原有路径；部分块断点续传、基于 SIDX 的精确调度和 BTR 播放地址自动刷新尚未移植。实际收益取决于线路、节点及视频码率，尚未完成与网页端的受控速度对比。

## 开发与版本说明

构建前切换到需要的版本分支，并按 [BTR 模块文档](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/docs/BTR.md) 配置 Flutter、Android SDK 和本地环境。该文档同时包含模块结构、测试命令及实机验证记录。

- [1.0.1 更新说明](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/version1.0.1.txt)
- [修改记录](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/CHANGELOG.md)

## 致谢

- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：提供客户端基础、播放器及完整的 B 站功能。
- [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)：提供多 Range、多 CDN 和面向播放的下载调度思路。
- [nishuodedui1145-del/PiliPlus](https://github.com/nishuodedui1145-del/PiliPlus)：感谢其 PiliPlus 与 BTR 的整合探索及开源分享，为同方向的 Android 集成提供参考。

同时感谢 PiliPlus 所继承的 [PiliPala](https://github.com/guozhigq/pilipala)、[PiliPalaX](https://github.com/orz12/PiliPalaX)，以及上游贡献者与第三方依赖作者。

## 许可

本项目保留 PiliPlus 的 [GPL-3.0 许可证](LICENSE)，原有源码作者标记和第三方资源许可证保留。上游项目的完整功能介绍请访问各自仓库。
