> Looking for the menu-bar Guardian app? See the [project introduction](https://github.com/easonzhangbin/lumix-tether-macos-fix/blob/main/README.md). This page describes the separate CLI workflow.

# LUMIX Tether USB Fix for macOS

[简体中文](https://github.com/easonzhangbin/lumix-tether-macos-fix/blob/main/docs/CLI.zh-CN.md)

The CLI is retained as [repository source](https://github.com/easonzhangbin/lumix-tether-macos-fix/tree/main), not an old release download. Build it using [Building from source](#building-from-source) below. Only the current [Guardian 0.2.4 beta](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.4) is retained as a binary release; its app bundle is separate from this CLI workflow.

A small Apple Silicon USB recovery helper, started by a `.command` script, that clears pending PTP responses before opening Panasonic LUMIX Tether 2.12. It restored USB tethering and live view on one tested Panasonic DC-S1H setup, over both USB 2 and USB 3.

**Use the script before each Tether launch.** The problem has recurred after unplugging and reconnecting USB3. This is a launch-time recovery procedure, not a permanent driver or firmware fix.

This is an independent community project. It is not affiliated with Panasonic or Apple.

## What is included

- **Restore S1H Connection.command** and **恢复S1H连接.command**, equivalent script entry points.
- **Restart Camera Service and Restore.command** and **重启相机服务并恢复连接.command**, explicit service-restart entry points for a connection still owned by the camera service.
- A native IOUSBHost recovery helper at `bin/s1h_iousbhost_probe`.
- A guarded service-ownership helper at `bin/s1h_camera_service`.
- Automatic selection of Tether's existing interface language, with a command-line override.

The locally built `dist/LUMIX Tether USB Fix/` folder contains the scripts and `bin/`. Keep them together. **It does not contain LUMIX Tether, Panasonic's installer or icons, or Qt libraries.** Install the official application separately.

## Tested configuration

| Component | Verified setup |
| --- | --- |
| Camera | Panasonic DC-S1H |
| Mac | MacBookPro18,2, Apple M1 Max |
| macOS | 27.0.1, build 26A434 |
| Tether | 2.12, build 2.12.0.5 |
| USB 2 | 480 Mbps negotiated link; Tether live view restored |
| USB 3 | 5 Gbps negotiated link; Tether live view restored |

These are negotiated USB link speeds, not measured file-transfer throughput. Long-duration stability has not been measured, and reconnecting the camera can require another recovery.

The helper is built for **arm64 / Apple Silicon**, with a macOS 12 deployment target. The actual hardware test above was on macOS 27.0.1; the deployment target does not establish compatibility with every intervening macOS release. Intel Macs are not supported by this release.

**DC-S1R, DC-S1 and other LUMIX cameras are untested.** Some bodies may share USB identifiers, but that does not establish that this recovery procedure is appropriate for them.

## Getting started

1. Download and install **LUMIX Tether 2.12** from [Panasonic's official download page](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html).
2. Obtain the [repository source](https://github.com/easonzhangbin/lumix-tether-macos-fix/tree/main), follow [Building from source](#building-from-source), then use the resulting `dist/LUMIX Tether USB Fix/` folder. Old release and CI downloads are no longer installation sources.
3. Close Tether and all other camera or photo-import applications. Keep the other applications closed while using Tether. Connect the S1H with a data-capable USB cable and choose **PC(Tether)** on the camera.
4. Double-click **Restore S1H Connection.command** or **恢复S1H连接.command**. It runs in Terminal and looks for official Tether 2.12 in `/Applications` and `~/Applications`.
5. After recovery and a successful fresh-session check, the script opens Tether. Select the camera, click **Start**, then **LV** for live view.

Start Tether through the script each time, including after reconnecting the camera. A successful session does not prevent the condition from recurring. The default recovery does not forcibly stop camera applications or restart macOS's camera service.

If macOS asks Tether or Terminal for access to the camera's removable volume, or asks permission to connect a USB accessory, allow the access needed by the application you are using. If recovery succeeds but Tether cannot connect, check **System Settings → Privacy & Security → Files and Folders** for the actual Tether 2.12 application. System permission may still be required after a successful protocol recovery.

For a nonstandard installation path, run the script from the extracted release folder:

```sh
./"Restore S1H Connection.command" --tether-app "/path/to/LUMIX Tether.app"
```

The selected app must be official Tether 2.12.

### Keeping other applications off the camera

The recovery helper must release the USB interface before official Tether can open it. In this recovery-then-launch design, leaving the helper running with an exclusive USB lock would also prevent Tether from connecting. The tool therefore provides **no permanent reservation of the interface for Tether**.

Use this sequence when a connection is lost:

1. Quit all camera/import applications and keep them closed while using Tether.
2. After a USB reconnect or sleep/wake, quit Tether, confirm PC(Tether), and run the **normal recovery script first**.
3. If the interface is still busy, run `--diagnose`. Use the [explicit service-restart entry point](#if-the-camera-service-still-owns-the-interface) only when the diagnostic identifies the camera service as the owner.
4. If the guard refuses, follow its diagnostic: close the identified application and leave only one camera connected. Do not force-stop an unknown owner. If ownership cannot be resolved, save your work and restart the Mac as a last controlled recovery step, then run normal recovery again.

#### Optional: reduce automatic importer launches

With Tether closed, open Image Capture, select the connected camera, and use its Action/options control to set **Connecting this [device] opens → No application**, if available. The control's location varies by macOS version. Quit Image Capture afterward. See [Apple's per-device connection menu](https://support.apple.com/guide/image-capture/image-capture-imgcp1003/mac) and [Capture One's official No Application instructions](https://support.captureone.com/hc/en-us/articles/360002423997-Why-does-Capture-One-automatically-start-every-time-I-connect-my-camera-CF-card-or-iPhone).

This reduces automatic app launches only. It does not stop an application that is already running from noticing or accessing the camera, and it does not lock USB ownership.

### If the camera service still owns the interface

Version 1.0.1 adds a read-only ownership check and a separate, opt-in service-restart mode. Normal recovery never restarts the service automatically. If recovery fails, the script checks ownership read-only and points to the explicit restart entry point when appropriate.

To collect diagnostics without opening the USB interface, running the PTP probe, launching Tether or restarting the service:

```sh
./"Restore S1H Connection.command" --diagnose
```

If the diagnostic reports that `ptpcamerad` still owns the interface:

1. Close **all camera and photo-import applications**, including Tether, Preview, Image Capture and Photos if running.
2. Double-click **Restart Camera Service and Restore.command**, or explicitly select the same mode in Terminal:

   ```sh
   ./"Restore S1H Connection.command" --restart-camera-service
   ```

3. The tool checks ownership and process identity, then attempts the service restart, the strict USB recovery and finally the Tether launch. A failed guard stops the sequence.

**This explicitly interrupts the current user's PTP camera service.** The guarded restart may send a normal termination request, then force-stop the same verified service instance if it does not exit within the bounded wait. Although known camera apps and ownership are checked, the tool cannot prove that every background XPC client is idle; close all camera/import software first. Unknown ownership, other PTP-camera ownership or a running camera app can cause the restart to be refused.

This mode does not use `sudo`, change security settings or install a persistent service. `--diagnose` cannot be combined with `--check` or `--restart-camera-service`. Each diagnostic or recovery run prints the path to its log; review it for private paths before sharing excerpts.

### Language

Each script launch explicitly selects Tether's language from the system's preferred language. Tether supports `zh`, `en`, `ja`, `de`, `es`, `fr`, `it` and `ru`; other preferred languages fall back to English.

You can override the choice or run a check without accessing the camera:

```sh
./"Restore S1H Connection.command" --language en
./"Restore S1H Connection.command" --language zh
./"Restore S1H Connection.command" --language auto --check
```

The other supported language codes can also be passed to `--language`. Tether 2.12 already contains these translations; the script passes its existing `-lang=xx` argument without replacing resources or patching Panasonic's executable.

**Start through the script when you want automatic language selection.** Opening the original Tether icon directly may use a previously saved language such as English.

### If macOS blocks a downloaded file

The helper uses a local ad-hoc signature and has not been notarized with an Apple Developer ID. Gatekeeper may block downloaded scripts or the helper on another Mac. Review the source and download origin, then follow [Apple's instructions for opening apps safely](https://support.apple.com/en-us/102445) if you decide to trust the files.

## How the recovery works

On the tested S1H, an unread `GetDeviceInfo` transaction remained on the bulk-IN endpoint: a 237-byte Data container followed by a 12-byte OK Response, both with transaction ID 0. Attempts to write a new command timed out.

Investigation of a later USB3 reconnection found a second obstacle: the macOS PTP camera service, `ptpcamerad`, still owned the interface after all camera applications had been closed. The helper could not access the interface until that stale service instance released it. Preview was registered as a client earlier, but a subsequent USB3 failure also occurred with Preview closed. Closing Preview alone is therefore not a complete fix, and the observations do not establish it as the cause.

The helper uses Apple's native IOUSBHost API to consume complete pending containers. It treats a zero-byte timeout **at a container boundary** as an empty queue, then verifies a fresh `OpenSession` → `GetDeviceInfo` → `CloseSession` exchange. Only after that check does the script open Tether.

Recovery therefore needs both an available interface and a clean PTP transaction state. It does **not** establish which component created the pending transaction, permanently repair Apple's USB stack, or establish a universal cause for LUMIX connection failures on newer macOS versions. See [the technical notes](TECHNICAL.md) for the evidence and limits.

The helper does not take pictures, delete images, update firmware, or log image payloads or camera serial numbers.

## Troubleshooting

**A third-party app owns the interface.** If diagnosis identifies an owner such as NegPy, disconnect the camera inside that application or quit it normally. Do not use the camera-service restart to stop a different program. A known camera app merely detected as running is a conservative blocker, not proof of actual ownership.

**Live-view hot-plug freezes the camera.** On the tested setup, five-second USB unplug/reconnect during live view failed under Guardian 0.2.2 and 0.2.3 and needed battery power resets. Neither these CLI scripts nor Guardian can run USB/PTP recovery while the S1H is not enumerated. The cause is unproven; 0.2.4 has not repeated that test. Finish transfer → End This Shoot in Guardian, or quit Tether normally in the CLI workflow → confirm exit → disconnect is a recommendation, not a newly validated hot-plug fix.

**Tether 2.11 opens or an old shortcut crashes.** Confirm the version of the application being opened. An old Dock item or shortcut can still point to 2.11. This script requires official Tether 2.12 and rejects 2.11; a crash from the older app is not evidence that the 2.12 recovery failed.

**The camera or interface is busy.** Close Tether and other camera clients, including Preview or an import window if they are accessing the camera. If the interface remains busy after those apps exit, a stale `ptpcamerad` instance may still own it. An ownership error happens before the helper can drain PTP responses; it is a different failure stage from a command-write timeout. Use `--diagnose`, then the [explicit service-restart mode](#if-the-camera-service-still-owns-the-interface) if appropriate. The default script does not terminate the service automatically.

**It worked once, then failed after reconnecting.** This has been reproduced on the tested USB3 setup. Run the recovery script again before Tether. If it reports a busy interface even after camera applications are closed, include that stage and the reconnect sequence in a bug report. An earlier successful live-view session does not demonstrate a permanent system-level repair.

**No camera is found.** Check power, the data cable, the USB mode and any macOS accessory-connection prompt. This tool cannot repair a missing physical USB connection.

**A different camera is not working.** Please report the exact model as an untested configuration. Do not assume support from a shared USB ID.

For a report, use the [bug template](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml). Share only the relevant status and error lines. Do not post a camera serial number or an unredacted crash report.

## Building from source

The source build needs Xcode Command Line Tools on an Apple Silicon Mac. It uses system frameworks and does not require Homebrew, Python or third-party libraries.

From the repository root:

```sh
./scripts/build.sh
./scripts/self-check.sh
./scripts/package.sh
```

The build creates `dist/LUMIX Tether USB Fix/`, containing the normal and explicit service-restart `.command` entry points, plus the helpers in `bin/`. Packaging creates a local arm64 ZIP and its SHA-256 checksum in `dist/`. The self-check validates the artifact without opening the camera or running Tether. Use each script's `--help` option for its full interface.

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md). Reports from additional cameras and macOS versions are welcome, with clear separation between a successful handshake and verified Tether live view.

## Support development

If this tool helps your work, you can support development through Alipay. Support is entirely optional.

<img src="../assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">

## License and third-party software

This project's original scripts, recovery helper and documentation are available under the [MIT License](../LICENSE), copyright © 2026 Eason Zhang / easonzhangbin.

The MIT license does not apply to Panasonic LUMIX Tether, Panasonic artwork, Qt or other third-party components. Those remain subject to their respective licenses. LUMIX and Panasonic are trademarks of their respective owners.
