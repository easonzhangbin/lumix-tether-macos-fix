# LUMIX Tether USB Fix for macOS

[简体中文](README.zh-CN.md)

A small Apple Silicon USB recovery helper, started by a `.command` script, that clears pending PTP responses before opening Panasonic LUMIX Tether 2.12. It restored USB tethering and live view on one tested Panasonic DC-S1H setup, over both USB 2 and USB 3.

This is an independent community project. It is not affiliated with Panasonic or Apple.

## What is included

- **Restore S1H Connection.command** and **恢复S1H连接.command**, equivalent script entry points.
- A native IOUSBHost recovery helper at `bin/s1h_iousbhost_probe`.
- Automatic selection of Tether's existing interface language, with a command-line override.

The release ZIP extracts to a folder containing the scripts and `bin/`. Keep them together. **It does not contain LUMIX Tether, Panasonic's installer or icons, or Qt libraries.** Install the official application separately.

## Tested configuration

| Component | Verified setup |
| --- | --- |
| Camera | Panasonic DC-S1H |
| Mac | MacBookPro18,2, Apple M1 Max |
| macOS | 27.0.1, build 26A434 |
| Tether | 2.12, build 2.12.0.5 |
| USB 2 | 480 Mbps negotiated link; Tether live view restored |
| USB 3 | 5 Gbps negotiated link; Tether live view restored |

These are negotiated USB link speeds, not measured file-transfer throughput. Long-duration stability has not been measured.

The helper is built for **arm64 / Apple Silicon**, with a macOS 12 deployment target. The actual hardware test above was on macOS 27.0.1; the deployment target does not establish compatibility with every intervening macOS release. Intel Macs are not supported by this release.

**DC-S1R, DC-S1 and other LUMIX cameras are untested.** Some bodies may share USB identifiers, but that does not establish that this recovery procedure is appropriate for them.

## Getting started

1. Download and install **LUMIX Tether 2.12** from [Panasonic's official download page](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html).
2. Download this project's ZIP from [Releases](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases) and extract the folder.
3. Close Tether and other applications that are accessing the camera. Connect the S1H with a data-capable USB cable and choose **PC(Tether)** on the camera.
4. Double-click **Restore S1H Connection.command** or **恢复S1H连接.command**. It runs in Terminal and looks for official Tether 2.12 in `/Applications` and `~/Applications`.
5. After recovery and a successful fresh-session check, the script opens Tether. Select the camera, click **Start**, then **LV** for live view.

Run the fix before Tether when a connection is stuck, or after reconnecting the camera. The tool does not terminate another camera application to take over its connection.

If macOS asks Tether or Terminal for access to the camera's removable volume, or asks permission to connect a USB accessory, allow the access needed by the application you are using. If recovery succeeds but Tether cannot connect, check **System Settings → Privacy & Security → Files and Folders** for the actual Tether 2.12 application. System permission may still be required after a successful protocol recovery.

For a nonstandard installation path, run the script from the extracted release folder:

```sh
./"Restore S1H Connection.command" --tether-app "/path/to/LUMIX Tether.app"
```

The selected app must be official Tether 2.12.

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

The helper uses Apple's native IOUSBHost API to consume complete pending containers. It treats a zero-byte timeout **at a container boundary** as an empty queue, then verifies a fresh `OpenSession` → `GetDeviceInfo` → `CloseSession` exchange. Only after that check does the script open Tether.

This explains the recovery that was observed. It does **not** prove which component created the pending transaction, or establish a universal cause for LUMIX connection failures on newer macOS versions. See [the technical notes](docs/TECHNICAL.md) for the evidence and limits.

The helper does not take pictures, delete images, update firmware, or log image payloads or camera serial numbers.

## Troubleshooting

**Tether 2.11 opens or an old shortcut crashes.** Confirm the version of the application being opened. An old Dock item or shortcut can still point to 2.11. This script requires official Tether 2.12 and rejects 2.11; a crash from the older app is not evidence that the 2.12 recovery failed.

**The camera or interface is busy.** Close the application currently using it, disconnect and reconnect the cable, choose PC(Tether), then try again. The fix does not forcibly stop other camera clients.

**No camera is found.** Check power, the data cable, the USB mode and any macOS accessory-connection prompt. This tool cannot repair a missing physical USB connection.

**A different camera is not working.** Please report the exact model as an untested configuration. Do not assume support from a shared USB ID.

For a report, use the [bug template](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues/new?template=bug_report.yml). Share only the relevant status and error lines. Do not post a camera serial number or an unredacted crash report.

## Building from source

The default public build needs Xcode Command Line Tools on an Apple Silicon Mac. It uses system frameworks and does not require Homebrew, Python or third-party libraries.

From the repository root:

```sh
./scripts/build.sh
./scripts/self-check.sh
./scripts/package.sh
```

The build creates `dist/LUMIX Tether USB Fix/`, containing the two `.command` files and `bin/s1h_iousbhost_probe`. Packaging creates a public arm64 ZIP and its SHA-256 checksum in `dist/`. The self-check validates the artifact without opening the camera or running Tether. Use each script's `--help` option for its full interface.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Reports from additional cameras and macOS versions are welcome, with clear separation between a successful handshake and verified Tether live view.

## Support development

If this tool helps your work, you can support development through Alipay. Support is entirely optional.

<img src="assets/alipay-donate.jpg" alt="Alipay donation QR code" width="240">

## License and third-party software

This project's original scripts, recovery helper and documentation are available under the [MIT License](LICENSE), copyright © 2026 Eason Zhang / easonzhangbin.

The MIT license does not apply to Panasonic LUMIX Tether, Panasonic artwork, Qt or other third-party components. Those remain subject to their respective licenses. LUMIX and Panasonic are trademarks of their respective owners.
