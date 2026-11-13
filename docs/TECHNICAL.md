# Technical notes / 技术说明

## Scope / 范围

This document records one recovered configuration, not a universal diagnosis for macOS or LUMIX cameras. The public tool consists of `.command` scripts and a native helper in the same release folder.

本说明记录一套已恢复的环境，不代表对所有 macOS 或 LUMIX 机型的通用诊断。公开工具由同一个发布目录内的 `.command` 脚本与原生恢复程序组成。

| Component / 项目 | Observed / 实测 |
| --- | --- |
| Camera / 相机 | Panasonic DC-S1H |
| Host / 主机 | MacBookPro18,2, Apple M1 Max |
| OS / 系统 | macOS 27.0.1 (26A434) |
| Vendor app / 厂商软件 | LUMIX Tether 2.12.0.5 |
| Links / 链路 | USB2 480Mbps; USB3 5Gbps |
| Final result / 最终结果 | Tether camera controls and actual live view restored on both links / 两种链路均恢复 Tether 相机控制与实际实时预览 |

The link rates above are negotiated speeds. File-transfer throughput and long-duration stability were not measured. DC-S1R, DC-S1 and other bodies remain untested.

以上为协商速率，未测文件传输吞吐量及长时间稳定性。DC-S1R、DC-S1 和其他机型尚未验证。

## Failure evidence / 故障证据

- USB enumeration and interface access succeeded.
- Both the vendor Tether path and early direct PTP probes timed out when writing a new command.
- Reading bulk IN after a write error returned pending `GetDeviceInfo` transaction-0 data: a 237-byte Data container and a 12-byte `0x2001` OK Response.
- After consuming the pending containers, a new strict three-transaction exchange succeeded. Tether then recognized the camera and displayed live view.
- After a USB3 reconnection, the recovery helper observed and drained the same two pending container types before another successful fresh-session check and Tether live view.

对应观察：USB 枚举及接口访问正常；新的写命令超时。继续读取 bulk IN 后发现事务 0 的残留设备信息数据与 OK 响应。完整消费它们后，新的三步会话验证成功，Tether 随后恢复预览。USB3 重连后再次观察到同类残留，并成功通过恢复程序处理。

An API-reported zero-byte write timeout does not by itself prove that no bytes reached the physical bus. The successful recovery was established by matching new protocol transactions and then observing the vendor application's live view.

API 报告写入超时且完成字节数为 0，不能单独证明物理总线上没有传输任何字节。本次成功结论以新的匹配事务和厂商应用实际显示实时画面为依据。

## Transport and transaction sequence / 传输与事务流程

The helper uses Apple's native `IOUSBHostInterface` and `IOUSBHostPipe`, with I/O buffers allocated through `ioDataWithCapacity:error:`. It does not depend on ImageCaptureCore, libusb, Python or Homebrew.

恢复程序使用原生 `IOUSBHostInterface`、`IOUSBHostPipe`，通过 `ioDataWithCapacity:error:` 分配 I/O 缓冲区，不依赖 ImageCaptureCore、libusb、Python 或 Homebrew。

Observed USB interface / 已观察接口：

| Field / 字段 | Value / 数值 |
| --- | --- |
| Vendor / Product | `04da:2382` |
| Configuration / Interface / Alternate setting | `1 / 0 / 0` |
| Interface class / subclass / protocol | `06 / 01 / 01` |
| Bulk OUT | `0x01` |
| Bulk IN | `0x82` |
| Interrupt IN | `0x83` |

The identifier may be shared by other camera bodies. A matching identifier is not evidence that those models have been tested or are supported.

其他机型可能共用此标识。匹配标识不等于该型号已测试或受支持。

Recovery / 恢复步骤：

1. Obtain the interface without forcing another camera client to release it.
2. Read pending bulk-IN data with bounded timeouts. Parse container headers and consume complete payloads without logging their content.
3. Certify an empty queue only when a zero-byte timeout occurs at a complete container boundary. A partial container, unexpected error or exhausted limit stops recovery before a new OUT command.
4. Send `OpenSession` (`0x1002`, transaction 0, session 1); require a matching `0x2001` response.
5. Send `GetDeviceInfo` (`0x1001`, transaction 1); require its complete Data container and matching OK Response.
6. Send `CloseSession` (`0x1003`, transaction 2); require a matching OK Response.
7. Close the helper's interface, then let the script launch a separately installed official Tether 2.12.

恢复程序先读取完整残留容器，确认输入队列已清空，再验证全新的打开会话、读取设备信息、关闭会话。三个步骤均匹配成功后，才释放接口并启动官方 Tether。

The bounded drain uses 500ms reads, a 3-second total budget and a maximum of five complete containers. These are recovery limits, not assumptions about image size or the amount of data a camera may normally produce.

排空阶段采用单次 500ms 读取、总计 3 秒预算及最多 5 个完整容器的限制。这些是恢复上限，不代表对图像大小或相机正常数据量的假设。

## Why an isolated OK is insufficient / 为何单个 OK 不足以证明成功

A pending `GetDeviceInfo` response with transaction ID 0 could be mistaken for an `OpenSession` OK that also uses transaction ID 0. Early investigation encountered this ambiguity. The helper therefore requires the subsequent DeviceInfo Data/OK transaction and CloseSession response as well; an isolated OK is not reported as successful recovery.

残留的 `GetDeviceInfo` OK 和新的 `OpenSession` 都可能使用事务 ID 0。调查中遇到过这种歧义，因此程序还要求后续设备信息 Data／OK 以及关闭会话响应全部匹配，不能凭单个 OK 判定恢复。

## Known and unknown / 已知与未知

**Established:** draining the observed pending responses restored valid USB PTP exchanges and Tether 2.12 live view on the tested S1H, using both USB2 and USB3.

**已证实：** 消费观察到的残留响应后，这台 S1H 在 USB2、USB3 上均恢复了有效 PTP 通信及 Tether 2.12 实时预览。

**Not established:** which process or component originated the pending transaction; a specific macOS kernel defect; that every connection failure has this cause; support for other cameras; recovery on every Apple Silicon Mac or macOS version.

**尚未证实：** 残留事务由谁产生、是否存在某个特定内核缺陷、所有连接故障是否同因、其他机型是否适用，以及所有 Apple Silicon Mac 或 macOS 版本是否可恢复。

Panasonic's published Tether compatibility page lists S1H, S1R and Apple Silicon, with a tested macOS range ending at 15.6 at the time of this investigation. That list does not prove that an unlisted newer system can never work. See [the official download and compatibility page](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html).

调查时松下兼容说明列有 S1H、S1R 与 Apple Silicon，系统验证范围最高到 macOS 15.6。未列出的较新系统不能因此被判定为必定无法使用。

## Language and packaging / 语言与打包

Tether 2.12 contains translations for `zh`, `en`, `ja`, `de`, `es`, `fr`, `it` and `ru`. On every launch, the script maps the system's preferred language to a supported code, falls back to English for other languages, and passes the existing `-lang=xx` option. An explicit `--language` option overrides this selection. It does not rewrite Panasonic's executable or translation resources.

Tether 2.12 内置 `zh`、`en`、`ja`、`de`、`es`、`fr`、`it`、`ru` 翻译。每次启动时，脚本将系统首选语言映射到支持代码，其他语言回退为英文，并传入已有的 `-lang=xx` 参数。显式 `--language` 参数可覆盖自动选择。此过程不改写厂商程序或翻译资源。

Opening the original Tether icon directly may use its saved language rather than the current system preference. Launch through either recovery script for automatic language selection.

直接打开原厂 Tether 图标可能使用已保存的语言，而不是当前系统首选语言。需要自动选择时，请从任一恢复脚本启动。

Public artifacts contain the two equivalent scripts, `恢复S1H连接.command` and `Restore S1H Connection.command`, plus `bin/s1h_iousbhost_probe`. The user installs official Tether 2.12 separately. The script searches `/Applications` and `~/Applications`, or accepts an explicit path through `--tether-app`. `--check` validates the setup without accessing the camera.

公开产物包含两个等效脚本 `恢复S1H连接.command`、`Restore S1H Connection.command`，以及 `bin/s1h_iousbhost_probe`。用户需单独安装官方 Tether 2.12。脚本搜索 `/Applications` 和 `~/Applications`，也接受 `--tether-app` 显式路径；`--check` 仅检查环境，不访问相机。

Panasonic binaries, artwork, Qt libraries and installer packages are excluded from public release artifacts and remain covered by their respective licenses.

松下程序、图标、Qt 库与安装包不属于公开产物，其原有许可继续有效。

## Logs and reports / 日志与报告

Protocol recovery does not replace macOS privacy or accessory permissions. If prompted, the user must grant the required removable-volume access to Tether or Terminal, or USB-accessory access to the application they intend to use. A successful helper exchange is separate from the vendor app's permission state.

协议恢复不能替代 macOS 隐私或配件权限。系统提示时，用户仍需允许 Tether 或终端必要的可移动宗卷访问，或为当前应用允许 USB 配件访问。恢复程序握手成功，与厂商应用的权限状态是两个独立条件。

Logs should contain protocol headers, lengths, statuses and version information only. Do not include image payloads, camera serial numbers, private paths or unredacted full crash reports. A crash report showing Tether 2.11 is an older-app report, not a verified failure of the tested 2.12 path.

日志只需协议头、长度、状态及版本信息。不要提交图像内容、相机序列号、私人路径或未脱敏的完整崩溃报告。显示 Tether 2.11 的崩溃报告属于旧版应用，不能直接证明已验证的 2.12 路径失败。
