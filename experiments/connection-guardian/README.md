# LUMIX Connection Guardian

[简体中文](README.zh-CN.md)

A menu-bar connection supervisor for DC-S1H. Separately installed official LUMIX Tether 2.12 retains shooting, exposure controls, white balance and original-file saving. This utility prepares the connection, monitors USB changes and coordinates application restarts.

The current community beta is Guardian 0.2.5 for Apple Silicon. The release includes a DMG and its SHA-256 checksum. A previous Guardian recovery handoff was followed by official Tether preview and a saved 6000×4000 RAW (36,048,384 bytes). Aperture, shutter, ISO and color-temperature controls were verified separately in the official UI. [Guardian 0.2.5 downloads](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5)

The app provides End This Shoot and separates USB detection, the Tether process and the shooting-connection state. Local rotating event logs support troubleshooting. Confirm shooting inside Tether: a present USB device, recorded interface owner or running process never establishes that capture is working.

## High Resolution Diagnostic

1. Confirm the S1H is connected in Tether, enable RAW file transfer, and set the camera's High Resolution image size to XL.
2. Choose **Start High Resolution Diagnostic…** from the Guardian menu. Select the same import folder as in Tether.
3. Wait for **Watch ready**, then take one XL shot. Guardian looks for a new structurally complete 12000×8000 DC-S1H Pixel Shift RW2 in that folder or an immediate date subfolder named `YYYYMMDD`. The 30-second timer starts when the watch is ready. Guardian does not detect the shutter press or read the memory card.
4. If a complete RAW arrives, Guardian reports it. If the wait expires, the folder check fails, or the USB or Tether session changes while waiting, Guardian saves available evidence. **Save Diagnostic Now** can collect it immediately while waiting.
5. After collection, use **Show This Diagnostic Folder** to inspect the report under `~/Library/Logs/S1H Connection Guardian/diagnostics`. **End Diagnostic Mode** exits the diagnostic and leaves automatic recovery paused.

The diagnostic pauses automatic recovery from the moment it starts so Guardian leaves Tether and the USB session alone. Reports can include Guardian events, available logs and thread samples from verified Tether and camera-service processes, and a matching Tether crash report when available. Diagnostics stay on this Mac. Review their contents before sharing.

The 0.2.5 timeout and session hold were tested with the S1H connected. This feature gathers evidence for the intermittent high-resolution RAW transfer stall. The cause and a fix remain unverified.

## External interface ownership

Fresh confirmed third-party ownership, including the observed NegPy case, is shown in red in the interface-owner and recovery rows. Disconnect the camera in that app or quit it normally; Guardian does not terminate it or discard its work. Unknown or stale inspection clears the warning and old owner name. Detection of Preview or another known running client is a separate conservative blocker, not proof that the client owns USB. Normal system `ptpcamerad` ownership is eligible only for the existing guarded current-user service procedure, not third-party-app termination.

All launch entries preserve fresh inspection → strict preparation → post-preparation validation → official launch while Tether is absent. Blocked pending work waits without consuming I/O retry counts. When Tether is still running, Guardian remains passive even after a foreign owner releases the camera. Request Reconnect if Tether needs a normal restart. The 0.2.5 build passed 379 hardware-free checks across identity, service guard, event logging, RAW arrival and controller policy.

The earlier CLI remains available to build from source. [CLI build guide](https://github.com/easonzhangbin/lumix-tether-macos-fix/blob/main/docs/CLI.md)

## Historical 0.2.3 correction

The service helper now accepts a successful `IOServiceGetMatchingServices` result with a NULL iterator as no matching services. Only its two matching-service enumeration checks changed: actual API failures and invalid non-NULL iterators still fail closed, and recursive registry validation is unchanged. The service self-tests increased from 43 to 51; the 0.2.3 hardware-free build passed **310 checks: 16 identity, 51 service guard, 50 event writer and 193 controller/policy**.

From the observed exit of the old Tether process to the verified new launch, the measured interval was 3.852 seconds on 0.2.2 and 3.877 seconds on the installed 0.2.3 build. Official live view was confirmed afterward; these intervals do not measure time to live view. **On the tested setup, the physical USB test—unplug, wait five seconds, reconnect—failed on both versions.** The camera remained on “Please wait”, could not switch off normally and needed a battery power reset each time. On 0.2.3, Tether exited normally 0.968 seconds after detected detach, but the camera did not re-enumerate; no subsequent repair or launch ran. The corrected read-only inspection returned exit zero, zero devices and no error. That confirms the empty-enumeration correction, not a cure for the camera lockup. Its cause remains unproven, and Guardian cannot run its USB/PTP recovery while the camera is not enumerated.

Recommended sequence: finish shooting and transfers → End This Shoot → confirm Tether has exited → disconnect USB. This sequence has not yet been hardware-retested in this round. If the camera is stuck, pause Guardian; after confirming no write activity, disconnect USB and try normal OFF, using a battery power reset if shutdown remains impossible. General hot-plug, sleep/wake and long-duration reliability are not established.

### Earlier 0.2.2 correction

A separate pre-recovery check names detected camera clients such as Preview, without claiming they actually own the interface. The actual owner is shown separately. Checking and opening Tether now uses the preparation chain while Tether is absent; blocked and unblocked states are recorded locally.

## Install and use

1. Install [official LUMIX Tether 2.12](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html) separately. This tool neither includes nor modifies Panasonic software.
2. Open the Guardian 0.2.5 DMG and drag the app to the Applications shortcut. [Release downloads](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5)
3. Connect the S1H using a data cable and select PC(Tether).
4. Open `LUMIX Connection Guardian.app` to view connection status, then choose Start Guardian and Open Tether. Closing the status window keeps the menu-bar app running. Reopen the window from its menu.
5. Wait for connection preparation and Tether startup, then confirm preview and shoot in Tether.
6. After capture and file transfers finish, choose End This Shoot. It disables automatic recovery first and requests a normal Tether quit. Guardian stays idle in the menu bar.
7. To leave Tether open while stopping automatic recovery, choose Pause Recovery. Quitting Guardian also leaves Tether alone. Any active bounded preparation finishes its cleanup first.

This beta uses an ad-hoc signature and has no Apple notarization. If macOS prevents opening the download, verify its source and checksum and review Apple's guidance. [Open an app safely on your Mac](https://support.apple.com/en-us/102445)

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

**DC-S1H and arm64 / Apple Silicon only.** Install official Tether 2.12 separately. The tested setup is M1 Max/macOS 27.0.1; the macOS 12 deployment target does not establish support for every OS, Mac or camera.

Monitoring reads USB registry information, ownership and application processes. A new USB recovery may start only while Tether is absent. A camera-service restart requires the existing guard to confirm this user's specific service and permit the action. The High Resolution Diagnostic only reads the metadata and lengths of new RAWs in the selected folder.

Reconnect first requests a normal Tether quit. A confirmed physical USB detach may also request normal quit of the exact verified Tether instance Guardian launched. A quit timeout does not prove that the camera is idle, so there is no automatic forced termination; Force Restart after reconnect and Force Quit after ending a shoot are separate explicit actions. Force Quit at the end of a shoot never relaunches Tether. Recovery retries are bounded.

Other applications can still launch independently; this utility cannot impose a cross-application USB lock. It cannot retain exclusive ownership while Tether needs the interface or repair Tether's internal thread waits from outside.

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

The source packaging script creates a ZIP with this project's app, documentation, license and approved donation image. The release DMG contains the app, an Applications shortcut and bilingual installation notes.

## Support development

Donations are entirely optional and support further compatibility work and validation.

<img src="https://raw.githubusercontent.com/easonzhangbin/lumix-tether-macos-fix/main/assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">
