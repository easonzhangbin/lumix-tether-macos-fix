# LUMIX Connection Guardian

[English](README.md)

<img src="experiments/connection-guardian/assets/GuardianAppIcon-source-v1.png" alt="LUMIX 连接守护应用图标" width="120">

**让 S1H 重新连上 Mac，继续使用原厂 Tether 拍摄。**

面向 Apple Silicon Mac 的独立菜单栏工具：准备 S1H 的 USB 连接，交给官方 Tether 2.12，再监测连接和应用状态。实时预览、拍摄、光圈、快门、ISO、白平衡及原片保存继续由松下程序提供；Guardian 负责连接恢复，以及清楚地结束本次拍摄。

[下载 Guardian 0.2.1 测试版](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.1) · [源码与详细说明](experiments/connection-guardian/README.zh-CN.md) · [早期恢复脚本](docs/CLI.zh-CN.md)

当前为在一套 S1H 环境验证的社区测试版，与松下或 Apple 无隶属关系。用户需另行安装官方 Tether；下载包只包含本项目应用及辅助程序。

## 功能

| 操作 | 实际行为 |
| --- | --- |
| 开始守护 | 检查相机及其他客户端，在 Tether 未运行时准备新的 USB／PTP 会话，再打开官方程序。开始也表示允许在守卫检查通过时处理本用户的系统相机服务占用。 |
| 状态监测 | 分开显示 USB 检测、链路协商速率、Tether 进程及拍摄连接。已知 Tether 运行时不开始新的 USB 恢复；实际预览与拍摄须在 Tether 内确认。 |
| 仅暂停自动恢复 | 停止后续自动恢复，保留 Tether 当前状态。 |
| 结束本次拍摄 | 先停自动恢复，再请求 Tether 正常退出；守护工具继续保留，不会自动重开 Tether。请在照片传输完成后使用。 |
| 重新连接 | 请求正常退出 Tether，再准备连接并重新打开。退出超时后提供单独的“强制退出／强制重启”操作，不会自动强杀 Tether。 |
| 本地诊断 | 轮转记录操作、恢复步骤、启动请求及进程观察事件，并保留原有辅助程序诊断日志。 |

物理断开 USB 后，可以请求由 Guardian 启动且身份仍一致的 Tether 正常退出。恢复有重试上限；占用未知或其他相机软件运行时，守卫可拒绝服务恢复。它无法提供跨应用 USB 禁入锁，也不能修复所有 Tether 内部挂起。

## 安装与使用

1. 从[松下官方下载页](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)安装 **LUMIX Tether 2.12**，放在 `/Applications` 或 `~/Applications`。
2. 下载并解压 [Guardian 测试版 ZIP](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.1)，将 **LUMIX Connection Guardian.app** 放进应用程序文件夹。
3. 退出其他相机／照片导入软件，用数据线连接 S1H，相机选择 **PC(Tether)**。
4. 打开 Guardian，点击**开始守护**。在官方 Tether 中选择相机、点击**开始**及 **LV**，确认预览后，向自己指定的保存目录试拍。
5. 拍摄及文件传输完成后，点击**结束本次拍摄**。关闭状态窗口仍会保留菜单栏图标。

首次启动为空闲状态，不安装登录项或持久系统服务。Guardian 界面跟随中文／英文系统首选语言；启动 Tether 时使用它已有的语言参数，不支持的语言回退英文，不替换厂商资源。

应用采用本地 ad-hoc 签名，**尚未进行 Developer ID 签名及公证**。其他 Mac 可能阻止下载的应用；请核对源码与来源，并按 [Apple 官方安全打开说明](https://support.apple.com/en-us/102445)操作。本工具不关闭系统安全保护。macOS 仍可能为当前使用的程序单独请求 USB 配件或可移动宗卷权限。

## 已验证与待验证

| 项目 | 观察结果 |
| --- | --- |
| 硬件 | Panasonic DC-S1H；Apple M1 Max，MacBookPro18,2 |
| 系统／官方软件 | macOS 27.0.1（26A434）；Tether 2.12.0.5 |
| USB | USB3 协商 5Gbps；此前恢复脚本也在 USB2 480Mbps 恢复过预览 |
| 实际拍摄 | 一次 Guardian 恢复交接后，官方预览正常，并拍摄保存一张 6000×4000 RAW，36,048,384 字节 |
| 相机控制 | 光圈、快门、ISO、白平衡色温在原厂界面单独完成修改及恢复验证 |
| 会话操作 | 仅暂停会保留 Tether；结束拍摄能正常退出，短时间观察未自动重开 |
| 自动检查 | 236 项通过：设备身份 16、服务守卫 43、事件日志 49、控制器／策略 128；均采用纯检查或模拟环境 |

Guardian 反复拔插、睡眠唤醒、长时间拍摄、连拍、其他 Mac／系统及其他机型仍待验证。**本测试版的严格身份检查仅面向 S1H，不支持直接用于 S1R、S1 等其他机型。** 仅含 arm64；macOS 12 编译目标不代表所有后续版本都已实测。

**5Gbps 是 USB 协商档位，不是实时 MB/s。** 本机未发现供被动监测使用的可靠相机吞吐计数；不会把落盘速度或未测量的 0 当成 USB 实时速度。

## 本地事件日志

`~/Library/Logs/S1H Connection Guardian/events.jsonl` 记录时间、运行／请求编号、操作及结果。每份最多 1MiB，保留三份轮转历史；可从**显示诊断与日志文件夹**查看。

守护器提交的启动请求与系统返回的应用分别记录。外部观察到的进程标为 `external_or_unknown`，不会根据 `launchd` 猜测用户操作，也不保证能确定是谁创建了进程。事件日志不声称已经曝光或可以拍摄。

事件字段不含相机序列号、照片、完整路径或原始检查对象。独立辅助程序日志仍含进程元数据，分享前请检查摘录。日志不会自动上传。

## 从源码构建

Apple Silicon Mac 安装 Xcode Command Line Tools 后执行：

```sh
./experiments/connection-guardian/build.sh
./experiments/connection-guardian/package.sh
```

构建和自测不会连接相机或打开 Tether。工程位于 iCloud 同步目录时，请使用[详细说明](experiments/connection-guardian/README.zh-CN.md)中的独立输出目录，避免文件提供程序元数据影响严格签名验证。

早期 `.command` 工具仍保留在 [v1.0.1](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/v1.0.1)，用法见[脚本指南](docs/CLI.zh-CN.md)。主分支还包含尚未单独发布的 CLI 1.0.2 守卫修正。[技术记录与边界](docs/TECHNICAL.md)、[参与贡献](CONTRIBUTING.md)、[问题反馈](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml)。

## 支持开发

可通过支付宝自愿支持后续适配与测试。

<img src="assets/alipay-donate.jpg" alt="支付宝支持开发收款码" width="240">

## 许可

本项目代码及文档采用 [MIT 许可](LICENSE)，© 2026 Eason Zhang / easonzhangbin。应用图标为原创生成资产。松下 LUMIX Tether、松下图形及 Qt 属于第三方软件，不在此分发；LUMIX、Panasonic 商标归各自权利人所有。
