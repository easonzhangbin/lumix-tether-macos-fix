# S1H Native Tether

[English](README.md)

面向 Apple 芯片 Mac 的松下 **DC-S1H** USB 联机拍摄工具。AppKit 界面搭配自带的 USB／PTP 通信进程，可独立于 LUMIX Tether 运行。

[下载 0.1.6（Apple 芯片）](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.6/S1H-Native-Tether-0.1.6-arm64.zip) · [版本说明与校验值](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.6)

## 连接与拍摄

1. 解压 ZIP，打开 **S1H Native Tether.app**。应用使用 ad-hoc 签名，尚未经过 Apple 公证。如果 macOS 阻止打开，先确认来源并核对压缩包校验值。 [Apple 安全打开应用说明](https://support.apple.com/zh-cn/102445)
2. 退出 LUMIX Tether、图像捕捉、「预览」等可能占用相机的应用。使用 USB 数据线接入 S1H，在机身选择 **PC(Tether)**，然后点击**连接**。
3. 选择照片保存文件夹，或使用默认的 `~/Pictures/S1H Tether`。点击**拍摄并保存**时默认**仅保存到 Mac**。按机身快门时，沿用相机当前的联机存储目标。
4. 等待照片传输完成，再点击**停止**，然后断开 USB 或切换到其他相机应用。

若界面显示**修复连接**，表示相机仍有一个 PTP 会话。确认机身空闲、写卡灯熄灭后，再确认修复并重新建立会话。会话日志及最近一帧预览存放在本机的 `~/Library/Caches/S1H Native Preview/experimental/`。

## 功能与实机验证

- 在一台 DC-S1H 和一台运行 macOS 27.0.1 的 Apple 芯片 Mac 上，实测实时取景达到 **1600 × 1072**。光圈、快门、ISO 和白平衡的可选项由相机报告。
- 已验证 RAW 保存到 Mac，也实测机身快门拍摄的 **12000 × 8000 RW2** 可以传回。在机身选择**拍照 → 画质 1 → 高分辨率模式 → 开始**即可进入摇摇乐模式。连续 XL 传输和「存储卡＋Mac」仍待实机验证。
- 0.1.6 为 ISO **AUTO** 和「手动白平衡 **1–4**」显示正确名称，沿用守护工具图标，并给「连接／修复连接」添加了 Border Beam。开启系统「减少动态效果」时显示静态光束。

构建目标为 Apple 芯片 Mac 上的 macOS 12 或更高版本。实机验证限于上述配置，其他系统版本、相机型号及长时拍摄尚待验证。

## 从源码构建

在 Apple 芯片 Mac 上安装 Xcode 命令行工具，然后在本目录运行 `./build.sh`。脚本会编译通信进程，运行离线自检，并签名与验证 `build/S1H Native Tether.app`。

如果同步文件夹附加的 Finder 元数据影响签名，使用 `NATIVE_TETHER_OUTPUT_DIR="$HOME/Downloads/S1H Native Tether Build" ./build.sh` 将构建输出放到本地「下载」文件夹。
