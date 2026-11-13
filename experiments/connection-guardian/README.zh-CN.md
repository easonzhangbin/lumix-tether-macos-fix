# LUMIX Connection Guardian

[English](README.md)

面向 DC-S1H 的菜单栏连接守护工具。拍摄、光圈、快门、白平衡和原片保存仍由另行安装的官方 LUMIX Tether 2.12 完成；本工具负责连接前的准备、USB 插拔监测和应用重启交接。

当前为 **Guardian 0.2.1 社区测试版**，发布于 [guardian-v0.2.1](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.1)。此前一次守护器恢复后，已在原厂 Tether 验证实时预览、6000×4000 RAW 拍摄和保存（36,048,384 字节）。光圈、快门、ISO、色温控制也在原厂界面单独验证过。这些短测不能替代重复拔插、睡眠唤醒及长时间拍摄测试。

工具提供“结束本次拍摄”，并把 USB 检测、Tether 进程及拍摄连接状态分开显示；0.2.1 新增有大小上限的本地事件日志，便于排查。拍摄连接必须在 Tether 内确认；USB 已连接、接口有占用、进程正在运行，都不会被当作已经可以拍摄。

## 使用

1. 安装[官方 LUMIX Tether 2.12](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)。本工具不包含或修改松下程序。
2. 将 S1H 通过数据线连接 Mac，并选择 PC(Tether)。
3. 打开 `LUMIX Connection Guardian.app`，查看连接状态；点击开始守护并打开 Tether。关闭状态窗口后仍保留菜单栏图标，可从菜单重新查看。
4. 等待连接准备及原厂程序启动，在 Tether 内确认预览并进行拍摄。
5. 完成拍摄及照片传输后，点击“结束本次拍摄”。它先停止自动恢复，再请求 Tether 正常退出，之后不会自动重新打开；守护工具保留在菜单栏。
6. 若只需暂停自动恢复并保留 Tether，选择“暂停自动恢复”。退出守护工具也会保留 Tether；正在执行的有界恢复程序会先完成清理。

首次打开不会创建登录项、系统服务或后台 LaunchAgent。工具只在用户启动后运行；中文或英文界面跟随系统首选语言。启动原厂 Tether 时使用它现有的语言参数。

## 能力与边界

工具只读监测 USB 注册信息、接口占用及 Tether 进程。原厂程序未运行时，才可开始清理残留响应和验证新 PTP 会话。只有确认是本用户的系统相机服务占用、且现有守卫允许时，才会处理该服务并重试。它不抢占驱动、不结束其他相机软件，也不拍摄、读取或删除照片。

重新连接会先请求 Tether 正常退出。确认 USB 物理断开后，也可请求由守护器启动、且身份仍一致的 Tether 正常退出。退出超时并不能证明相机空闲，因此不会自动强杀 Tether；重新连接超时后的“强制重启”和结束拍摄超时后的“强制退出”都是单独的明确操作。结束拍摄后强制退出也不会重新启动。正常退出和 USB 插拔后的恢复采用有上限的重试；不会无限向状态不明的会话发送命令。

外部程序仍可自行启动，macOS 没有为这个工具提供跨应用的 USB 禁入锁。监测器不能一边独占相机，一边让 Tether 使用同一接口，也不能从外部修复 Tether 内部线程等待。若问题发生在原厂程序内部，只能重启程序并重新准备连接。

## 本地事件日志

守护工具记录“开始”“结束本次拍摄”“暂停”“重新连接”等流程操作、本工具发出的应用启动请求，以及观察到的 Tether 进程变化。它们表示守护工具做了什么、看到了什么，不是相机快门事件，也不能证明照片已经拍摄、保存或当前可以拍摄。

事件以 JSON Lines 格式写入 `~/Library/Logs/S1H Connection Guardian/events.jsonl`。每个文件上限为 1 MiB，最多保留 `events.jsonl.1`、`events.jsonl.2`、`events.jsonl.3` 三个轮转文件。运行标识、尝试标识、时间戳、进程 ID 和守护状态用于关联同一流程中的事件。

日志区分“本工具请求启动”和“从外部观察到进程、来源未知”。启动请求只记录 Guardian 向系统发出的请求，不能证明最终是哪项操作促成了进程出现。仅观察进程不能确定人的意图，也不能断定来自 Finder、Dock 或其他应用；父进程是 `launchd` 也不足以确定启动来源。

事件日志不包含照片、相机序列号、原始检查快照或完整文件系统路径。现有辅助程序日志保持不变，仍可能包含进程元数据或本机路径。所有日志保存在本机，不自动上传；分享任何摘录前请先检查。事件日志用于诊断，不是相机活动的完整审计记录。


## 速率显示

界面中的“协商速率 5Gbps”表示 USB 链路档位，并非实际每秒传输了这么多数据。本机 S1H 的被动注册表检查未提供累计传输字节计数，因此本版不显示实时 USB MB/s，也不会把未测量标为 0MB/s。照片落盘速度受缓冲和磁盘写入影响，不能替代 USB 吞吐量。Apple 的 [IOUSBHostCompletionHandler](https://developer.apple.com/documentation/iousbhost/iousbhostcompletionhandler) 返回的是调用者自身请求完成的字节数，无法用于旁观官方 Tether 的全部传输。

## 构建

需要 Apple Silicon Mac 和 Xcode Command Line Tools：

```sh
./build.sh
```

构建及纯自测不会连接相机或启动原厂应用。生成的应用只有本地签名，尚未公证。日志保存在本机，不自动上传；分享前请检查内容。

若工程位于 iCloud 同步文件夹，文件提供程序可能为 `.app` 添加 Finder 元数据，影响严格签名检查。可在同步目录之外构建：

```sh
GUARDIAN_OUTPUT_DIR="$HOME/Library/Caches/LUMIX Connection Guardian/build" ./build.sh
GUARDIAN_OUTPUT_DIR="$HOME/Library/Caches/LUMIX Connection Guardian/build" ./package.sh
```

打包脚本只包含本项目应用、文档、许可证及已经获准公开的捐赠图；不包含官方 Tether、照片或本机日志。

## 支持开发

捐赠完全自愿。感谢支持后续适配和验证。

<img src="https://raw.githubusercontent.com/easonzhangbin/lumix-tether-macos-fix/main/assets/alipay-donate.jpg" alt="支付宝捐赠二维码" width="240">
