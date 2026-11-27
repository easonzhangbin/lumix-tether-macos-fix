# S1H Native Tether

[简体中文](README.zh-CN.md)

An independent USB tethering app for the Panasonic **DC-S1H** on Apple silicon Macs. The AppKit interface uses its own native USB/PTP worker and runs independently of LUMIX Tether.

[Download 0.1.6 for Apple silicon](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.6/S1H-Native-Tether-0.1.6-arm64.zip) · [Release notes and checksums](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.6)

## Connect and shoot

1. Extract the ZIP and open **S1H Native Tether.app**. The app has an ad-hoc signature and is distributed without Apple notarization. If macOS blocks it, verify the source and archive checksum first. [Apple’s safe-opening guide](https://support.apple.com/en-us/102445)
2. Quit other camera clients such as LUMIX Tether, Image Capture, and Preview. Connect the S1H with a USB data cable, select **PC(Tether)** on the camera, and click **Connect**.
3. Choose a save folder or use `~/Pictures/S1H Tether`. **Capture and Save** defaults to **Save to Mac Only**. Photos taken with the physical shutter follow the camera’s active tether storage target.
4. Wait for transfers to finish, then click **Stop** before unplugging the camera or switching camera apps.

If **Recover** appears, the camera has reported an existing PTP session. Wait until the camera is idle and the card-access light is off, then confirm recovery to start a fresh session. Session logs and the latest preview frame are stored locally under `~/Library/Caches/S1H Native Preview/experimental/`.

## Features and validation

- Live view reached **1600 × 1072** on one DC-S1H and Apple silicon Mac running macOS 27.0.1. Available aperture, shutter speed, ISO, and white balance settings follow the camera’s reported options.
- RAW capture to Mac and a physical-shutter **12000 × 8000 RW2** transfer were verified. Start High Resolution Mode on the camera under **Photo → Image Quality 1 → High Resolution Mode → Start**. Consecutive XL transfers and Card + Mac still need hardware validation.
- 0.1.6 shows ISO **AUTO** and White Set **1–4** by name, reuses the Guardian app icon, and adds a Border Beam to **Connect/Recover**. The beam becomes static when macOS Reduce Motion is enabled.

The build targets macOS 12 and later on Apple silicon. Hardware validation covers the setup above. Other macOS versions, camera models, and long shooting sessions remain unverified.

## Build from source

With the Xcode Command Line Tools installed on an Apple silicon Mac, run `./build.sh` from this directory. It compiles the worker, runs offline checks, then signs and verifies `build/S1H Native Tether.app`.

If a synced folder adds Finder metadata that interferes with signing, build to a local folder with `NATIVE_TETHER_OUTPUT_DIR="$HOME/Downloads/S1H Native Tether Build" ./build.sh`.
