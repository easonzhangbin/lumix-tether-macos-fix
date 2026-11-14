# LUMIX Connection Guardian

[简体中文](README.zh-CN.md)

<img src="experiments/connection-guardian/assets/GuardianAppIcon-source-v1.png" alt="LUMIX Connection Guardian app icon" width="120">

**Reconnect your S1H to Mac, and keep shooting with official LUMIX Tether.**

An independent Apple Silicon menu-bar utility that prepares the S1H USB connection, hands it to official Tether 2.12, and watches connection and application lifecycles. Panasonic's application supplies live view, shooting, aperture, shutter, ISO, white balance and original-file saving. Guardian supplies connection recovery and a clear way to finish a session.

[Download Guardian 0.2.2 beta](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.2) · [Source and detailed guide](experiments/connection-guardian/README.md) · [Earlier recovery scripts](docs/CLI.md)

This is a community beta tested on one S1H setup. It is not affiliated with Panasonic or Apple. Official Tether must be installed separately; the download contains this project's own app and helpers only.

## 0.2.2 correction

The pre-recovery check now names other camera clients that must quit normally, including Preview. A detected application is a conservative blocker, not proof that it owns the camera; actual interface ownership is shown separately. All Guardian launch entries check and prepare the connection while Tether is absent. Blocked and unblocked recovery states are logged.

## What it does

| Action | Behavior |
| --- | --- |
| Start Guardian | Check the camera and other clients, prepare a fresh USB/PTP session while Tether is absent, then open official Tether. Starting opts in to guarded recovery of the current user's camera service when checks permit. |
| Observe | Show USB detection, negotiated link speed, Tether process state and a separate shooting-connection status. No new USB recovery starts while Tether is known to be running. Confirm actual preview and capture inside Tether. |
| Pause Recovery | Stop future automatic recovery and leave Tether as it is. |
| End This Shoot | Disable recovery first, then request a normal Tether quit. Keep Guardian in the menu bar without automatically reopening Tether. Finish transfers before using this action. |
| Reconnect | Request normal Tether quit, prepare the connection again and reopen it. A quit timeout enables a separate explicit Force Quit/Force Restart action; it never forces Tether automatically. |
| Diagnose | Keep rotating local event logs for actions, recovery steps, launch requests and process observations, alongside the existing helper diagnostics. |

A physical disconnect may request normal quit of the exact verified Tether instance Guardian launched. Recovery retries are bounded. Unknown ownership or other camera software can block service recovery. Guardian cannot reserve USB globally while allowing Tether to use it, or repair every internal Tether hang.

## Install and use

1. Install **official LUMIX Tether 2.12** from [Panasonic](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html), in `/Applications` or `~/Applications`.
2. Download and extract the [Guardian beta ZIP](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/guardian-v0.2.2). Move **LUMIX Connection Guardian.app** to your Applications folder.
3. Close other camera/import applications. Connect the S1H with a data cable and select **PC(Tether)**.
4. Open Guardian and click **Start Guardian**. In official Tether, select the camera, click **Start**, then **LV**. Confirm preview and take a test photo into your chosen destination.
5. After capture and file transfer finish, click **End This Shoot**. Closing Guardian's status window keeps its menu-bar item available.

Guardian starts idle and does not install a login item or persistent system service. Its UI follows Chinese/English system preferences; official Tether is launched with its existing supported-language option, with English fallback. No vendor resources are replaced.

The app is locally ad-hoc signed and **not Developer ID notarized**. Another Mac may block a downloaded copy. Review its source and origin and follow [Apple's safe-opening instructions](https://support.apple.com/en-us/102445). The tool does not disable system protections. macOS may separately request accessory or removable-volume permission for the app being used.

## Verified, and still unverified

| Item | Observed result |
| --- | --- |
| Hardware | Panasonic DC-S1H; Apple M1 Max, MacBookPro18,2 |
| System / official app | macOS 27.0.1 (26A434); Tether 2.12.0.5 |
| USB | 5 Gbps negotiated USB3; earlier script recovery also worked at 480 Mbps USB2 |
| Actual shooting | After a Guardian recovery handoff, official live view worked and one 6000×4000 RAW was captured and saved: 36,048,384 bytes |
| Camera controls | Aperture, shutter, ISO and color temperature were changed and restored separately in the official UI |
| Session controls | Pause preserved Tether; End closed it normally with no automatic reopen in a short observation |
| Automated checks | 302 passed: 16 USB identity, 43 service-guard, 50 event-log, 193 controller/policy checks; these use pure or fake environments |

Repeated Guardian hot-plug recovery, sleep/wake, long shoots, bursts, other Macs/macOS versions and other bodies remain unverified. **S1R, S1 and other models are not supported by this S1H beta's strict identity path.** arm64 only; the macOS 12 build target is not a claim that every later OS has been tested.

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

The earlier `.command` tools remain available in [v1.0.1](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/v1.0.1); see their [CLI guide](docs/CLI.md). The main branch also includes unreleased CLI 1.0.2 guard corrections. [Technical evidence and limits](docs/TECHNICAL.md), [contributing](CONTRIBUTING.md), and [bug reports](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml).

## Support development

Optional Alipay support helps further compatibility work and testing.

<img src="assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">

## License

Original project code and documentation: [MIT](LICENSE), © 2026 Eason Zhang / easonzhangbin. The included app icon is an original generated asset. Panasonic LUMIX Tether, its artwork and Qt remain third-party software and are not distributed here. LUMIX and Panasonic are trademarks of their owners.
