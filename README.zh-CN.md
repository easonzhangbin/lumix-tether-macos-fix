# LUMIX Tether macOS USB 连接修复

[English](README.md)

通过 `.command` 脚本运行的小型 Apple Silicon USB 恢复工具：先清理未读完的 PTP 响应，再打开松下 LUMIX Tether 2.12。已在一套 Panasonic DC-S1H 环境上恢复 USB2、USB3 联机连接，并验证 Tether 实时预览正常。

本项目由社区独立开发，与松下或 Apple 没有隶属关系。

## 包含内容

- **恢复S1H连接.command** 和 **Restore S1H Connection.command**，两个等效脚本入口。
- 使用原生 IOUSBHost 的恢复程序，位于 `bin/s1h_iousbhost_probe`。
- 自动选择 Tether 原有界面语言，也可通过命令行指定语言。

Release ZIP 解压后得到包含脚本与 `bin/` 的目录，请保持它们在一起。公开包**不包含 Tether、松下安装包或图标，也不包含 Qt 库**。请自行安装官方 Tether。

## 已验证环境

| 项目 | 实际测试配置 |
| --- | --- |
| 相机 | Panasonic DC-S1H |
| Mac | MacBookPro18,2，Apple M1 Max |
| macOS | 27.0.1，构建号 26A434 |
| Tether | 2.12，构建号 2.12.0.5 |
| USB2 | 协商链路速率 480Mbps；Tether 实时预览恢复 |
| USB3 | 协商链路速率 5Gbps；Tether 实时预览恢复 |

上述速率是 USB 协商链路速率，并非实测文件传输速度；尚未做长时间稳定性测试。

恢复程序只面向 **arm64／Apple Silicon**，构建部署目标为 macOS 12。实际硬件验证仅覆盖上表中的 macOS 27.0.1，部署目标不代表已验证所有后续系统版本。此版本不支持 Intel Mac。

**DC-S1R、DC-S1 以及其他 LUMIX 机型均未实测。** 部分机型可能共用 USB 标识，不能仅凭标识相同推断本恢复方法适用。

## 使用方法

1. 从[松下官方下载页](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)下载并安装 **LUMIX Tether 2.12**。
2. 从本项目的 [Releases](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases) 下载 ZIP，解压得到工具目录。
3. 退出 Tether 和其他正在访问相机的软件。使用支持数据传输的 USB 线连接 S1H，在相机上选择 **PC(Tether)／PC（联机拍摄）**。
4. 双击 **恢复S1H连接.command** 或 **Restore S1H Connection.command**。脚本会在终端中运行，并在 `/Applications` 和 `~/Applications` 查找官方 Tether 2.12。
5. 清理和新会话验证成功后，脚本会打开 Tether。选择相机，点击 **Start／开始**，再点击 **LV** 打开实时预览。

连接卡住或相机重新插线后，可先运行本工具，再启动 Tether。工具不会强制关闭其他相机软件来抢占连接。

如果 macOS 提示 Tether 或终端访问相机的可移动宗卷，或提示连接 USB 配件，请允许当前使用的应用所需访问。若恢复验证成功但 Tether 仍无法连接，请在**系统设置 → 隐私与安全性 → 文件与文件夹**中检查实际 Tether 2.12 应用的权限。协议恢复成功后，仍可能需要完成系统权限授权。

若官方应用不在默认位置，可在解压后的工具目录中执行：

```sh
./"恢复S1H连接.command" --tether-app "/path/to/LUMIX Tether.app"
```

指定的应用必须是官方 Tether 2.12。

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

恢复程序使用 Apple 原生 IOUSBHost API，先读取并丢弃完整的残留容器。只有在**完整容器边界**出现零字节超时，才认为队列已清空；随后严格验证一组新的 `OpenSession` → `GetDeviceInfo` → `CloseSession`，成功后脚本才打开 Tether。

这些证据解释了本次恢复过程，但尚未证明是谁产生了残留事务，也不能据此断言所有新版 macOS 的 LUMIX 连接故障都由同一原因造成。详见[技术说明](docs/TECHNICAL.md)。

恢复程序不拍照、不删除图片、不更新固件；日志不记录图像内容或相机序列号。

## 常见问题

**打开的是 Tether 2.11，或旧快捷方式启动后崩溃。** 请核对实际运行应用的版本。旧 Dock 图标或快捷方式可能仍指向 2.11。此脚本要求官方 Tether 2.12，并拒绝 2.11；旧版应用的崩溃不能用来判断 2.12 的恢复是否失败。

**提示相机或接口被占用。** 退出正在访问相机的程序，拔线重连、选择 PC(Tether)，再运行本工具。工具不会强制结束其他相机客户端。

**找不到相机。** 检查电源、数据线、USB 模式，以及 macOS 是否弹出配件连接许可。本工具无法修复物理 USB 连接缺失。

**其他机型不能使用。** 请按未验证环境报告准确型号，不要因 USB ID 相同而推定兼容。

报告问题请使用 [Bug 模板](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml)，只提交相关状态和错误行。不要公开相机序列号或未脱敏的完整崩溃报告。

## 从源码构建

默认公开版本在 Apple Silicon Mac 上使用 Xcode Command Line Tools 构建，只依赖系统框架，无需 Homebrew、Python 或第三方库。

在仓库根目录执行：

```sh
./scripts/build.sh
./scripts/self-check.sh
./scripts/package.sh
```

构建会生成 `dist/LUMIX Tether USB Fix/`，其中包含两个 `.command` 文件及 `bin/s1h_iousbhost_probe`。打包脚本在 `dist/` 生成公开 arm64 ZIP 及 SHA-256 校验文件。自检只验证产物，不访问相机或运行 Tether。各脚本的完整参数可通过 `--help` 查看。

## 参与贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。欢迎补充其他机型和系统版本的实测结果，并区分“握手成功”和“Tether 实时预览已经验证”。

## 支持开发

如果这个工具对你的工作有帮助，可以通过支付宝支持开发。支持完全自愿。

<img src="assets/alipay-donate.jpg" alt="支付宝支持开发收款码" width="240">

## 许可与第三方软件

本项目自行编写的脚本、恢复程序和文档采用 [MIT License](LICENSE)，版权 © 2026 Eason Zhang / easonzhangbin。

MIT 许可不适用于松下 LUMIX Tether、松下图标、Qt 或其他第三方组件。这些内容仍受各自许可约束。LUMIX、Panasonic 等商标属于其各自权利人。
