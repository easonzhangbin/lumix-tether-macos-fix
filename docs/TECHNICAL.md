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

The link rates above are negotiated speeds. File-transfer throughput and long-duration stability were not measured. The problem recurred after a later USB3 reconnection. DC-S1R, DC-S1 and other bodies remain untested.

以上为协商速率，未测文件传输吞吐量及长时间稳定性。后来一次 USB3 重连后问题复发。DC-S1R、DC-S1 和其他机型尚未验证。

## Failure evidence / 故障证据

- During the initial recovery, USB enumeration and interface access succeeded.
- Both the vendor Tether path and early direct PTP probes timed out when writing a new command.
- Reading bulk IN after a write error returned pending `GetDeviceInfo` transaction-0 data: a 237-byte Data container and a 12-byte `0x2001` OK Response.
- After consuming the pending containers, a new strict three-transaction exchange succeeded. Tether then recognized the camera and displayed live view.
- After a USB3 reconnection, the recovery helper observed and drained the same two pending container types before another successful fresh-session check and Tether live view.

对应观察：USB 枚举及接口访问正常；新的写命令超时。继续读取 bulk IN 后发现事务 0 的残留设备信息数据与 OK 响应。完整消费它们后，新的三步会话验证成功，Tether 随后恢复预览。USB3 重连后再次观察到同类残留，并成功通过恢复程序处理。

## Reconnection and service ownership / 重连复发与服务占用

A later USB3 unplug/reconnect reproduced the transaction-0 `GetDeviceInfo` Data/OK backlog and Tether's command-write timeout. There was also an interface-ownership problem: after all camera applications had exited, the old `ptpcamerad` process still held the interface. Kernel ownership diagnostics identified that specific process. A normal termination request did not make it exit; a targeted forced stop of that identified instance released the interface. The original drain and strict session check then passed, and Tether live view was observed again.

后来一次 USB3 拔插重连，再次复现了事务 0 的 `GetDeviceInfo` Data／OK 残留和 Tether 写命令超时。同时存在接口占用问题：所有相机软件退出后，旧 `ptpcamerad` 进程仍持有接口，内核占用诊断确认了对应进程。普通退出请求没有使其结束；针对该已确认身份的旧服务实例执行强制停止后，接口得到释放。随后原有排空流程和严格会话校验均通过，Tether 再次显示实时预览。

These observations distinguish two recovery stages:

| Observed condition / 观察到的状态 | What it blocks / 阻塞位置 |
| --- | --- |
| Stale `ptpcamerad` interface ownership / 旧服务仍占用接口 | The helper cannot open the interface, so no drain can run / 恢复程序无法打开接口，尚不能开始排空 |
| Unread PTP Data/Response containers / PTP 数据与响应未读完 | New command writes can time out even when the interface is accessible / 即使已获得接口，新命令写入仍可能超时 |

The two conditions were observed in the same investigation; their presence does not establish that one caused the other. Preview was registered as a camera client during the investigation, but that alone does not identify it as the origin of either condition.

两种状态在同一次调查中被观察到，但不能因此确定相互因果关系。调查中“预览”曾登记为相机客户端，仅凭这一点也不能认定它是任一状态的起因。

A subsequent USB3 reconnection reproduced Tether's command-write timeout with Preview already closed; the observed `ptpcamerad` client registration was Tether. This shows that Preview does not have to be running for the failure to recur. It does not establish that every other background application or client was absent.

之后一次 USB3 重连中，“预览”已退出，仍复现了 Tether 写命令超时；当时观察到的 `ptpcamerad` 客户端登记为 Tether。这说明故障复发并不要求“预览”正在运行，但不能据此推断所有其他后台应用或客户端都不存在。

Apple's [IOUSBHost object initializer documentation](https://developer.apple.com/documentation/iousbhost/iousbhostobject/initwithioservice%3Aoptions%3Aqueue%3Aerror%3Ainteresthandler%3A) explains that an existing exclusive open prevents initialization of a second host object. This supports the interface-ownership mechanism; it is not an Apple diagnosis or confirmation of this particular bug.

Apple 的 [IOUSBHost 对象初始化说明](https://developer.apple.com/documentation/iousbhost/iousbhostobject/initwithioservice%3Aoptions%3Aqueue%3Aerror%3Ainteresthandler%3A)指出，已有独占访问时无法创建第二个对应主机对象。此资料解释接口独占机制，不代表 Apple 已认定或确认本项目遇到的特定故障。

This project provides a recovery before launching Tether. It does not install a replacement driver or permanently change Apple's camera service, USB stack or camera firmware. Run recovery again after a reconnection or another failed launch. The default flow does not stop camera applications or restart `ptpcamerad` automatically.

本项目提供启动 Tether 前的恢复流程，不安装替代驱动，也不永久改变 Apple 相机服务、USB 栈或相机固件。重连或再次启动失败后，需要重新执行恢复。默认流程不会自动结束相机软件或重启 `ptpcamerad`。

## Interface handoff is not a permanent USB lock / 接口交接不等于永久 USB 锁

The helper owns the interface only while recovering and verifying its own PTP session. It closes that session and destroys its IOUSBHost interface before official Tether is launched. Tether must then obtain its own access. In this design, an exclusive lock retained by the helper would exclude Tether as well; there is no permanent ownership guarantee during or after that handoff.

恢复程序只在恢复及验证自身 PTP 会话时持有接口。启动官方 Tether 前，它会关闭会话并销毁 IOUSBHost 接口，随后由 Tether 获取自己的访问权。在当前设计下，恢复程序若继续独占锁住接口，也会阻止 Tether；交接期间及之后都不存在永久防抢占保证。

This is an interface-ownership issue, not a file write-protection setting. No file permission or filesystem lock is used to reserve the camera for Tether. Keep all other camera/import applications closed throughout the Tether session. Reducing automatic importer launches is useful but cannot prevent an already-running client from accessing the device.

这是接口占用问题，不是文件写保护设置。本项目不通过文件权限或文件系统锁为 Tether 预留相机。使用 Tether 期间应保持所有其他相机／导入软件关闭；减少自动启动有帮助，但不能阻止已运行客户端访问设备。

Apple documents the per-device connection action in the [Image Capture guide](https://support.apple.com/guide/image-capture/image-capture-imgcp1003/mac). [Capture One's official guide](https://support.captureone.com/hc/en-us/articles/360002423997-Why-does-Capture-One-automatically-start-every-time-I-connect-my-camera-CF-card-or-iPhone) directly describes the No Application choice. This changes automatic-launch behavior, not USB exclusivity. The README gives the optional UI steps; this project does not change that setting automatically.

Apple 的[“图像捕捉”指南](https://support.apple.com/guide/image-capture/image-capture-imgcp1003/mac)说明了设备连接动作菜单；[Capture One 官方指南](https://support.captureone.com/hc/en-us/articles/360002423997-Why-does-Capture-One-automatically-start-every-time-I-connect-my-camera-CF-card-or-iPhone)直接说明 No Application 选项。它改变自动启动行为，不改变 USB 独占关系。README 提供可选的界面步骤，本项目不会自动修改该设置。

After reconnecting USB or waking the Mac, quit Tether and try normal recovery first. If the interface is still busy, inspect ownership and use the explicit service-restart flow only when its guard can identify the eligible service instance. On refusal, close the diagnosed application or disconnect extra cameras. Do not force-stop an unknown owner. Save work and restart the Mac only as a last controlled recovery if ownership remains unresolved; this is an operating procedure, not evidence of a permanent cure or a claim that sleep/wake was reproduced in testing.

USB 重连或 Mac 唤醒后，应先退出 Tether 并尝试普通恢复；仍被占用时，先检查占用，仅在守卫能确认符合条件的服务实例时使用明确重启流程。若被拒绝，应退出诊断指出的应用，或断开额外相机，不得强制结束未知占用者。占用关系仍无法确认时，保存工作后再将重启 Mac 作为最后一个受控恢复步骤。这是操作流程，不是永久治愈证据，也不代表已在测试中复现休眠唤醒故障。

## v1.0.1 ownership diagnostics and opt-in restart / v1.0.1 占用诊断与明确选择的重启

`--diagnose` reads IORegistry ownership and process metadata and writes a diagnostic log. It does not open a USB interface, run the PTP recovery probe, launch Tether or restart a service. A default recovery failure also triggers a read-only ownership check and a suggestion to use the separate restart entry point when appropriate; it never silently escalates to a restart.

`--diagnose` 读取 IORegistry 占用及进程元数据并输出诊断日志，不打开 USB 接口，不运行 PTP 恢复探针，不启动 Tether，也不重启服务。普通恢复失败后同样只读检查占用，并在适用时提示独立重启入口，不会静默转为重启操作。

`--restart-camera-service`, or the equivalent **Restart Camera Service and Restore.command** / **重启相机服务并恢复连接.command** entry point, explicitly selects the guarded service-restart flow before the normal probe and Tether launch.

`--restart-camera-service` 或等效的 **Restart Camera Service and Restore.command**／**重启相机服务并恢复连接.command**，表示明确选择在普通探针和 Tether 启动之前执行带守卫的服务重启流程。

The guard checks both `UsbExclusiveOwner` and `IOUserClientCreator` evidence from IORegistry against the current user's `/usr/libexec/ptpcamerad` process, including its PID and start time. It refuses an unverified owner, unresolved ownership involving this or another PTP camera, or a detected running camera application. Before signaling, the process identity must still match the verified instance. A bounded normal-termination attempt may be followed by a forced stop of that same instance.

守卫以 IORegistry 中的 `UsbExclusiveOwner` 和 `IOUserClientCreator` 双重证据，核对当前用户 `/usr/libexec/ptpcamerad` 的 PID、启动时间及身份。无法验证占用者、当前或其他 PTP 相机占用关系不明确，或检测到相机应用仍在运行时，会拒绝操作。发送信号前必须仍匹配已核对的进程实例；有限等待的普通终止请求之后，可能强制停止同一实例。

**This interrupts the current user's PTP camera service.** The guard cannot prove that every background XPC client is idle. Users must first close all camera and photo-import software, not merely hide their windows. If the guard refuses, the script does not run the USB probe or launch Tether. The mode requires no `sudo`, changes no security setting and installs no persistent service.

**此操作会中断当前用户的 PTP 相机服务。** 守卫无法证明每个后台 XPC 客户端都空闲。用户必须先正常退出全部相机及照片导入软件，仅隐藏窗口不够。守卫拒绝后，脚本不执行 USB 探针或启动 Tether。此模式不需要 `sudo`，不改变安全设置，不安装常驻服务。

The targeted manual service release and subsequent recovery were verified during the recurrence investigation. Those observations explain why the opt-in mode exists; a guard is not evidence of a permanent fix or proof that all background clients were idle.

复发调查中已验证针对旧服务实例的释放及后续恢复。这些观察说明明确重启模式的用途，但守卫本身不是永久修复证据，也不能证明所有后台客户端当时均空闲。

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

1. Obtain the interface without forcing another camera client to release it. If a service still owns it, report the ownership failure before attempting a drain.
2. Read pending bulk-IN data with bounded timeouts. Parse container headers and consume complete payloads without logging their content.
3. Certify an empty queue only when a zero-byte timeout occurs at a complete container boundary. A partial container, unexpected error or exhausted limit stops recovery before a new OUT command.
4. Send `OpenSession` (`0x1002`, transaction 0, session 1); require a matching `0x2001` response.
5. Send `GetDeviceInfo` (`0x1001`, transaction 1); require its complete Data container and matching OK Response.
6. Send `CloseSession` (`0x1003`, transaction 2); require a matching OK Response.
7. Close the helper's interface, then let the script launch a separately installed official Tether 2.12.

恢复程序先读取完整残留容器，确认输入队列已清空，再验证全新的打开会话、读取设备信息、关闭会话。三个步骤均匹配成功后，才释放接口并启动官方 Tether。

The bounded drain uses 500ms reads, a 3-second total budget and a maximum of five complete containers. These are recovery limits, not assumptions about image size or the amount of data a camera may normally produce.

排空阶段采用单次 500ms 读取、总计 3 秒预算及最多 5 个完整容器的限制。这些是恢复上限，不代表对图像大小或相机正常数据量的假设。

### USB probe phase results / USB 探针阶段结果

The native USB probe distinguishes these outcomes. They describe the probe stage, not whether Tether subsequently displayed live view.

原生 USB 探针区分以下结果。它们说明探针运行到哪个阶段，不代表 Tether 随后是否显示了实时预览。

| Exit code / 退出码 | Meaning / 含义 |
| --- | --- |
| `0` | Fresh OpenSession, DeviceInfo Data/OK and CloseSession checks all passed / 新会话三步校验全部通过 |
| `20` | No matching PTP interface / 没有匹配的 PTP 接口 |
| `21` | Multiple matching interfaces; selection is ambiguous / 匹配到多个接口，无法唯一选择 |
| `22` | Interface open failed; inspect ownership and permissions separately / 接口打开失败，需另行核对占用及权限 |
| `23` | Drain was not certified; no new OUT command was sent / 未确认排空完成，没有发送新的 OUT 命令 |
| `24` | Fresh-session verification did not fully pass / 新会话校验未全部通过 |
| `124` | Process watchdog deadline reached / 到达进程看门狗时限 |

An open error or NSError alone does not identify the owner. Code `22` must be read together with the separate ownership diagnostic; it is not automatically classified as a stale `ptpcamerad` instance.

仅凭打开错误或 NSError 不能确定占用者。`22` 需要结合独立占用诊断判断，不能自动归因为旧 `ptpcamerad` 实例。

## Why an isolated OK is insufficient / 为何单个 OK 不足以证明成功

A pending `GetDeviceInfo` response with transaction ID 0 could be mistaken for an `OpenSession` OK that also uses transaction ID 0. Early investigation encountered this ambiguity. The helper therefore requires the subsequent DeviceInfo Data/OK transaction and CloseSession response as well; an isolated OK is not reported as successful recovery.

残留的 `GetDeviceInfo` OK 和新的 `OpenSession` 都可能使用事务 ID 0。调查中遇到过这种歧义，因此程序还要求后续设备信息 Data／OK 以及关闭会话响应全部匹配，不能凭单个 OK 判定恢复。

## v1.0.1 validation / v1.0.1 验证

- Fourteen isolated launcher tests and forty simulated native-guard checks passed without hardware access or real process signals.
- On the documented USB3 S1H setup, read-only diagnosis identified the interface's current-user camera-service owner. A real restart request while Tether was running was refused with no signals sent.
- After Tether was quit normally, the explicit restart entry point revalidated and released the old service instance using bounded TERM followed by KILL. It then drained the same 237-byte Data and 12-byte OK transaction-0 containers, passed all three fresh PTP checks, opened official Tether 2.12 in Chinese, and displayed actual live view.
- This validates the observed recovery path. It is not a long-duration test or a guarantee against all future USB reconnection failures.

- 14 项隔离启动脚本测试、40 项原生守卫模拟检查通过；这些自动测试不访问硬件、不发送真实进程信号。
- 在上述 USB3 S1H 环境中，只读诊断正确识别了当前用户的相机服务占用者。Tether 运行时，真实重启请求被拒绝，未发送任何终止信号。
- 正常退出 Tether 后，明确的重启入口重新核验目标，通过有时间上限的 TERM 及后续 KILL 使旧服务释放接口；随后排空同样的事务 0 残留（237 字节 Data、12 字节 OK），三步新会话检查全部通过，官方 Tether 2.12 以中文启动并显示实际实时画面。
- 这些结果验证了观察到的恢复路径，不等于长时间稳定性测试，也不保证将来所有 USB 重连都不会再失败。

## Longer-term transport work / 后续通信层工作

The current native helper owns the interface only during recovery and releases it before official Tether starts. It cannot keep exclusive ownership and simultaneously allow Tether's camera service to use the same interface.

Read-only inspection of official Tether 2.12 found a Qt UI calling `libLmxptpif.dylib`; that library uses ImageCaptureCore camera discovery, session and PTP-command APIs. There is therefore a UI/communication boundary, but replacing the library while retaining the UI would require matching a large private C++ ABI, callbacks and event/session behavior. No such replacement or vendor binary patch is implemented in this release.

A separate minimal S1H application using one native USB/PTP queue for connection, preview, timeout recovery and reconnection is another possible direction. The strict native transactions and an earlier successful JPEG-preview experiment support investigating it. Continuous frame rate, long-duration operation, sleep/wake and hot-plug behavior still need implementation and measurement. A successful recovery is not evidence that this prospective application is already stable.

当前原生辅助程序只在恢复期间持有接口，官方 Tether 启动前必须释放。它不能一边持续独占接口，一边让 Tether 的相机服务使用同一接口。

对官方 Tether 2.12 的只读检查发现：Qt 界面调用 `libLmxptpif.dylib`，该库通过 ImageCaptureCore 执行发现相机、打开会话及发送 PTP 命令。因此确实存在界面与通信层的边界，但保留界面并替换该库，需要兼容大量私有 C++ ABI、回调、事件和会话行为。本版本没有实现此类替换，也没有修改厂商二进制。

另一条可研究的路线是独立的最小 S1H 应用，由同一原生 USB／PTP 队列负责连接、预览、超时恢复与重连。已有的严格原生握手及此前成功取得 JPEG 预览的实验支持继续探索；连续帧率、长时间运行、睡眠唤醒及热插拔仍需开发与测量，不能由一次恢复成功推断其已稳定。

## Known and unknown / 已知与未知

**Established:** draining the observed pending responses restored valid USB PTP exchanges and Tether 2.12 live view on the tested S1H, using both USB2 and USB3. A later USB3 recurrence also required releasing the interface from a stale `ptpcamerad` instance after camera applications had exited, before the same drain procedure could run.

**已证实：** 消费观察到的残留响应后，这台 S1H 在 USB2、USB3 上均恢复了有效 PTP 通信及 Tether 2.12 实时预览。后来一次 USB3 复发中，相机应用退出后，还需先使旧 `ptpcamerad` 实例释放接口，才能执行相同排空流程。

**Not established:** which process or component originated the pending transaction; why the service retained the interface; that Preview caused the failure; a specific macOS kernel defect; a permanent system-level cure; that every connection failure has these conditions; support for other cameras; recovery on every Apple Silicon Mac or macOS version.

**尚未证实：** 残留事务由谁产生、服务为何继续占用接口、“预览”是否造成故障、是否存在某个特定内核缺陷、系统层永久治愈方案、所有故障是否具有上述状态、其他机型是否适用，以及所有 Apple Silicon Mac 或 macOS 版本是否可恢复。

Panasonic's published Tether compatibility page lists S1H, S1R and Apple Silicon, with a tested macOS range ending at 15.6 at the time of this investigation. That list does not prove that an unlisted newer system can never work. See [the official download and compatibility page](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html).

调查时松下兼容说明列有 S1H、S1R 与 Apple Silicon，系统验证范围最高到 macOS 15.6。未列出的较新系统不能因此被判定为必定无法使用。

## Language and packaging / 语言与打包

Tether 2.12 contains translations for `zh`, `en`, `ja`, `de`, `es`, `fr`, `it` and `ru`. On every launch, the script maps the system's preferred language to a supported code, falls back to English for other languages, and passes the existing `-lang=xx` option. An explicit `--language` option overrides this selection. It does not rewrite Panasonic's executable or translation resources.

Tether 2.12 内置 `zh`、`en`、`ja`、`de`、`es`、`fr`、`it`、`ru` 翻译。每次启动时，脚本将系统首选语言映射到支持代码，其他语言回退为英文，并传入已有的 `-lang=xx` 参数。显式 `--language` 参数可覆盖自动选择。此过程不改写厂商程序或翻译资源。

Opening the original Tether icon directly may use its saved language rather than the current system preference. Launch through either recovery script for automatic language selection.

直接打开原厂 Tether 图标可能使用已保存的语言，而不是当前系统首选语言。需要自动选择时，请从任一恢复脚本启动。

Public artifacts contain the normal entry points `恢复S1H连接.command` and `Restore S1H Connection.command`, the explicit restart entry points `重启相机服务并恢复连接.command` and `Restart Camera Service and Restore.command`, and native helpers in `bin/`. The user installs official Tether 2.12 separately. The script searches `/Applications` and `~/Applications`, or accepts an explicit path through `--tether-app`. `--check` validates the setup without accessing the camera; `--diagnose` performs the read-only ownership inspection described above.

公开产物包含普通入口 `恢复S1H连接.command`、`Restore S1H Connection.command`，明确重启入口 `重启相机服务并恢复连接.command`、`Restart Camera Service and Restore.command`，以及 `bin/` 内的原生辅助程序。用户需单独安装官方 Tether 2.12。脚本搜索 `/Applications` 和 `~/Applications`，也接受 `--tether-app` 显式路径；`--check` 仅检查环境、不访问相机，`--diagnose` 执行上述只读占用诊断。

Panasonic binaries, artwork, Qt libraries and installer packages are excluded from public release artifacts and remain covered by their respective licenses.

松下程序、图标、Qt 库与安装包不属于公开产物，其原有许可继续有效。

## Logs and reports / 日志与报告

Protocol recovery does not replace macOS privacy or accessory permissions. If prompted, the user must grant the required removable-volume access to Tether or Terminal, or USB-accessory access to the application they intend to use. A successful helper exchange is separate from the vendor app's permission state.

协议恢复不能替代 macOS 隐私或配件权限。系统提示时，用户仍需允许 Tether 或终端必要的可移动宗卷访问，或为当前应用允许 USB 配件访问。恢复程序握手成功，与厂商应用的权限状态是两个独立条件。

Logs contain protocol headers, lengths, statuses and version information; ownership diagnostics also include process metadata. Review excerpts for private paths before sharing. Do not include image payloads, camera serial numbers or unredacted full crash reports. A crash report showing Tether 2.11 is an older-app report, not a verified failure of the tested 2.12 path.

日志包含协议头、长度、状态和版本信息；占用诊断还包含进程元数据。分享前请检查并去除私人路径。不要提交图像内容、相机序列号或未脱敏的完整崩溃报告。显示 Tether 2.11 的崩溃报告属于旧版应用，不能直接证明已验证的 2.12 路径失败。
