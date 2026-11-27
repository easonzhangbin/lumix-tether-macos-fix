# Technical notes / 技术说明

## Scope / 范围

This document records one recovered configuration, not a universal diagnosis for macOS or LUMIX cameras. The repository includes the Connection Guardian menu-bar beta and the earlier `.command` recovery tools, using native USB-recovery and ownership helpers.

本说明记录一套已恢复的环境，不代表对所有 macOS 或 LUMIX 机型的通用诊断。仓库包含 Connection Guardian 菜单栏测试版及早期 `.command` 恢复工具，使用原生 USB 恢复及占用诊断辅助程序。

| Component / 项目 | Observed / 实测 |
| --- | --- |
| Camera / 相机 | Panasonic DC-S1H |
| Host / 主机 | MacBookPro18,2, Apple M1 Max |
| OS / 系统 | macOS 27.0.1 (26A434) |
| Vendor app / 厂商软件 | LUMIX Tether 2.12.0.5 |
| Links / 链路 | USB2 480Mbps; USB3 5Gbps |
| Final result / 最终结果 | Tether camera controls and actual live view restored on both links / 两种链路均恢复 Tether 相机控制与实际实时预览 |

The link rates above are negotiated speeds, not measured payload throughput. A later, separate capture/download test is recorded below. The problem recurred after a later USB3 reconnection. DC-S1R, DC-S1 and other bodies remain untested.

以上为协商速率，不是有效数据吞吐量。后续独立拍摄／下载测试见下文。后来一次 USB3 重连后问题复发。DC-S1R、DC-S1 和其他机型尚未验证。

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

## Guard shutdown race fix / 守卫退出竞态修复

The unreleased v1.0.2 source includes the following guard change, which is absent from v1.0.1. The validation above remains the historical record for v1.0.1.

尚未发布的 v1.0.2 源码包含以下守卫修改，v1.0.1 不含此修改。上节保留 v1.0.1 的历史验证记录。

### Service shutdown inventory race / 服务退出时的进程快照竞态

Process inventory and subsequent owner-identity lookup are separate observations. After a verified service receives the permitted TERM or KILL and exits, a later lookup can report `ESRCH` while the earlier inventory still contains that exact process identity and IORegistry has not yet released its ownership record. The previous guard could reject this transition as `owner_identity_unavailable` even though the selected process had exited.

The revised guard permits only an earlier entry matching the already verified PID, UID, executable path and start time to enter a bounded wait for ownership release when the process is now absent. It does not send another signal, assume the interface is already free, or accept another owner. A changed identity, including a reused PID with a different start time, remains a refusal. This addresses a false refusal during shutdown; it does not change USB recovery or install a persistent service.

Forty-three simulated guard checks and fourteen isolated launcher tests passed for the revised guard, without hardware access or real process signals. These checks are separate from the historical hardware recovery and do not establish long-duration stability.

进程列表快照与后续占用者身份查询并非原子操作。已经验证的服务收到允许的 TERM 或 KILL 并退出后，后一次查询可能返回 `ESRCH`，但较早快照仍含该进程的完整旧身份，IORegistry 也可能尚未释放占用记录。此前守卫可能在这个过渡阶段以 `owner_identity_unavailable` 拒绝继续，即使目标进程已经退出。

修订守卫仅允许与此前已验证的 PID、UID、可执行路径、启动时间完全一致的旧快照，在确认进程已不存在后，进入有时间上限的占用释放等待。它不会追加信号、假定接口已经空闲，或接受其他占用者。身份改变仍被拒绝，包括 PID 被复用但启动时间不同的情况。此修改处理退出阶段的误拒绝，不改变 USB 恢复流程，也不安装常驻服务。

修订守卫已通过 43 项模拟检查和 14 项隔离启动脚本测试，均不访问硬件、不发送真实进程信号。这些检查与此前实机恢复观察分别记录，不能证明长期稳定性。

## Official Tether stop/quit hang / 官方 Tether 停止及退出挂起

An anonymized hang report from official Tether 2.12.0.5 showed its main thread in `DeviceAdapter::~DeviceAdapter` → `LiveViewManager::ForceStop` → `StopLive` → `std::thread::join`. The preview worker synchronously depended on the vendor request queue, whose command-timeout recovery path had entered `Controller closeSession` and was waiting on a semaphore.

Static inspection of the matching vendor library showed that this close path calls the legacy ImageCaptureCore `requestCloseSession`, runs a run loop with a 10-second limit, then waits on the session semaphore with a further 10-second limit. Its close-session delegate stops that run loop and signals that semaphore. Apple documents that the legacy API's delegate callback runs on the main thread. This supports a specific dependency cycle: the main thread waits for the preview worker, while the worker's request path needs a close callback on the main thread. See [Apple's legacy close-session API](https://developer.apple.com/documentation/imagecapturecore/icdevice/requestclosesession()).

The sampled waits have configured time limits, and the vendor path can subsequently attempt reconnection. The report therefore supports a stop/quit delay caused by timeout recovery; it does not prove an unlimited deadlock, the callback queue of every PTP operation, or a unique cause in Apple's USB stack. The camera service also had a waiting thread, but the report did not establish its complete causal relationship to this cycle.

The smallest candidate for retaining official Tether's UI is a stop/quit lifecycle change: stop issuing preview requests, suppress reconnection while stopping, keep the main thread available for callbacks, and destroy the adapter after its worker finishes asynchronously. This project has not implemented a vendor patch, injected a library or re-signed the official app. The public recovery launcher does not repair Tether's internal shutdown behavior. The raw report, private process identifiers and image payloads are excluded from this repository.

一份官方 Tether 2.12.0.5 的匿名化挂起报告显示，主线程停在 `DeviceAdapter::~DeviceAdapter` → `LiveViewManager::ForceStop` → `StopLive` → `std::thread::join`。预览 worker 同步依赖厂商请求队列；请求队列中的命令超时恢复流程已进入 `Controller closeSession`，正在等待 semaphore。

对匹配厂商库的静态检查发现，该关闭流程调用旧式 ImageCaptureCore `requestCloseSession`，先运行最多 10 秒的 run loop，再以另外 10 秒上限等待 session semaphore。关闭会话的 delegate 会停止该 run loop 并 signal 同一 semaphore。Apple 文档规定旧 API 的 delegate 回调在主线程执行。因此有证据支持一个具体等待环：主线程等预览 worker 退出，而 worker 依赖的请求流程需要主线程处理关闭回调。参见 [Apple 旧式关闭会话 API](https://developer.apple.com/documentation/imagecapturecore/icdevice/requestclosesession())。

采样所在等待均配置了时间上限，厂商路径之后还可能尝试重连。因此报告支持“超时恢复拖住停止／退出”的判断，尚不能证明无限死锁、所有 PTP 操作的回调队列，或故障唯一来自 Apple USB 栈。相机服务也存在等待线程，但报告没有建立它与此等待环的完整因果关系。

保留官方界面的最小候选是调整停止／退出生命周期：停止发出新预览请求，停止期间禁止自动重连，保持主线程可处理回调，并在 worker 异步结束后销毁 adapter。本项目尚未实现厂商补丁、注入库或重签官方应用；公开恢复脚本不能修复 Tether 内部退出行为。原始报告、私人进程标识及图像内容不进入本仓库。

## Connection Guardian beta / 连接守护测试版

Guardian 0.2.5 is the menu-bar beta described in the [project introduction](../README.md), with [source and usage](../experiments/connection-guardian/README.md). Shooting, camera controls and original-file saving use the unmodified official Tether 2.12 app.

Start explicitly enables bounded connection preparation while Tether is absent, including guarded current-user camera-service recovery when permitted. While Tether is known to be running, no new USB/PTP repair is started. Confirmed physical detach may request a normal quit only of the exact verified Tether instance Guardian launched. Reconnect also requests normal quit. Thirty seconds without exit enables a separate explicit force action; it never automatically forces Tether to quit.

End This Shoot disables recovery before waiting for an owned helper/launch to settle and requesting normal Tether quit. The ended session does not reopen Tether automatically. Pause preserves the existing app; it cancels future actions but cannot undo an already-delivered quit request. A stale helper/launch callback cannot restore old launch consent.

The app uses local rotating JSONL event logs with timestamps, run/request IDs, action requests, outcomes and process-observation edges. Guardian launch requests and returned applications are distinct events; externally observed processes retain unknown origin. A returned app does not prove the request created that process. Event fields are restricted metadata; raw diagnostics and photographs are excluded from public artifacts.

Version 0.2.5 adds an opt-in diagnostic for the DC-S1H 96 MP capture path. It takes a baseline of the selected save folder and checks new RW2 files for the expected model, cropped dimensions and metadata/payload bounds. If an expected file has not arrived within 30 seconds of the watcher becoming ready, Guardian captures available process samples and recent logs locally. The diagnostic pauses recovery so the existing session can be inspected. The cause of the intermittent camera stall remains unresolved.

Version 0.2.5 passed 379 hardware-free checks covering USB identity (16), service guards (51), the event writer (50), RAW arrival (25), and controller policy (237). Controller fixtures exercise asynchronous End and late callbacks with fake helper and process boundaries. Physical hot-plug, sleep/wake, and OS force-quit behavior require separate testing. The failed 0.2.2/0.2.3 hot-plug observations are recorded below.

A short Guardian recovery handoff was followed by actual official Tether preview and capture/save of one 6000×4000 RAW, 36,048,384 bytes. Pause retained the official process. End closed Tether normally; a six-second observation saw no automatic reopen. Long-duration work, repeated Guardian USB reconnects, sleep/wake and other hardware remain unverified.

Guardian 0.2.5 是[项目介绍](../README.zh-CN.md)中的菜单栏测试版，详见[源码及用法](../experiments/connection-guardian/README.zh-CN.md)。拍摄、参数控制及原片保存由官方 Tether 2.12 完成。

明确开始后，才在 Tether 未运行时进行有上限的连接准备，并在守卫允许时处理本用户的相机服务占用。已知 Tether 运行时不开始新的 USB／PTP 恢复。确认物理断开后，只可请求 Guardian 启动且身份仍一致的 Tether 正常退出；重新连接也先请求正常退出。30 秒未退出仅启用单独的明确强制操作，不会自动强杀。

结束本次拍摄先停止恢复，等待已有辅助程序／启动交接结束，再请求 Tether 正常退出；结束后不会自动重开。暂停保留应用当前状态，但无法撤回已经发出的退出请求。迟到的辅助程序或启动回调不能恢复已撤销的启动授权。

本地 JSONL 事件日志记录时间、运行／请求编号、操作、结果和进程变化。守护器的启动请求与系统返回的应用分开记录；外部观察进程的来源保留未知，返回应用不等于已经证明该请求创建了进程。事件仅含受限制的元数据，公开产物不含原始诊断或照片。

0.2.5 新增手动启用的 DC-S1H 9600 万像素拍摄诊断。工具先记录所选保存目录的初始文件，再检查新增 RW2 的机型、裁切尺寸和元数据及数据边界。监测就绪后 30 秒内未收到符合条件的文件时，工具会在本机保存可获取的线程采样和近期日志。诊断期间暂停恢复，便于保留当前会话。相机偶发卡住的根因仍待确认。

0.2.5 通过 379 项无硬件检查，包括设备身份（16）、服务守卫（51）、事件日志（50）、RAW 到达（25）和控制器策略（237）。控制器使用模拟辅助程序和进程边界测试异步结束及迟到回调。实际拔插、睡眠唤醒和系统强制退出仍需分别验证。0.2.2／0.2.3 拔插失败的实测记录见下文。

一次短测中，Guardian 恢复交接后，官方 Tether 预览正常，并拍摄保存一张 6000×4000 RAW（36,048,384 字节）。暂停保留了原厂进程；结束拍摄正常关闭 Tether，随后 6 秒未观察到自动重开。长时间拍摄、Guardian 反复拔插、睡眠唤醒及其他硬件仍待验证。

## Official shooting baseline / 原厂拍摄基线

Before testing Guardian, official Tether 2.12 displayed actual S1H live view and remotely captured a RAW file that was saved to a separate local test directory: 35,581,440 bytes, with card + PC storage and RAW transfer enabled. The UI accepted and read back ISO 100 → 200 → 100, shutter 1/60 → 1/80 → 1/60, aperture F8.0 → F7.5 → F8.0, and color temperature 5500 K → 5600 K → 5500 K. The original settings were restored and Tether quit normally. This establishes official shooting and control on this connection, not successful Guardian recovery. Test photos and private reports are excluded.

守护器测试前，官方 Tether 2.12 显示了 S1H 实时画面，并遥控拍摄一张 RAW，已保存到独立本地测试目录，大小 35,581,440 字节；设置为记忆卡＋PC、开启 RAW 传输。界面接受并回读了 ISO 100 → 200 → 100、快门 1/60 → 1/80 → 1/60、光圈 F8.0 → F7.5 → F8.0、色温 5500 K → 5600 K → 5500 K。原设置已恢复，Tether 正常退出。这证明该次连接中的原厂拍摄及控制可用，不等于守护器恢复已经成功。测试照片和私人报告不公开。

## Earlier native transport experiments / 此前原生通信实验

An independent native preview prototype obtained 640×432 preview at about 19 fps and 1600×1072 JPEG at a higher reported format. Three physical reconnect observations succeeded across prototype builds. A separate libgphoto2 harness captured and downloaded one 6000×4000 RAW (36,093,440 bytes), with a 1.851194-second download, about 19.497 MB/s, over a negotiated 5 Gbps link. Neither preview fetch counts nor one RAW transfer measure maximum USB throughput.

The preview-only UI lacks integrated shooting and full camera controls and is not being released as a Tether replacement. These observations do not validate Guardian or general reconnection reliability. The project now prioritizes retaining the official shooting UI with a separate connection supervisor. No vendor binary, camera image or private local harness is distributed.

此前独立原生预览原型取得约 19 帧／秒的 640×432 预览，以及较高档位的 1600×1072 JPEG；不同原型构建累计观察到 3 次物理重连成功。另一个 libgphoto2 本地程序拍摄并下载过一张 6000×4000 RAW（36,093,440 字节），下载 1.851194 秒，约 19.497 MB/s，链路协商为 5 Gbps。预览获取次数和一次 RAW 下载都不能测出 USB 最高吞吐。

仅预览界面尚未集成拍摄及完整参数控制，不作为 Tether 替代品发布。这些观察不能验证守护器或普遍重连可靠性。当前优先保留原厂拍摄界面，另做连接守护；不分发厂商程序、相机图像或私人测试程序。

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

The CLI folder built from source contains the normal entry points `恢复S1H连接.command` and `Restore S1H Connection.command`, the explicit restart entry points `重启相机服务并恢复连接.command` and `Restart Camera Service and Restore.command`, and native helpers in `bin/`. The user installs official Tether 2.12 separately. The script searches `/Applications` and `~/Applications`, or accepts an explicit path through `--tether-app`. `--check` validates the setup without accessing the camera; `--diagnose` performs the read-only ownership inspection described above.

源码构建的 CLI 目录包含普通入口 `恢复S1H连接.command`、`Restore S1H Connection.command`，明确重启入口 `重启相机服务并恢复连接.command`、`Restart Camera Service and Restore.command`，以及 `bin/` 内的原生辅助程序。用户需单独安装官方 Tether 2.12。脚本搜索 `/Applications` 和 `~/Applications`，也接受 `--tether-app` 显式路径；`--check` 仅检查环境、不访问相机，`--diagnose` 执行上述只读占用诊断。

Panasonic binaries, artwork, Qt libraries and installer packages are excluded from public release artifacts and remain covered by their respective licenses.

松下程序、图标、Qt 库与安装包不属于公开产物，其原有许可继续有效。

## Logs and reports / 日志与报告

Protocol recovery does not replace macOS privacy or accessory permissions. If prompted, the user must grant the required removable-volume access to Tether or Terminal, or USB-accessory access to the application they intend to use. A successful helper exchange is separate from the vendor app's permission state.

协议恢复不能替代 macOS 隐私或配件权限。系统提示时，用户仍需允许 Tether 或终端必要的可移动宗卷访问，或为当前应用允许 USB 配件访问。恢复程序握手成功，与厂商应用的权限状态是两个独立条件。

Logs contain protocol headers, lengths, statuses and version information; ownership diagnostics also include process metadata. Review excerpts for private paths before sharing. Do not include image payloads, camera serial numbers or unredacted full crash reports. A crash report showing Tether 2.11 is an older-app report, not a verified failure of the tested 2.12 path.

日志包含协议头、长度、状态和版本信息；占用诊断还包含进程元数据。分享前请检查并去除私人路径。不要提交图像内容、相机序列号或未脱敏的完整崩溃报告。显示 Tether 2.11 的崩溃报告属于旧版应用，不能直接证明已验证的 2.12 路径失败。

## 0.2.2 recovery gate correction / 恢复前检查修正

A later recurrence showed two successful normal Tether quits with no new repair helper while Preview was detected. The direct Open action could then launch Tether without preparation. The system camera service was the registered interface owner; Preview's running state was a conservative blocker, not proof that it owned USB. Normal Preview quit allowed queued recovery, service release and strict PTP validation, followed by actual official live view.

Version 0.2.2 makes all Guardian launch entries use fresh preparation while Tether is absent, exposes fixed-name blockers separately from ownership, and logs blocked/unblocked states. Camera apps appearing during a successful repair preserve pending recovery instead of consuming the I/O retry budget. A hardware check of the new Open entry confirmed that it waited while Preview ran, then completed strict recovery after Preview quit normally and returned to official live view. Full hardware-free build validation passes 302 checks: 16 identity, 43 service, 50 event writer, 193 controller checks. This correction does not establish universal hot-plug or sleep/wake reliability.

后续复发中，Tether两次正常退出后，在“预览”被检测为运行时没有执行新的恢复；直接打开入口随后绕过了准备。登记的接口占用者是系统相机服务，“预览”运行只是保守拦截，不能证明它占用了USB。正常退出“预览”后，排队的恢复完成服务释放及严格PTP检查，官方实时画面恢复。

0.2.2 将 Tether 未运行时的启动入口统一到新的准备流程，分开显示客户端检查与接口占用者，并记录阻塞和解除。恢复成功后出现相机客户端时保留任务，不消耗 I/O 重试预算。新版打开入口的实机复测确认：“预览”运行时保持等待，正常退出后完成严格恢复并重新显示官方实时画面。完整无硬件验证共 302 项：身份 16、服务 43、事件 50、控制器 193；不能据此保证普遍拔插或睡眠唤醒可靠性。

## 0.2.3 empty enumeration correction; USB hot-plug still fails / 空枚举修正，USB 热插拔仍失败

On 0.2.2, the interval from observing the old Tether process exit to the verified new launch was 3.852 seconds. Actual official live view was confirmed afterward. A subsequent USB unplug, five-second wait and reconnect failed: the S1H remained on “Please wait”, could not switch off normally and required removing and reinserting its battery. The host had no enumerated S1H. A read-only API reproduction returned success (`kr = 0`), a NULL matching iterator and zero services; the old helper misclassified that empty success as iterator invalidation.

Apple's [IOKit header documentation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/IOKitLib.h) defines a successful NULL result from `IOServiceGetMatchingServices` as no matching services. Version 0.2.3 changes only the service helper's two matching-service enumeration checks. API errors still fail closed; non-NULL iterators must still pass their validity check. Recursive registry traversal validation is unchanged. Eight added service tests raise that suite from 43 to 51; the complete hardware-free build passes 310 checks (16 + 51 + 50 + 193).

The installed 0.2.3 build (bundle version 5) verified a new Tether launch 3.877 seconds after the old process exit was observed. Camera recognition and actual live view were confirmed afterward; 3.877 seconds does not measure time to live view. **The same five-second USB hot-plug test then failed again.** Guardian recorded detach and delivered normal quit; Tether exited 0.968 seconds after detach. No camera re-enumeration, repair helper or Tether relaunch followed. Read-only inspection correctly returned exit zero, zero devices and no inspection error. Guardian was paused, and the camera again required a battery power reset.

The empty-enumeration fix is therefore verified independently of the remaining camera lockup. Neither its cause nor a permanent hot-plug cure has been established. Guardian cannot run USB/PTP recovery without an enumerated camera. Recommended workflow is capture/transfers complete → End This Shoot → confirm Tether exit → disconnect USB; that sequence has not yet been hardware-retested in this round. For a stuck camera, pause Guardian and, after confirming no write activity, disconnect USB and attempt normal OFF before a necessary battery power reset. These observations do not establish sleep/wake, long-duration or other-model reliability.

0.2.2 中，从观察到旧 Tether 进程退出至核实新启动耗时 3.852 秒，之后另行确认实际官方预览通过。但随后拔下 USB、等待五秒并重连失败：S1H 停在“Please wait”，无法正常关机，需取出并重新装入电池复位；主机实际没有枚举到 S1H。只读 API 复现得到成功返回（`kr = 0`）、NULL 匹配迭代器及零服务，旧辅助程序却将空结果误判为迭代器失效。

Apple 的 [IOKit 头文件说明](https://github.com/apple-oss-distributions/IOKitUser/blob/main/IOKitLib.h)规定，`IOServiceGetMatchingServices` 成功返回 NULL 表示没有匹配服务。0.2.3 仅改动服务辅助程序的两处匹配枚举检查：API 错误仍拒绝继续，非 NULL 迭代器仍需通过有效性检查，递归注册表遍历校验未放宽。新增八项服务测试，服务套件从 43 增至 51；完整无硬件构建检查共 310 项（16 + 51 + 50 + 193）通过。

已安装的 0.2.3（bundle version 5）从观察到旧进程退出至核实新 Tether 启动耗时 3.877 秒。之后另行确认相机识别及实际实时预览；3.877 秒并非恢复到预览的耗时。**随后相同五秒 USB 拔插测试仍失败。** Guardian 记录断开并送达正常退出请求；断开后 0.968 秒 Tether 已退出，但相机没有重新枚举，也未继续执行恢复辅助程序或重新启动 Tether。只读检查正确返回退出码零、零设备及无检查错误。守护随后暂停，相机再次需要电池断电复位。

因此，空枚举检测已被独立验证修正，但相机卡住仍存在，根因及永久热插拔修复均未证实。相机未枚举时，Guardian 无法执行 USB／PTP 恢复。建议拍摄及传输完成 → 结束本次拍摄 → 确认 Tether 已退出 → 再断开 USB；此顺序尚未在本轮实机复测。相机卡住时，先暂停守护，确认无写入后断开 USB、尝试正常 OFF，仍不能关机时再进行必要的电池断电复位。这些观察不能证明睡眠唤醒、长时间或其他机型可靠性。

A later reattachment did enumerate at 5Gbps, but an externally observed Tether appeared before any Guardian preparation/launch request. Start while that process was running correctly observed only; official Tether remained unconnected. Normal quit then allowed guarded service release and strict recovery, followed by a verified Guardian launch and actual official live view. This is a distinct failure mode from an absent USB camera and does not establish who launched the external process.

随后一次重新接入中，S1H 已枚举为 5Gbps，但在守护发出任何准备或启动请求前，已观察到外部来源未知的 Tether 进程。运行中点击开始守护只观察状态，官方程序仍未联机。正常退出后，守护完成有校验的服务释放及严格恢复，新启动的官方 Tether 随后实际显示实时画面。这与 USB 中完全没有相机是两种状态，日志不能确定外部进程由谁打开。


## 0.2.4 confirmed external ownership / 已确认的外部占用

A read-only observation identified NegPy as the confirmed interface owner while the known-camera-app list was empty. The earlier gate could therefore show preparation as ready. Version 0.2.4 adds a pure ownership gate based on fresh confirmed executable identity, not a running-app name. The exact system camera-service path and canonical installed official Tether executables are exempt from the third-party classification; this does not bypass the existing service-restart guard.

Snapshots expose `external_interface_owner` and sanitized `external_interface_owner_info` (`name`, `pid`); `inspection_gate: external_interface_owner` takes precedence for presentation. The UI also requires fresh valid inspection and confirmed ownership before showing a red name. Unknown or expired evidence clears the name and red styling. A known app merely running remains a separate conservative blocker. The tested NegPy owner/recovery/help rows were visibly red with complete text while Guardian was paused; no camera action was performed by that check.

Pending preparation waits for release without consuming its I/O retry budget. A running Tether still means observe-only, even after another app releases the interface; an explicit Reconnect requests normal quit first. External ownership never authorizes terminating that application. Version 0.2.4 passed **347 hardware-free checks** on its full build. The earlier 0.2.3 count of 310 remains a historical checkpoint. Physical hot-plug was not retested on 0.2.4.

一次只读观察确认 NegPy 实际持有接口，但已知相机软件列表为空，旧 gate 因此可能错误显示可准备。0.2.4 增加基于新鲜、已确认可执行文件身份的纯占用判定，不以运行软件名称推断占用。系统相机服务精确路径和默认安装位置的官方 Tether 可执行文件不按第三方归类，但不会绕过既有服务重启守卫。

快照提供 `external_interface_owner` 及过滤后的 `external_interface_owner_info`（`name`、`pid`），提示用的 `inspection_gate: external_interface_owner` 优先。界面还要求检查新鲜有效、占用已确认，才显示红色名称；未知或过期会清除旧名称及红色。仅检测到已知软件运行仍是另一项保守拦截。实机已确认 NegPy 的占用／恢复／帮助三行均红色且文本完整，当时守护处于暂停状态，该检查未操作相机。

等待释放时保留准备任务，不消耗 I/O 重试次数；即使其他软件释放，只要 Tether 仍运行就只观察，需要正常重启时明确选择重新连接。外部占用不授权结束该软件。0.2.4 完整构建通过 **347 项无硬件检查**，0.2.3 的 310 项保留为历史记录。0.2.4 未复测物理热拔插。
