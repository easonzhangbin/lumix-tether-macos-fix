# LUMIX S1H 的 macOS 联机工具

[English](README.md)

## S1H Native Tether 0.1.16

**面向 Apple 芯片 Mac 和松下 DC-S1H 的独立 USB 联机拍摄工具。**

这个项目起于一台 DC-S1H 在较新的 macOS 测试环境里难以连上原厂 LUMIX Tether。我们希望继续用这台相机做棚拍，因此用原生 AppKit 界面和 USB／PTP 通信进程，提供取景、遥控快门和原片传输。应用可独立运行。 [松下公布的兼容信息与下载](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)

[下载 Native Tether 0.1.16（Apple 芯片 PKG）](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.16/S1H-Native-Tether-0.1.16-arm64.pkg) · [发布说明与 SHA-256](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.16) · [安装与源码](experiments/native-tether/README.zh-CN.md)

- 取景支持 100% 实际像素和 200% 放大。机身设为 MF 后，可单步向前或向后调整支持电子对焦的镜头。
- 支持软件及机身快门、RAW 传输进度、自选保存目录和文件名前缀自动编号。
- 显示 USB 协商速率、相机报告的电量及本地 PTP 接口报告。
- 每次启动尝试连接。**断线后重试**默认开启，核实当前用户的 macOS 相机服务占用接口后，每次中断最多自动释放一次。点击**停止**或退出可结束本次尝试。 [恢复连接指南](experiments/native-tether/README.zh-CN.md#恢复连接)

构建目标为 Apple 芯片及 macOS 12 或更高版本。实机测试使用 DC-S1H 和运行 macOS 27.0.1 的 Apple M1 Max Mac，已验证 1600 × 1072 实时取景、镜头双向调焦，以及同一会话连续两张 12000 × 8000 RW2 的保存与完整解码。

## LUMIX Connection Guardian

<img src="experiments/connection-guardian/assets/GuardianAppIcon-source-v1.png" alt="LUMIX 连接守护应用图标" width="120">

**让 S1H 重新连上 Mac，继续使用原厂 Tether 拍摄。**

面向 Apple Silicon Mac 的独立菜单栏工具：准备 S1H 的 USB 连接，交给官方 Tether 2.12，再监测连接和应用状态。实时预览、拍摄、光圈、快门、ISO、白平衡及原片保存继续由松下程序提供；Guardian 负责连接恢复，以及清楚地结束本次拍摄。

[下载 Guardian 0.2.5 测试版（Apple Silicon DMG）](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/guardian-v0.2.5/LUMIX-Connection-Guardian-0.2.5-arm64.dmg) · [版本说明与 SHA-256](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5) · [详细说明](experiments/connection-guardian/README.zh-CN.md) · [早期恢复脚本](docs/CLI.zh-CN.md)

当前为在一套 S1H 环境验证的社区测试版，与松下或 Apple 无隶属关系。用户需另行安装官方 Tether；下载包只包含本项目应用及辅助程序。

## 0.2.5 摇摇乐诊断

在 Tether 连好 S1H 后，从守护菜单选**开始摇摇乐诊断…**，选择 Tether 的导入文件夹。等诊断显示就绪，再拍一张 XL。守护工具检查该文件夹及其直接日期子目录中是否到达结构完整的 12000×8000 DC-S1H RW2。

从就绪起 30 秒内未收到完整 RAW 时，守护工具会保存可取得的本地日志和线程采样。等待期间也可点击**立即保存诊断**抓取现场。启动诊断时暂停自动恢复，退出诊断模式后仍保持暂停。通过**显示本次诊断文件夹**可在本机查看报告。

高分辨率 RAW 偶发传输卡住的问题仍待解决。此前五秒 USB 热拔插测试需要取电池复位，0.2.5 尚未复测热拔插。[详细诊断步骤](experiments/connection-guardian/README.zh-CN.md#摇摇乐诊断)

## 外部接口占用

新鲜检查确认第三方软件持有接口时，会显示红字，例如 **“接口被 NegPy 占用，请先在该软件断开相机或正常退出”**。信息未知或过期后清除旧名称及红色警告。检测到某相机软件正在运行，是另一项保守恢复拦截，不等于证明它持有接口。正常 macOS `ptpcamerad` 服务与第三方软件分开处理，只有守卫核对通过才可恢复该服务；Guardian 不会自动关闭其他相机软件。

等待占用释放不会消耗 I/O 重试次数。若 Tether 仍运行，其他软件释放相机后也不会开始 USB 操作；需要正常重启 Tether 时，请使用**重新连接**。

### 此前 0.2.3 修正

修正 macOS 成功返回 NULL 空迭代器、表示没有匹配 USB 服务时被误判为检查错误的问题。真实 API 错误或非 NULL 迭代器失效时仍停止恢复，递归注册表检查未放宽。此改动修复空设备检测，不代表已解释下述相机卡住的原因。

S1H 未在 USB 中重新枚举时，此测试版无法开始连接恢复。

### 此前 0.2.2 修正

恢复前会明确列出需要正常退出的其他相机客户端（例如“预览”）。这表示保守检查发现程序在运行，不能据此证明它实际占用了相机接口。接口实际占用者单独显示。所有守护器启动入口均经过连接检查，Tether 未运行时不再直接绕过 USB 准备；阻塞及解除也写入事件日志。

## 功能

| 操作 | 实际行为 |
| --- | --- |
| 开始守护 | 检查相机及其他客户端，在 Tether 未运行时准备新的 USB／PTP 会话，再打开官方程序。开始也表示允许在守卫检查通过时处理本用户的系统相机服务占用。 |
| 状态监测 | 分开显示 USB 检测、链路协商速率、Tether 进程及拍摄连接。已知 Tether 运行时不开始新的 USB 恢复；实际预览与拍摄须在 Tether 内确认。 |
| 仅暂停自动恢复 | 停止后续自动恢复，保留 Tether 当前状态。 |
| 结束本次拍摄 | 先停自动恢复，再请求 Tether 正常退出；守护工具继续保留，不会自动重开 Tether。请在照片传输完成后使用。 |
| 重新连接 | 请求正常退出 Tether，再准备连接并重新打开。退出超时后提供单独的“强制退出／强制重启”操作，不会自动强杀 Tether。 |
| 摇摇乐诊断 | 监测 Tether 导入文件夹。XL RW2 未到达时保存本地日志与线程状态，暂停自动恢复以保留现场。 |

物理断开 USB 后，可以请求由 Guardian 启动且身份仍一致的 Tether 正常退出。恢复有重试上限；占用未知或其他相机软件运行时，守卫可拒绝服务恢复。它无法提供跨应用 USB 禁入锁，也不能修复所有 Tether 内部挂起。

## 工作原理

1. 只读检查 USB、接口登记占用者及运行中的相机软件，使用新鲜观察结果。
2. 外部软件被确认持有接口，或检测到其他相机客户端时，等待准备条件满足。红字是请你在对应软件断开相机或正常退出的提示。
3. Tether 已运行时只监测。**开始守护**及**检查连接并打开 Tether**不会修复正在运行的会话；需要重启时用**重新连接**，先请求正常退出。
4. Tether 未运行且检查通过后，原生辅助程序排空完整的残留 PTP 响应并验证新会话。若已核实的本用户相机服务阻止访问，明确点击开始时的授权允许有上限、受守卫保护的服务恢复；它可能结束该特定服务实例，不会结束任意相机软件。
5. 启动前再次核对相机身份、进程及占用。期间出现新的拦截条件会保留准备任务，不绕过检查。
6. 打开另行安装、未经修改的官方 Tether，在其中选择相机、开始及 LV；实际预览、拍摄、参数控制及原片保存由松下应用完成。

## 安装与使用

1. 从[松下官方下载页](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)安装 **LUMIX Tether 2.12**，放在 `/Applications` 或 `~/Applications`。
2. 打开 Guardian 测试版 DMG，将 **LUMIX Connection Guardian.app** 拖到“应用程序”快捷方式。[Guardian 0.2.5 下载页](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5)
3. 退出其他相机／照片导入软件，用数据线连接 S1H，相机选择 **PC(Tether)**。
4. 打开 Guardian，点击**开始守护**。在官方 Tether 中选择相机、点击**开始**及 **LV**，确认预览后，向自己指定的保存目录试拍。
5. 拍摄及文件传输完成后，点击**结束本次拍摄**。关闭状态窗口仍会保留菜单栏图标。

首次启动为空闲状态，不安装登录项或持久系统服务。Guardian 界面跟随中文／英文系统首选语言；启动 Tether 时使用它已有的语言参数，不支持的语言回退英文，不替换厂商资源。

应用采用本地 ad-hoc 签名，**尚未进行 Developer ID 签名及公证**。其他 Mac 可能阻止下载的应用；请核对源码与来源，并按 [Apple 官方安全打开说明](https://support.apple.com/en-us/102445)操作。本工具不关闭系统安全保护。macOS 仍可能为当前使用的程序单独请求 USB 配件或可移动宗卷权限。

## 遇到问题时，按这个顺序处理

1. **先停止拍摄并等照片传输结束。** 保持 USB 插牢、相机开机并选择 **PC(Tether)**，查看守护状态。
2. **按“恢复前检查”提示正常退出其他程序。** 例如“预览”、图像捕捉或其他联机软件；先保存未完成的编辑。显示程序在运行不等于已证明它占用相机。
3. **USB 已识别、Tether 却等连接：** 点击菜单栏守护图标 → **重新连接（正常重启 Tether）**。等旧 Tether 正常退出，守护准备连接并打开新窗口。单点“开始守护”不会重启已运行的 Tether；准备期间不要再从 Dock／Finder 手动打开 Tether。
4. **Tether 未运行：** 通过守护的 **检查连接并打开 Tether**（也可按 ⌘O）启动，等待准备完成。官方相机列表显示 DC-S1H 后，点 **开始**，再点 **LV** 确认画面。USB 已连接、进程已运行本身不代表可以拍摄。
5. **显示“未检测到相机”：** 先检查相机电源、PC(Tether) 和数据线。**若卡在“请稍后”且无法正常 OFF：** 暂停守护 → 断开 USB → 确认没有录制或存储卡写入 → 电源 OFF、取出电池约 10 秒 → 装回开机。恢复正常后接回 USB、选择 PC(Tether)，再回到第 4 步。未重新枚举的相机无法由守护发送 USB／PTP 恢复指令。
6. **仍失败时停止重复拔插。** 查看守护的“恢复前检查”及“显示诊断与日志文件夹”；保留最近失败时间。正常退出超时时不要把它当作相机已空闲，也不要在文件传输中强制退出。

收工建议顺序：**传输结束 → 结束本次拍摄 → 确认 Tether 已退出 → 再拔 USB。** 此顺序尚未在本轮实机复测；当前实时预览中的五秒热拔插测试已失败，不能保证自动恢复。

## 已验证与待验证

| 项目 | 观察结果 |
| --- | --- |
| 硬件 | Panasonic DC-S1H；Apple M1 Max，MacBookPro18,2 |
| 系统／官方软件 | macOS 27.0.1（26A434）；Tether 2.12.0.5 |
| USB | USB3 协商 5Gbps；此前恢复脚本也在 USB2 480Mbps 恢复过预览 |
| 实际拍摄 | 一次 Guardian 恢复交接后，官方预览正常，并拍摄保存一张 6000×4000 RAW，36,048,384 字节 |
| 相机控制 | 光圈、快门、ISO、白平衡色温在原厂界面单独完成修改及恢复验证 |
| 会话操作 | 仅暂停会保留 Tether；结束拍摄能正常退出，短时间观察未自动重开 |
| 正常退出后恢复 | 0.2.3 从观察到旧进程退出至核实新 Tether 启动耗时 3.877 秒；之后另行确认实际官方实时预览通过 |
| 占用提示 | 已安装的 0.2.4 在真实 NegPy 连接时，接口占用、恢复前检查和处理提示均显示红字；守护保持暂停 |
| 摇摇乐诊断 | 0.2.5 在等待超时后保存了本地报告与线程采样，并保持原 Tether 会话运行 |
| 自动检查 | 379 项通过，包括设备身份（16）、服务守卫（51）、事件日志（50）、RAW 到达检测（25）和控制器策略（237）。检查无需连接相机。 |

0.2.2 从观察到旧进程退出至核实新 Tether 启动耗时 3.852 秒，之后另行确认实时预览通过。但随后拔下 USB、等待五秒再接回的测试失败：相机停在“Please wait”，无法正常关机，需取出并重新装入电池断电复位。**0.2.3 相同五秒重连测试也失败。** 检测到断开后 0.968 秒，Tether 已正常退出，但相机未重新枚举，因此没有继续运行恢复或启动程序。修正后的只读检查成功报告零设备且无错误；相机仍需再次取电池复位，卡住的根因未证。

建议顺序：拍摄及传输完成 → **结束本次拍摄** → 确认 Tether 已退出 → 再断开 USB。此顺序尚未在本轮实机复测。若相机已卡住，先暂停守护；确认无写入活动后断开 USB、尝试正常 OFF，仍不能关机时再进行电池断电复位。

本次五秒热拔插已失败；更多拔插场景、睡眠唤醒、长时间拍摄、连拍、其他 Mac／系统及其他机型仍待验证。**本测试版的严格身份检查仅面向 S1H，不支持直接用于 S1R、S1 等其他机型。** 仅含 arm64；macOS 12 编译目标不代表所有后续版本都已实测。

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

早期 `.command` 工具保留为源码。当前 Guardian 版本提供 DMG 和 SHA-256 校验文件，CI 用于构建验证。[脚本指南](docs/CLI.zh-CN.md) · [技术记录与边界](docs/TECHNICAL.md) · [参与贡献](CONTRIBUTING.md) · [问题反馈](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml)

## 支持开发

可通过支付宝自愿支持后续适配与测试。

<img src="assets/alipay-donate.jpg" alt="支付宝支持开发收款码" width="240">

## 许可

本项目代码及文档采用 [MIT 许可](LICENSE)，© 2026 Eason Zhang / easonzhangbin。应用图标为原创生成资产。松下 LUMIX Tether、松下图形及 Qt 属于第三方软件，不在此分发；LUMIX、Panasonic 商标归各自权利人所有。
