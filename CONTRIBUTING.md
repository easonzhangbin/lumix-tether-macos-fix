# Contributing

[简体中文说明](#简体中文)

Thanks for helping investigate LUMIX tethering on macOS. Useful contributions include clear hardware reports, reproducible transport traces with private data removed, and small changes that preserve the recovery checks.

## Reporting a problem or a new camera

Use the bug-report issue form. Include:

- The camera model and firmware version, without a serial number.
- The Mac model or chip, macOS version and build number.
- The actual Tether version and build number. Confirm that an old Dock item did not launch 2.11.
- USB connection details, including negotiated speed if available.
- The stage that failed and a short, redacted excerpt of the relevant helper output.
- Whether the full handshake succeeded, whether Tether recognized the camera, and whether live view actually appeared.

Please do not upload complete USB captures, photo payloads or unredacted crash reports. They can contain image data, device identifiers, user names and private paths. Provide a minimal protocol-header excerpt instead.

Reports for DC-S1R, DC-S1 and other cameras are welcome as **untested-model reports**. A shared USB ID is not enough to mark a model as supported. Keep "expected to work," "handshake verified" and "Tether live view verified" distinct.

## Code changes

Keep changes focused and explain the concrete behavior they address. Use native system frameworks for the default public build; it must not require Homebrew, Python or third-party runtime libraries.

Preserve these properties:

- Bound every I/O and cleanup operation.
- Consume complete PTP containers and verify fresh transaction IDs.
- Treat an error or partial-container timeout as a failed drain.
- Do not turn a single leftover OK response into a successful handshake.
- Do not force another camera application to stop or surrender its connection.
- Do not add photo capture, image deletion, firmware updates or payload/serial-number logging to recovery.
- Keep vendor software out of public source and release artifacts.

Describe validation in the pull request. If a change has only been compiled or inspected, say so. Do not imply that a hardware test was performed. Build success on a deployment target does not establish runtime compatibility with that OS.

Use a separately installed official Tether 2.12 app for local testing. The public release is a folder of `.command` scripts and the native helper; keep vendor applications and installer packages out of issues, pull requests and release artifacts.

## License

Contributions to this project's original code and documentation are made under the MIT license in [LICENSE](LICENSE). Do not copy third-party code or assets without preserving the required license and confirming that they may be included.

## 简体中文

欢迎提交清楚的硬件实测、已脱敏的最小协议记录，以及保留恢复校验的小范围改动。

报告请说明相机型号与固件、Mac 芯片或型号、macOS 版本及构建号、实际 Tether 版本、USB 链路情况和失败步骤。请区分“握手成功”“Tether 已识别”和“实时预览已显示”。DC-S1R、DC-S1 等其他机型目前按未验证机型报告，不能只因 USB ID 相同而标为兼容。

不要上传完整 USB 抓包、照片内容、相机序列号或未脱敏的完整崩溃日志。请仅提供相关的协议头、长度、状态与错误行，并去除私人路径和标识。

代码应保留超时上限、完整容器读取、新事务匹配和严格失败处理。恢复流程不应强制结束其他相机软件，也不应拍照、删图、更新固件或记录数据内容。默认公开构建只依赖系统框架，不引入 Homebrew、Python 或第三方运行库。

PR 中请说明实际验证方式；只编译或静态检查时应明确写出，不能暗示已做硬件测试。不要将松下程序、图标、Qt 库或厂商安装包上传到公开仓库、Issue 或 PR。

本项目原创内容的贡献采用 [MIT 许可](LICENSE)。第三方代码和资源必须确认许可，并保留所需声明。公开发布形态为 `.command` 脚本与原生恢复程序的目录包；本地测试请使用单独安装的官方 Tether 2.12。
