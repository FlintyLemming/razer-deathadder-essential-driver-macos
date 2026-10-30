# DeathAdder Control

Razer DeathAdder Essential（USB `1532:0098`）的 macOS 配置工具。单窗口 SwiftUI 程序，不需要内核扩展或 DriverKit：所有配置都通过 HID 特性报告完成。

项目地址：<https://github.com/FlintyLemming/razer-deathadder-essential-driver-macos>，觉得好用欢迎点个 ⭐ Star。

## 功能

- 设备信息：固件版本、序列号、设备模式（处于 Driver 模式时可一键切回 Normal，板载映射才生效）
- DPI：200–6400，步进 100；5 个预设档位一键切换
- 回报率：125 / 250 / 500 / 1000 Hz
- 按键映射（写入鼠标板载存储）：7 个按钮都可以设为鼠标按键、键盘按键（可带修饰键，支持录制），或者禁用；可以一键恢复出厂映射
- 插拔自动重连；高级区里有调试命令，可以手动发送原始命令

## 目录

```
DeathAdderControl.xcodeproj   由 project.yml 生成（XcodeGen）
project.yml                   工程配置：签名团队、Bundle ID 等
DeathAdderControl/            App：界面、状态模型、自检
Packages/RazerKit/            协议库（本地 Swift Package）
  Sources/RazerKit/           帧格式 / 事务层 / IOKit 传输 / 高层 API / 键码表
  Sources/rzctl/              命令行调试工具
  Tests/RazerKitTests/        离线测试（含真机抓包回放）
```

## 构建

用 Xcode 打开 `DeathAdderControl.xcodeproj`，选 `DeathAdderControl` scheme 运行即可。也可以用命令行：

```bash
xcodebuild -project DeathAdderControl.xcodeproj -scheme DeathAdderControl -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

修改 `project.yml` 后，运行 `xcodegen` 重新生成工程。签名使用 Personal Team（`AJ9MHAPR4U`），Bundle ID 是 `moe.flinty.DeathAdderControl`。

首次运行时需要在「系统设置 → 隐私与安全性 → 输入监控」里允许 DeathAdder Control，然后重新打开它。因为签名身份是固定的，以后重新构建不需要再授权。

## 真机核对（macOS，2026-10-30）

App 带一个只读自检，写入测试需要显式加 `--write-test`：

```bash
open -W -n "build/DerivedData/Build/Products/Debug/DeathAdder Control.app" --args --self-test /tmp/rz.txt --write-test
```

必须以 app 身份运行才能用上它自己的输入监控授权，所以这里用 `open` 启动，而不是直接执行二进制。

## 与协议文档的出入（macOS 实测）

- **写缓冲区是 90 字节，不带报告 ID**。不要做「90 字节不行就改 91 字节」的自动回退：错位的 91 字节帧会让固件之后一直返回 status 0（new），不再处理任何命令，只能拔插鼠标恢复。
- **读缓冲区也按 90 字节读**。按 91 字节读时，macOS 会返回 91 字节，但内容开头没有报告 ID，也拿不到处理后的应答。
- **DPI 档位表每档 7 字节** `[stageNo, xHi, xLo, yHi, yLo, 0, 0]`，3 + 5×7 = 38，文档 §6.3 写的 6 字节有误。
- 设备通常在 1–2 ms 内就处理完命令。

## 已知限制

- 多媒体键（mode 10）的编码尚未逆向，没有放进界面。需要音量键的话，可以用键盘页的「静音 / 音量 + / 音量 −」（在「系统」分组里）。
- 灯光、DPI 档位表的写入、去抖时间的写入尚未验证，没有实现。
