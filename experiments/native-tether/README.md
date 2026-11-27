# S1H Native Tether

[简体中文](README.zh-CN.md)

An independent USB tethering app for still photography with the Panasonic **DC-S1H** on Apple silicon Macs. It grew out of a connection problem with official LUMIX Tether on our newer macOS test setup. Its AppKit interface and USB/PTP worker let us keep using the camera for studio work and bring originals directly into a Mac folder. [Panasonic’s published compatibility and downloads](https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html)

[Download 0.1.15 for Apple silicon (PKG)](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/download/native-tether-v0.1.15/S1H-Native-Tether-0.1.15-arm64.pkg) · [Release notes and SHA-256](https://github.com/easonzhangbin/lumix-tether-macos-fix/releases/tag/native-tether-v0.1.15)

## Install and shoot

1. Verify the PKG using the matching SHA-256 file from the release page. Open the PKG in Installer, then open **S1H Native Tether.app** in **Applications**. The installer is unsigned and the app is ad-hoc signed. This release is distributed without Apple notarization. If macOS blocks it, check the source and checksum before deciding whether to open it. [Apple’s safe-opening guide](https://support.apple.com/en-us/102445)
2. Quit other camera clients such as LUMIX Tether, Image Capture, and Preview. Connect the S1H with a USB data cable, select **PC(Tether)** on the camera, and click **Connect**. Native Tether runs on its own.
3. Choose a save folder or use `~/Pictures/S1H Tether`. **Capture and Save** defaults to **Save to Mac Only**. Photos taken with the physical shutter follow the camera’s active tether storage target.
4. Wait for transfers to finish, then click **Stop** before unplugging the camera or switching camera apps.

## What 0.1.15 does

- **Live view and camera settings** include Fit Window, 100% Actual Pixels, draggable 200% Zoom, a composition grid, and the camera’s available aperture, shutter speed, ISO, and white balance options.
- **Remote Focus** provides one step per click with **Focus Forward** and **Focus Back**. Set the camera to MF and use an electronically controlled lens. If both buttons are inactive, refresh the camera settings after selecting MF.
- **Original-file transfer** accepts software and physical shutter captures. The app shows transfer progress, checks RAW file integrity before finalizing, and retains an incomplete download as a `.part` file. **Photo File Naming…** lets you save originals with a prefix and sequential number such as `Sample_0001.RW2`.
- **Camera Shutter Storage** shows the camera’s active tether destination and card status. The app verifies target changes through readback. The software shutter has a separate, temporary destination.
- **Status and diagnostics** include USB negotiated link rate and, when supported, battery percentage via **Refresh Camera Settings**. **View & Tools → Camera Capability Report** shows the PTP operations, events, and properties the camera advertises. The report omits the serial number.

For an XL RAW, choose **Photo → Image Quality 1 → High Resolution Mode → Start** on the camera. USB link rates describe the negotiated connection. File transfer performance varies with the camera, cable, and Mac.

## Hardware checks and scope

The build targets **macOS 12 or later on Apple silicon**. The tested pairing was a **DC-S1H and Apple M1 Max** on **macOS 27.0.1 (26A434)**. Tests reached **1600 × 1072** live view, verified lens movement in either MF direction, and saved and fully decoded consecutive **12000 × 8000 RW2** images from one session. Other models, other macOS versions, and long shoots need more hardware coverage. Card + Mac requires a card recognized by the camera and needs further hardware validation.

## Recover a connection

If **Recover** appears, the camera has reported an existing PTP session. Wait until the camera is idle and the card-access light is off, then confirm recovery. The app pauses automatic reconnect when a capture or previous session needs review.

If macOS sees the S1H but the app cannot open its interface, the status line shows a confirmed exclusive owner in red. For a named camera or import app, quit it normally and try connecting again.

If the current user's macOS camera service `ptpcamerad` holds the interface, choose **View & Tools → Release System Camera Interface…** to verify ownership. Wait until the camera is idle, the card-access light is off, and all imports and transfers have finished. Choose **Release and Connect** to request that the service quit. If the wait expires, a force quit is permitted only while the same verified process still owns the same S1H interface. A detected camera or import app, another USB camera, or a change in ownership stops recovery. The app reconnects after it confirms the interface is free.

Session logs and the most recent preview frame are stored locally under `~/Library/Caches/S1H Native Preview/experimental/sessions/`. In a report, include the app version, macOS version, camera model and firmware, and the steps that led to the issue. Share excerpts with private details removed. [GitHub Issues](https://github.com/easonzhangbin/lumix-tether-macos-fix/issues)

## Build from source

With the Xcode Command Line Tools installed on an Apple silicon Mac, run `./build.sh` from this directory. It compiles the worker, runs offline checks, then signs and verifies `build/S1H Native Tether.app`.

If a synced folder adds Finder metadata that interferes with signing, build to a local folder with `NATIVE_TETHER_OUTPUT_DIR="$HOME/Downloads/S1H Native Tether Build" ./build.sh`.
