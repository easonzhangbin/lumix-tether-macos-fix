> 菜单栏 Guardian 应用见[项目介绍](https://github.com/easonzhangbin/lumix-tether-macos-fix/blob/main/README.zh-CN.md)。本页说明独立的恢复脚本用法。

# LUMIX Tether macOS USB 连接修复

[English](https://github.com/easonzhangbin/lumix-tether-macos-fix/blob/main/docs/CLI.md)

CLI 以[仓库源码](https://github.com/easonzhangbin/lumix-tether-macos-fix/tree/main)保留，不再提供旧版下载；请按下方[从源码构建](#从源码构建)使用。二进制发布仅保留当前 [Guardian 0.2.4 测试版](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.4)，其应用包与本页 CLI 流程分开。

通过 `.command` 脚本运行的小型 Apple Silicon USB 恢复工具：先清理未读完的 PTP 响应，再打开松下 LUMIX Tether 2.12。已在一套 Panasonic DC-S1H 环境上恢复 USB2、USB3 联机连接，并验证 Tether 实时预览正常。

**请在每次启动 Tether 前先运行脚本。** 已观察到 USB3 拔插重连后问题复发；本工具是启动前恢复流程，不是永久驱动或固件补丁。

本项目由社区独立开发，与松下或 Apple 没有隶属关系。

## 包含内容

- **恢复S1H连接.command** 和 **Restore S1H Connection.command**，两个等效脚本入口。
- **重启相机服务并恢复连接.command** 和 **Restart Camera Service and Restore.command**，接口仍被相机服务占用时，由用户明确选择的重启入口。
- 使用原生 IOUSBHost 的恢复程序，位于 `bin/s1h_iousbhost_probe`。
- 带占用核对守卫的服务检查程序，位于 `bin/s1h_camera_service`。
- 自动选择 Tether 原有界面语言，也可通过命令行指定语言。

本地构建的 `dist/LUMIX Tether USB Fix/` 目录包含脚本与 `bin/`，请保持它们在一起。构建产物**不包含 Tether、松下安装包或图标，也不包含 Qt 库**。请自行安装官方 Tether。

## 已验证环境

| 项目 | 实际测试配置 |
| --- | --- |
| 相机 | Panasonic DC-S1H |
| Mac | MacBookPro18,2，Apple M1 Max |
| macOS | 27.0.1，构建号 26A434 |
| Tether | 2.12，构建号 2.12.0.5 |
| USB2 | 协商链路速率 480Mbps；Tether 实时预览恢复 |
| USB3 | 协商链路速率 5Gbps；Tether 实时预览恢复 |

上述速率是 USB 协商链路速率，并非实测文件传输速度；尚未做长时间稳定性测试，相机重连后可能需要再次恢复。

恢复程序只面向 **arm64／Apple Silicon**，构建部署目标为 macOS 12。实际硬件验证仅覆盖上表中的 macOS 27.0.1，部署目标不代表已验证所有后续系统版本。此版本不支持 Intel Mac。

**DC-S1R、DC-S1 以及其他 LUMIX 机型均未实测。** 部分机型可能共用 USB 标识，不能仅凭标识相同推断本恢复方法适用。

## 使用方法

1. 从[松下官方下载页](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)下载并安装 **LUMIX Tether 2.12**。
2. 获取[仓库源码](https://github.com/easonzhangbin/lumix-tether-macos-fix/tree/main)，按[从源码构建](#从源码构建)操作，再使用生成的 `dist/LUMIX Tether USB Fix/` 目录；旧 Release 和 CI 下载不再作为安装来源。
3. 退出 Tether 和所有其他相机、照片导入软件，并在使用 Tether 期间保持其他软件关闭。使用支持数据传输的 USB 线连接 S1H，在相机上选择 **PC(Tether)／PC（联机拍摄）**。
4. 双击 **恢复S1H连接.command** 或 **Restore S1H Connection.command**。脚本会在终端中运行，并在 `/Applications` 和 `~/Applications` 查找官方 Tether 2.12。
5. 清理和新会话验证成功后，脚本会打开 Tether。选择相机，点击 **Start／开始**，再点击 **LV** 打开实时预览。

每次启动 Tether 时，包括相机重新插线后，都请先运行本工具。一次成功连接不能保证问题不再出现。默认恢复流程不会强制结束相机软件或自动重启 macOS 相机服务。

如果 macOS 提示 Tether 或终端访问相机的可移动宗卷，或提示连接 USB 配件，请允许当前使用的应用所需访问。若恢复验证成功但 Tether 仍无法连接，请在**系统设置 → 隐私与安全性 → 文件与文件夹**中检查实际 Tether 2.12 应用的权限。协议恢复成功后，仍可能需要完成系统权限授权。

若官方应用不在默认位置，可在解压后的工具目录中执行：

```sh
./"恢复S1H连接.command" --tether-app "/path/to/LUMIX Tether.app"
```

指定的应用必须是官方 Tether 2.12。

### 减少其他软件重新占用相机

恢复程序必须先释放 USB 接口，官方 Tether 才能打开它。在当前“先恢复、再启动”的设计下，如果恢复程序常驻并独占锁住 USB，也会阻止 Tether 连接。因此，本工具**不保证将接口永久保留给 Tether**。

连接丢失时请按以下顺序处理：

1. 退出全部相机／导入软件，并在使用 Tether 期间保持关闭。
2. USB 重连或 Mac 从休眠唤醒后，先退出 Tether、确认 PC(Tether)，再运行**普通恢复脚本**。
3. 若仍提示接口被占用，运行 `--diagnose`；只有诊断确认相机服务持有接口时，才选择[明确的服务重启入口](#相机服务仍占用接口时)。
4. 守卫拒绝时，根据诊断退出对应应用，并只保留一台相机连接。不要强制结束未知占用者。若仍无法确认占用关系，保存工作后重启 Mac，作为最后一个受控恢复步骤；开机后再运行普通恢复。

#### 可选：减少导入软件自动启动

先退出 Tether，再打开“图像捕捉”并选中已连接的相机。通过“操作／选项”控制找到**连接此［设备］时打开**菜单；若有**无应用程序（No application）**选项，选择它。不同 macOS 版本的位置可能不同，设置后退出“图像捕捉”。可参考 [Apple 的设备连接菜单说明](https://support.apple.com/guide/image-capture/image-capture-imgcp1003/mac)及 [Capture One 官方的 No Application 操作说明](https://support.captureone.com/hc/en-us/articles/360002423997-Why-does-Capture-One-automatically-start-every-time-I-connect-my-camera-CF-card-or-iPhone)。

这只减少自动拉起应用，不能阻止已经运行的程序发现或访问相机，也不等于锁住 USB 接口。

### 相机服务仍占用接口时

v1.0.1 增加了只读占用诊断，以及独立、需明确选择的服务重启模式。普通恢复不会自动重启服务；恢复失败后，脚本只读检查占用情况，并在适用时提示使用明确的重启入口。

仅收集诊断，不打开 USB 接口、不执行 PTP 探针、不启动 Tether、不重启服务：

```sh
./"恢复S1H连接.command" --diagnose
```

若诊断报告 `ptpcamerad` 仍持有接口：

1. 先退出**所有相机和照片导入软件**，包括仍在运行的 Tether、“预览”、“图像捕捉”和“照片”。
2. 双击 **重启相机服务并恢复连接.command**，或在终端明确选择同一模式：

   ```sh
   ./"恢复S1H连接.command" --restart-camera-service
   ```

3. 工具核对占用与进程身份后，依次尝试服务重启、严格 USB 恢复，最后才启动 Tether。守卫检查失败会停止后续步骤。

**此模式会明确中断当前用户的 PTP 相机服务。** 守卫重启可能先发送普通退出请求；若该服务未在有限等待时间内退出，再强制停止同一个已核对的实例。虽然会检查已知相机软件和接口占用，但工具无法证明所有后台 XPC 客户端都已空闲，因此必须先退出全部相机／导入软件。占用来源未知、涉及其他 PTP 相机，或仍有相机软件运行时，工具可能拒绝重启。

此模式不使用 `sudo`，不更改安全设置，也不安装常驻服务。`--diagnose` 不能与 `--check` 或 `--restart-camera-service` 同时使用。每次诊断或恢复都会输出日志路径，分享摘录前请先检查私人路径等信息。

### 语言

每次通过脚本启动时，都会根据系统首选语言显式选择 Tether 语言。Tether 支持 `zh`、`en`、`ja`、`de`、`es`、`fr`、`it`、`ru`，其他首选语言回退为英文。

也可以手动指定语言，或仅运行不访问相机的自检：

```sh
./"恢复S1H连接.command" --language zh
./"恢复S1H连接.command" --language en
./"恢复S1H连接.command" --language auto --check
```

`--language` 也接受其他上述语言代码。Tether 2.12 本身已包含这些翻译；脚本通过原有 `-lang=xx` 参数启用，不替换翻译资源或修改松下程序。

**希望自动随系统语言切换时，请从脚本启动。** 直接打开原厂 Tether 图标，仍可能使用之前保存的英文等语言设置。

### macOS 阻止下载文件打开时

恢复程序采用本地 ad-hoc 签名，尚未使用 Apple Developer ID 签名并公证。从其他 Mac 下载后，Gatekeeper 可能阻止脚本或恢复程序启动。请先核对源码和下载来源；确认信任后，按照 [Apple 官方的安全打开应用说明](https://support.apple.com/en-us/102445)处理。

## 修复原理

在已测试的 S1H 上，bulk-IN 端点残留了未读完的 `GetDeviceInfo` 事务：一个 237 字节的 Data 容器，以及一个 12 字节的 OK Response，事务 ID 均为 0。此时发送新命令会超时。

后来一次 USB3 重连调查还发现了另一层障碍：所有相机软件退出后，macOS PTP 相机服务 `ptpcamerad` 仍持有接口，恢复程序必须等该旧服务实例释放接口后才能访问。“预览”曾登记为客户端，但之后在“预览”已退出时也复现了 USB3 故障。因此，单独关闭“预览”并不是完整修复，这些观察也不能确定故障由它造成。

恢复程序使用 Apple 原生 IOUSBHost API，先读取并丢弃完整的残留容器。只有在**完整容器边界**出现零字节超时，才认为队列已清空；随后严格验证一组新的 `OpenSession` → `GetDeviceInfo` → `CloseSession`，成功后脚本才打开 Tether。

因此，恢复需要同时满足“接口可访问”和“PTP 事务状态干净”两个条件。目前尚未证明残留事务由谁产生，也没有永久修正 Apple 的 USB 栈；不能据此断言所有新版 macOS 的 LUMIX 连接故障都由同一原因造成。详见[技术说明](TECHNICAL.md)。

恢复程序不拍照、不删除图片、不更新固件；日志不记录图像内容或相机序列号。

## 常见问题

**第三方软件持有接口。** 若诊断确认 NegPy 等软件持有接口，请在该软件中断开相机或正常退出。不要用相机服务重启去结束别的程序。仅检测到已知相机软件正在运行，是保守拦截，不代表已证明实际占用。

**实时预览时拔插导致相机卡住。** 本机 Guardian 0.2.2／0.2.3 的五秒 USB 拔插均失败，并需电池断电复位。S1H 未枚举时，CLI 和 Guardian 均无法执行 USB／PTP 恢复。根因未证，0.2.4 尚未重做该测试。建议“传输完成→Guardian 结束本次拍摄，或 CLI 流程中正常退出 Tether→确认退出→再断 USB”，并非新近验证的热插拔修复。

**打开的是 Tether 2.11，或旧快捷方式启动后崩溃。** 请核对实际运行应用的版本。旧 Dock 图标或快捷方式可能仍指向 2.11。此脚本要求官方 Tether 2.12，并拒绝 2.11；旧版应用的崩溃不能用来判断 2.12 的恢复是否失败。

**提示相机或接口被占用。** 退出 Tether 和其他相机客户端，包括正在访问相机的“预览”或导入窗口。若应用退出后仍被占用，可能是旧 `ptpcamerad` 实例继续持有接口。接口占用发生在排空 PTP 响应之前，与发送命令超时属于不同阶段。可先运行 `--diagnose`，再按[明确的服务重启流程](#相机服务仍占用接口时)处理；默认脚本不会自动结束该服务。

**之前能用，重连后又失败。** 已在本次 USB3 测试环境复现。请在启动 Tether 前再次运行恢复脚本；若退出相机软件后仍提示接口被占用，请在问题报告中说明失败阶段和重连顺序。此前一次实时预览成功，不代表系统层问题已被永久修正。

**找不到相机。** 检查电源、数据线、USB 模式，以及 macOS 是否弹出配件连接许可。本工具无法修复物理 USB 连接缺失。

**其他机型不能使用。** 请按未验证环境报告准确型号，不要因 USB ID 相同而推定兼容。

报告问题请使用 [Bug 模板](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml)，只提交相关状态和错误行。不要公开相机序列号或未脱敏的完整崩溃报告。

## 从源码构建

源码在 Apple Silicon Mac 上使用 Xcode Command Line Tools 构建，只依赖系统框架，无需 Homebrew、Python 或第三方库。

在仓库根目录执行：

```sh
./scripts/build.sh
./scripts/self-check.sh
./scripts/package.sh
```

构建会生成 `dist/LUMIX Tether USB Fix/`，其中包含普通恢复、明确选择的服务重启 `.command` 入口，以及 `bin/` 中的辅助程序。打包脚本在 `dist/` 生成本地 arm64 ZIP 及 SHA-256 校验文件。自检只验证产物，不访问相机或运行 Tether。各脚本的完整参数可通过 `--help` 查看。

## 参与贡献

请阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)。欢迎补充其他机型和系统版本的实测结果，并区分“握手成功”和“Tether 实时预览已经验证”。

## 支持开发

如果这个工具对你的工作有帮助，可以通过支付宝支持开发。支持完全自愿。

<img src="../assets/alipay-donate.jpg" alt="支付宝支持开发收款码" width="240">

## 许可与第三方软件

本项目自行编写的脚本、恢复程序和文档采用 [MIT License](../LICENSE)，版权 © 2026 Eason Zhang / easonzhangbin。

MIT 许可不适用于松下 LUMIX Tether、松下图标、Qt 或其他第三方组件。这些内容仍受各自许可约束。LUMIX、Panasonic 等商标属于其各自权利人。
