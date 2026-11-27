# LUMIX Connection Guardian

[简体中文](README.zh-CN.md)

<img src="experiments/connection-guardian/assets/GuardianAppIcon-source-v1.png" alt="LUMIX Connection Guardian app icon" width="120">

**Reconnect your S1H to Mac, and keep shooting with official LUMIX Tether.**

An independent Apple Silicon menu-bar utility that prepares the S1H USB connection, hands it to official Tether 2.12, and watches connection and application lifecycles. Panasonic's application supplies live view, shooting, aperture, shutter, ISO, white balance and original-file saving. Guardian supplies connection recovery and a clear way to finish a session.

[Download Guardian 0.2.5 beta for Apple Silicon (DMG)](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/guardian-v0.2.5/LUMIX-Connection-Guardian-0.2.5-arm64.dmg) · [Release notes and SHA-256](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5) · [Detailed guide](experiments/connection-guardian/README.md) · [Earlier recovery scripts](docs/CLI.md)

This is a community beta tested on one S1H setup. It is not affiliated with Panasonic or Apple. Official Tether must be installed separately; the download contains this project's own app and helpers only.

## S1H Native Tether

The standalone Apple Silicon app connects directly to the DC-S1H over USB for live view, remote shutter, exposure controls, and original-file transfer. [Download Native Tether 0.1.6](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.6) · [Setup and source](experiments/native-tether/README.md)

## High Resolution Diagnostic in 0.2.5

With the S1H connected in Tether, choose **Start High Resolution Diagnostic…** from the Guardian menu and select Tether's import folder. When the diagnostic shows it is ready, take one XL shot. Guardian checks for a new structurally complete 12000×8000 DC-S1H RW2 in the folder or its immediate date subfolders.

If no complete file arrives within 30 seconds of readiness, Guardian saves available local logs and thread samples. Choose **Save Diagnostic Now** while waiting to capture evidence immediately. Automatic recovery pauses when the diagnostic starts and stays paused after you exit diagnostic mode. Use **Show This Diagnostic Folder** to review the report on your Mac.

The diagnostic preserves evidence. The intermittent high-resolution RAW transfer stall remains unresolved. Earlier five-second USB hot-plug tests required a battery power reset, and 0.2.5 has not repeated those tests. [Detailed diagnostic steps](experiments/connection-guardian/README.md#high-resolution-diagnostic)

## External interface ownership

A fresh, confirmed third-party interface owner now produces a red warning: for example, **“Interface owned by NegPy; disconnect there or quit normally.”** Unknown or expired evidence clears the name and red warning. A known camera app detected as running is a separate conservative recovery blocker, not proof of ownership. The normal macOS `ptpcamerad` service is distinguished from third-party software and is eligible only for guarded service recovery. Guardian never closes other camera apps automatically.

Pending preparation waits for blockers to clear without spending its I/O retry budget. If Tether is still running, releasing another app does not trigger USB work: use **Reconnect** when a normal Tether restart is needed.

### Earlier 0.2.3 correction

Fixes an inspection error when macOS successfully reports no matching USB services with a NULL iterator. Actual API errors and invalid non-NULL iterators still stop recovery; recursive registry checks are unchanged. This fixes empty-device detection, not the unexplained camera lockup described below.

This beta cannot prepare a connection while the S1H is absent from USB enumeration.

### Earlier 0.2.2 correction

The pre-recovery check now names other camera clients that must quit normally, including Preview. A detected application is a conservative blocker, not proof that it owns the camera; actual interface ownership is shown separately. All Guardian launch entries check and prepare the connection while Tether is absent. Blocked and unblocked recovery states are logged.

## What it does

| Action | Behavior |
| --- | --- |
| Start Guardian | Check the camera and other clients, prepare a fresh USB/PTP session while Tether is absent, then open official Tether. Starting opts in to guarded recovery of the current user's camera service when checks permit. |
| Observe | Show USB detection, negotiated link speed, Tether process state and a separate shooting-connection status. No new USB recovery starts while Tether is known to be running. Confirm actual preview and capture inside Tether. |
| Pause Recovery | Stop future automatic recovery and leave Tether as it is. |
| End This Shoot | Disable recovery first, then request a normal Tether quit. Keep Guardian in the menu bar without automatically reopening Tether. Finish transfers before using this action. |
| Reconnect | Request normal Tether quit, prepare the connection again and reopen it. A quit timeout enables a separate explicit Force Quit/Force Restart action; it never forces Tether automatically. |
| High Resolution Diagnostic | Watch for an XL RW2 in Tether's import folder. Save local evidence when the file fails to arrive and hold the current session without automatic recovery. |

A physical disconnect may request normal quit of the exact verified Tether instance Guardian launched. Recovery retries are bounded. Unknown ownership or other camera software can block service recovery. Guardian cannot reserve USB globally while allowing Tether to use it, or repair every internal Tether hang.

## How it works

1. Inspect USB, registered interface ownership and running camera apps read-only, using fresh observations.
2. Wait if a confirmed external owner or another detected camera client blocks preparation. A red warning is a request for you to disconnect or quit that software normally.
3. If Tether is running, observe only. **Start Guardian** and **Check Connection and Open Tether** do not repair its active session; **Reconnect** first requests normal quit.
4. With Tether absent and checks permitting, the native helper drains complete pending PTP responses and verifies a fresh session. If the verified current user's camera service prevents access, explicit Start consent permits its bounded, guarded recovery; this may terminate that specific service instance, never an arbitrary camera app.
5. Recheck camera identity, processes and ownership before launch. A newly detected blocker preserves pending preparation rather than bypassing checks.
6. Open the separately installed, unmodified official Tether. Select the camera, Start and LV there; Panasonic's app performs actual preview, capture, parameter control and saving.

## Install and use

1. Install **official LUMIX Tether 2.12** from [Panasonic](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html), in `/Applications` or `~/Applications`.
2. Open the Guardian beta DMG and drag **LUMIX Connection Guardian.app** to the Applications shortcut. [Guardian 0.2.5 release downloads](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.5)
3. Close other camera/import applications. Connect the S1H with a data cable and select **PC(Tether)**.
4. Open Guardian and click **Start Guardian**. In official Tether, select the camera, click **Start**, then **LV**. Confirm preview and take a test photo into your chosen destination.
5. After capture and file transfer finish, click **End This Shoot**. Closing Guardian's status window keeps its menu-bar item available.

Guardian starts idle and does not install a login item or persistent system service. Its UI follows Chinese/English system preferences; official Tether is launched with its existing supported-language option, with English fallback. No vendor resources are replaced.

The app is locally ad-hoc signed and **not Developer ID notarized**. Another Mac may block a downloaded copy. Review its source and origin and follow [Apple's safe-opening instructions](https://support.apple.com/en-us/102445). The tool does not disable system protections. macOS may separately request accessory or removable-volume permission for the app being used.

## Troubleshooting order

1. **Stop capture and wait for file transfer to finish.** Keep the USB data cable connected, the camera powered on and **PC(Tether)** selected. Check Guardian’s status.
2. **Quit applications named by Recovery Check normally.** Save pending edits first, then quit Preview, Image Capture or another listed camera client. A running application is not proof that it owns the camera.
3. **USB detected, but Tether waiting for a camera:** open Guardian’s menu-bar item → **Reconnect (Quit Tether Normally)**. Wait for the old Tether to exit and for Guardian to prepare the connection and launch a new window. Start Guardian alone does not restart an existing Tether. Do not open Tether separately from Dock/Finder during preparation.
4. **Tether is absent:** launch it through Guardian’s **Check Connection and Open Tether** (also ⌘O), then wait for preparation. Once the official camera list shows DC-S1H, click **Start**, then **LV**, and verify an image. USB presence and a running process alone do not establish shooting readiness.
5. **Camera not detected:** check power, PC(Tether) and the data cable. **If it is stuck on “Please wait” and normal OFF fails:** pause Guardian → disconnect USB → confirm there is no recording or card write → set OFF and remove the battery for about 10 seconds → reinstall it and power on. Once normal operation returns, reconnect USB, select PC(Tether) and return to step 4. Guardian cannot send USB/PTP recovery to a camera that has not enumerated again.
6. **If it still fails, stop repeated hot-plug attempts.** Check Recovery Check and Show Diagnostics and Logs Folder, and retain the failure time. A quit timeout does not prove the camera is idle; do not force-quit during file transfer.

Recommended shutdown order: **finish transfer → End This Shoot → confirm Tether exited → disconnect USB.** This order has not been hardware-retested in this round. The five-second unplug/reconnect during live view failed on the tested setup; automatic recovery is not guaranteed.

## Verified, and still unverified

| Item | Observed result |
| --- | --- |
| Hardware | Panasonic DC-S1H; Apple M1 Max, MacBookPro18,2 |
| System / official app | macOS 27.0.1 (26A434); Tether 2.12.0.5 |
| USB | 5 Gbps negotiated USB3; earlier script recovery also worked at 480 Mbps USB2 |
| Actual shooting | After a Guardian recovery handoff, official live view worked and one 6000×4000 RAW was captured and saved: 36,048,384 bytes |
| Camera controls | Aperture, shutter, ISO and color temperature were changed and restored separately in the official UI |
| Session controls | Pause preserved Tether; End closed it normally with no automatic reopen in a short observation |
| Normal quit and recovery | 0.2.3 verified a new Tether launch 3.877 seconds after the old process exit was observed; official live view was confirmed afterward |
| Ownership warning | On installed 0.2.4, a real NegPy connection showed red owner, recovery-check and action-hint text; Guardian remained paused |
| High Resolution Diagnostic | The 0.2.5 timeout collected a local report and thread samples while preserving the running Tether session |
| Automated checks | 379 passed across USB identity (16), service guard (51), event logging (50), RAW arrival (25) and controller policy (237). These checks run without a camera. |

In 0.2.2, a new Tether launch was verified 3.852 seconds after the old process exit was observed; official live view was confirmed afterward. A subsequent physical USB unplug, five-second wait and reconnect failed: the camera remained on “Please wait”, would not power off normally, and required a battery power reset. **The same five-second reconnect test also failed on 0.2.3.** Tether exited normally 0.968 seconds after the detected detach, but the camera did not re-enumerate, so no further recovery or launch ran. The corrected read-only inspection returned success with zero devices and no error. The camera again needed a battery power reset; its lockup cause remains unproven.

Recommended sequence: finish capture and transfers → **End This Shoot** → confirm Tether has exited → disconnect USB. This sequence has not yet been hardware-retested in this round. If the camera is stuck, pause Guardian; after confirming no write activity, disconnect USB and try normal OFF, using a battery power reset if normal shutdown remains impossible.

The tested five-second hot-plug failed. More hot-plug scenarios, sleep/wake, long shoots, bursts, other Macs/macOS versions and other bodies remain unverified. **S1R, S1 and other models are not supported by this S1H beta's strict identity path.** arm64 only; the macOS 12 build target is not a claim that every later OS has been tested.

**5 Gbps is the negotiated link mode, not live MB/s.** This passive monitor does not obtain reliable per-camera throughput counters on the tested setup. It does not substitute file-write speed or an unmeasured zero for USB throughput.

## Local event logs

`~/Library/Logs/S1H Connection Guardian/events.jsonl` records timestamps, run/attempt IDs, actions and outcomes. It rotates at 1 MiB per file with three archives. Use **Show Diagnostics and Logs Folder** to find it.

A Guardian-issued launch request and the application returned by macOS are recorded separately. An externally observed process is labeled `external_or_unknown`; logs do not infer a human action from `launchd` or prove which actor created a process. They also do not claim that a shutter fired or shooting is working.

Event fields exclude camera serials, photographs, full paths and raw inspection objects. Separate helper logs include process metadata; review any excerpt before sharing. Nothing is automatically uploaded.

## Build

Use Xcode Command Line Tools on an Apple Silicon Mac:

```sh
./experiments/connection-guardian/build.sh
./experiments/connection-guardian/package.sh
```

Builds and self-tests do not open the camera or launch Tether. For iCloud-synchronized source folders, use the output-directory option in the [detailed guide](experiments/connection-guardian/README.md) to avoid file-provider metadata affecting strict app signatures.

The earlier `.command` tools remain available as source. The current Guardian release supplies the DMG and its SHA-256 file. CI validates builds. [CLI build and usage guide](docs/CLI.md) · [Technical evidence and limits](docs/TECHNICAL.md) · [Contributing](CONTRIBUTING.md) · [Bug reports](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml)

## Support development

Optional Alipay support helps further compatibility work and testing.

<img src="assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">

## License

Original project code and documentation: [MIT](LICENSE), © 2026 Eason Zhang / easonzhangbin. The included app icon is an original generated asset. Panasonic LUMIX Tether, its artwork and Qt remain third-party software and are not distributed here. LUMIX and Panasonic are trademarks of their owners.
