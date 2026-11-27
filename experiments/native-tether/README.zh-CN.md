# S1H Native Tether

[English](README.md)

面向 Apple 芯片 Mac 的松下 **DC-S1H** USB 联机拍摄工具。我们遇到的问题是 DC-S1H 在较新的 macOS 测试环境里难以连上原厂 LUMIX Tether。为继续使用这台相机做棚拍，我们用原生 AppKit 界面和 USB／PTP 通信进程，将取景、遥控快门、原片传输和保存目录放进同一个应用。 [松下公布的兼容信息与下载](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)

[下载 0.1.14（Apple 芯片 PKG）](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.14/S1H-Native-Tether-0.1.14-arm64.pkg) · [便携版 ZIP](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.14/S1H-Native-Tether-0.1.14-arm64.zip) · [发布说明与 SHA-256](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.14)

## 安装与拍摄

1. 用发布页对应的 SHA-256 文件核对 PKG，双击完成安装，再从「应用程序」打开 **S1H Native Tether.app**。如选择便携版 ZIP，请核对 ZIP 的校验值，解压后将应用移到「应用程序」。PKG 安装包未签名，应用使用 ad-hoc 签名，发布包尚未经过 Apple 公证。如果 macOS 阻止打开，先确认来源并核对校验值，再决定是否打开。 [Apple 安全打开应用说明](https://support.apple.com/zh-cn/102445)
2. 退出 LUMIX Tether、图像捕捉、「预览」等可能占用相机的应用。使用 USB 数据线接入 S1H，在机身选择 **PC(Tether)**，然后点击**连接**。Native Tether 可独立运行。
3. 选择照片保存文件夹，或使用默认的 `~/Pictures/S1H Tether`。点击**拍摄并保存**时默认**仅保存到 Mac**。按机身快门时，沿用相机当前的联机存储目标。
4. 等待照片传输完成，再点击**停止**，然后断开 USB 或切换到其他相机应用。

## 0.1.14 的主要功能

- **实时取景与相机参数**包括适合窗口、100% 实际像素、可拖动的 200% 放大和构图九宫格。光圈、快门、ISO 和白平衡的可选项以相机报告为准。
- **远程对焦**提供「向前对焦」和「向后对焦」，每次点击移动一步。将机身设为 MF，并使用支持电子调焦的镜头。若按钮不可用，切换 MF 后刷新相机参数。
- **原片传输**支持软件及机身快门。应用显示传输进度，在保存为正式文件前检查 RAW 完整性，并将未完成的下载保留为 `.part` 文件。**照片文件命名…**可为保存到 Mac 的原片添加前缀并自动编号，例如 `样片_0001.RW2`。
- **机身快门存储目标**显示相机当前的联机存储设置及存储卡状态。切换后由相机回读确认。软件快门使用单独的临时目标。
- **状态与诊断**包括 USB 协商速率。相机支持时，点击**刷新相机参数**也能读取电量。**取景与诊断 → 相机接口报告**列出相机上报的 PTP 操作、事件与属性，报告省略相机序列号。

拍摄 XL RAW 时，在机身选择**拍照 → 画质 1 → 高分辨率模式 → 开始**。USB 速率表示链路的协商档位，实际文件传输速度随相机、数据线和 Mac 而变化。

## 实机验证与适用范围

构建目标为 **Apple 芯片上的 macOS 12 或更高版本**。实机用的是 **DC-S1H 和搭载 Apple M1 Max 的 Mac**，系统为 **macOS 27.0.1（26A434）**。已验证 **1600 × 1072** 实时取景、镜头双向 MF 调整，以及同一会话连续两张 **12000 × 8000 RW2** 的保存与完整解码。更多机型、系统版本和长时间拍摄尚待验证。「存储卡＋Mac」需要机身识别存储卡，也有待进一步实测。

## 恢复连接

若界面显示**修复连接**，表示相机仍有一个 PTP 会话。确认机身空闲、写卡灯熄灭后，再确认修复。遇到需要检查拍摄结果或旧会话的情况，应用会暂停自动重连。

会话日志及最近一帧预览留在本机的 `~/Library/Caches/S1H Native Preview/experimental/sessions/`。反馈时请附应用版本、macOS 版本、相机型号及固件、复现步骤，以及必要的脱敏日志摘录。 [GitHub 问题反馈](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues)

## 从源码构建

在 Apple 芯片 Mac 上安装 Xcode 命令行工具，然后在本目录运行 `./build.sh`。脚本会编译通信进程，运行离线自检，并签名与验证 `build/S1H Native Tether.app`。

如果同步文件夹附加的 Finder 元数据影响签名，使用 `NATIVE_TETHER_OUTPUT_DIR="$HOME/Downloads/S1H Native Tether Build" ./build.sh` 将构建输出放到本地「下载」文件夹。
