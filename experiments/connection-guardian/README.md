# LUMIX Connection Guardian

[简体中文](README.zh-CN.md)

A menu-bar connection supervisor for DC-S1H. Separately installed official LUMIX Tether 2.12 retains shooting, exposure controls, white balance and original-file saving. This utility prepares the connection, monitors USB changes and coordinates application restarts.

This is **Guardian 0.2.3 community beta**, published as [guardian-v0.2.3](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.3). A previous single Guardian recovery handoff was followed by official Tether preview and a saved 6000×4000 RAW (36,048,384 bytes). Aperture, shutter, ISO and color-temperature controls were verified separately in the official UI. These short checks do not establish repeated hot-plug, sleep/wake or long-duration reliability.

The app provides End This Shoot and separates USB detection, the Tether process and the shooting-connection state. Local rotating event logs support troubleshooting. Confirm shooting inside Tether: a present USB device, recorded interface owner or running process never establishes that capture is working.

## 0.2.3 correction

The service helper now accepts a successful `IOServiceGetMatchingServices` result with a NULL iterator as no matching services. Only its two matching-service enumeration checks changed: actual API failures and invalid non-NULL iterators still fail closed, and recursive registry validation is unchanged. The service self-tests increased from 43 to 51; the complete hardware-free build passed **310 checks: 16 identity, 51 service guard, 50 event writer and 193 controller/policy**.

From the observed exit of the old Tether process to the verified new launch, the measured interval was 3.852 seconds on 0.2.2 and 3.877 seconds on the installed 0.2.3 build. Official live view was confirmed afterward; these intervals do not measure time to live view. **On the tested setup, the physical USB test—unplug, wait five seconds, reconnect—failed on both versions.** The camera remained on “Please wait”, could not switch off normally and needed a battery power reset each time. On 0.2.3, Tether exited normally 0.968 seconds after detected detach, but the camera did not re-enumerate; no subsequent repair or launch ran. The corrected read-only inspection returned exit zero, zero devices and no error. That confirms the empty-enumeration correction, not a cure for the camera lockup. Its cause remains unproven, and Guardian cannot run its USB/PTP recovery while the camera is not enumerated.

Recommended sequence: finish shooting and transfers → End This Shoot → confirm Tether has exited → disconnect USB. This sequence has not yet been hardware-retested in this round. If the camera is stuck, pause Guardian; after confirming no write activity, disconnect USB and try normal OFF, using a battery power reset if shutdown remains impossible. General hot-plug, sleep/wake and long-duration reliability are not established.

### Earlier 0.2.2 correction

A separate pre-recovery check names detected camera clients such as Preview, without claiming they actually own the interface. The actual owner is shown separately. Checking and opening Tether now uses the preparation chain while Tether is absent; blocked and unblocked states are recorded locally.

## Use

1. Install [official LUMIX Tether 2.12](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html) separately. This tool neither includes nor modifies Panasonic software.
2. Connect the S1H using a data cable and select PC(Tether).
3. Open `LUMIX Connection Guardian.app` to view connection status, then choose Start Guardian and Open Tether. Closing the status window keeps the menu-bar app running; reopen the window from its menu.
4. Wait for connection preparation and Tether startup, then confirm preview and shoot in Tether.
5. After capture and file transfers finish, choose End This Shoot. It disables automatic recovery first, requests a normal Tether quit, and never reopens Tether automatically. Guardian stays in the menu bar.
6. To leave Tether open while stopping automatic recovery, choose Pause Recovery. Quitting Guardian also leaves Tether alone; any active bounded preparation finishes its cleanup first.

The app does not install a login item, system service or LaunchAgent. Its Chinese/English interface follows the preferred system language. It uses Tether's existing language argument when launching that application.

## Troubleshooting order

1. **Stop capture and wait for file transfer to finish.** Keep the USB data cable connected, the camera powered on and **PC(Tether)** selected. Check Guardian’s status.
2. **Quit applications named by Recovery Check normally.** Save pending edits first, then quit Preview, Image Capture or another listed camera client. A running application is not proof that it owns the camera.
3. **USB detected, but Tether waiting for a camera:** open Guardian’s menu-bar item → **Reconnect (Quit Tether Normally)**. Wait for the old Tether to exit and for Guardian to prepare the connection and launch a new window. Start Guardian alone does not restart an existing Tether. Do not open Tether separately from Dock/Finder during preparation.
4. **Tether is absent:** launch it through Guardian’s **Check Connection and Open Tether** (also ⌘O), then wait for preparation. Once the official camera list shows DC-S1H, click **Start**, then **LV**, and verify an image. USB presence and a running process alone do not establish shooting readiness.
5. **Camera not detected:** check power, PC(Tether) and the data cable. **If it is stuck on “Please wait” and normal OFF fails:** pause Guardian → disconnect USB → confirm there is no recording or card write → set OFF and remove the battery for about 10 seconds → reinstall it and power on. Once normal operation returns, reconnect USB, select PC(Tether) and return to step 4. Guardian cannot send USB/PTP recovery to a camera that has not enumerated again.
6. **If it still fails, stop repeated hot-plug attempts.** Check Recovery Check and Show Diagnostics and Logs Folder, and retain the failure time. A quit timeout does not prove the camera is idle; do not force-quit during file transfer.

Recommended shutdown order: **finish transfer → End This Shoot → confirm Tether exited → disconnect USB.** This order has not been hardware-retested in this round. The five-second unplug/reconnect during live view failed on the tested setup; automatic recovery is not guaranteed.

## Scope

Monitoring reads USB registry information, ownership and application processes. A new USB recovery may start only while Tether is absent. A camera-service restart requires the existing guard to confirm this user's specific service and permit the action. The tool does not seize drivers, terminate other camera applications, capture images, or read/delete photographs.

Reconnect first requests a normal Tether quit. A confirmed physical USB detach may also request normal quit of the exact verified Tether instance Guardian launched. A quit timeout does not prove that the camera is idle, so there is no automatic forced termination; Force Restart after reconnect and Force Quit after ending a shoot are separate explicit actions. Force Quit at the end of a shoot never relaunches Tether. Recovery retries are bounded.

Other applications can still launch independently; this utility cannot impose a cross-application USB lock. It cannot retain exclusive ownership while Tether needs the interface or repair Tether's internal thread waits from outside. An internal application failure requires restarting Tether and preparing a new connection.

## Local event logs

Guardian records workflow actions such as Start, End This Shoot, Pause and Reconnect, its own application-launch requests, and observed Tether process changes. These describe the supervisor's actions and observations; they are not shutter events or confirmation that a photograph was captured, saved or ready to capture.

Events use JSON Lines at `~/Library/Logs/S1H Connection Guardian/events.jsonl`. Each file is limited to 1 MiB, with up to three rotated files named `events.jsonl.1`, `events.jsonl.2` and `events.jsonl.3`. Run and attempt identifiers, timestamps, process IDs and Guardian state help correlate related events.

A Guardian-issued launch request is distinguished from a Tether process observed externally with an unknown source. A launch request records what Guardian asked the system to do; it does not prove which action ultimately caused a process to appear. A process observation cannot establish human intent or whether Finder, the Dock or another application initiated startup. Having `launchd` as a parent does not resolve that source.

The event log excludes photographs, camera serial numbers, raw inspection snapshots and full filesystem paths. Existing helper logs are unchanged and may contain process metadata or local paths. All logs stay on this Mac and are not automatically uploaded; review any material before sharing it. Event logging is diagnostic support, not a complete audit of camera activity.


## Rate display

“Negotiated 5 Gbps” is the USB link mode, not current transfer throughput. Passive registry inspection of the tested S1H does not expose cumulative transferred-byte counters, so this version does not report real-time USB MB/s or present an unmeasured value as 0 MB/s. Photo file-write rates are affected by buffering and disk I/O and cannot substitute for USB throughput. Apple's [IOUSBHostCompletionHandler](https://developer.apple.com/documentation/iousbhost/iousbhostcompletionhandler) reports bytes for the caller's own completed request, not passive counters for official Tether's transfers.

## Build

Use an Apple Silicon Mac with Xcode Command Line Tools:

```sh
./build.sh
```

Builds and pure self-tests do not access the camera or launch Tether. The app is locally signed and not notarized. Logs remain local and are not automatically uploaded; review them before sharing.

An iCloud file provider may attach Finder metadata to an app in a synchronized directory, affecting strict signature validation. Build outside that directory when needed:

```sh
GUARDIAN_OUTPUT_DIR="$HOME/Library/Caches/LUMIX Connection Guardian/build" ./build.sh
GUARDIAN_OUTPUT_DIR="$HOME/Library/Caches/LUMIX Connection Guardian/build" ./package.sh
```

Packaging includes only this project's app, documentation, license and approved donation image. It excludes official Tether, photographs and local logs.

## Support development

Donations are entirely optional and support further compatibility work and validation.

<img src="https://raw.githubusercontent.com/easonzhangbin/lumix-tether-macos-fix/main/assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">
