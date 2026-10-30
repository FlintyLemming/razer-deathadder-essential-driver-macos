# DeathAdder Control

[中文](README.md) | **English**

A macOS configuration tool for the Razer DeathAdder Essential (USB `1532:0098`). It is a single-window SwiftUI app that needs no kernel extension or DriverKit driver: everything is configured through HID feature reports.

Repository: <https://github.com/FlintyLemming/razer-deathadder-essential-driver-macos>. If you find it useful, a ⭐ Star is appreciated.

## Features

- Device info: firmware version, serial number, device mode (if the mouse is in Driver mode, one click switches it back to Normal so the on-board mapping takes effect)
- DPI: 200–6400 in steps of 100, with 5 one-click presets
- Polling rate: 125 / 250 / 500 / 1000 Hz
- Button remapping (stored in the mouse's on-board memory): each of the 7 buttons can be set to a mouse button, a keyboard key (with modifiers, recordable), or disabled; factory mapping can be restored with one click
- Automatic reconnect on replug; the Advanced section has a debug console for sending raw commands

## Installation

Download the latest `.dmg` from [Releases](https://github.com/FlintyLemming/razer-deathadder-essential-driver-macos/releases), open it and drag DeathAdder Control into the Applications folder. Runs on Apple silicon and Intel, macOS 14 or later.

The app is not signed with a Developer ID or notarized, so macOS will say it is "damaged" or "from an unidentified developer". Remove the quarantine attribute in Terminal, then open it:

```bash
xattr -d com.apple.quarantine "/Applications/DeathAdder Control.app"
```

On first launch, allow DeathAdder Control under System Settings → Privacy & Security → Input Monitoring, then reopen it. Release builds are ad-hoc signed, so after updating to a new version you may need to grant the permission again (remove the old entry from the list first).

## Layout

```
DeathAdderControl.xcodeproj   Generated from project.yml (XcodeGen)
project.yml                   Project config: signing team, bundle ID, etc.
DeathAdderControl/            App: UI, state model, self-test
scripts/build-dmg.sh          Builds the release .dmg (also used by CI)
Packages/RazerKit/            Protocol library (local Swift package)
  Sources/RazerKit/           Frame format / transaction layer / IOKit transport / high-level API / key code tables
  Sources/rzctl/              Command-line debugging tool
  Tests/RazerKitTests/        Offline tests (including replay of captures from real hardware)
```

## Building

Open `DeathAdderControl.xcodeproj` in Xcode and run the `DeathAdderControl` scheme. Or from the command line:

```bash
xcodebuild -project DeathAdderControl.xcodeproj -scheme DeathAdderControl -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

To package a release `.dmg` (universal, ad-hoc signed, output in `build/dist/`):

```bash
scripts/build-dmg.sh 1.0
```

Pushing a `v*` tag (e.g. `git tag v1.0 && git push origin v1.0`) triggers GitHub Actions to build the `.dmg` and publish a Release.

After editing `project.yml`, run `xcodegen` to regenerate the project. Development builds are signed with a Personal Team (`AJ9MHAPR4U`); the bundle ID is `moe.flinty.DeathAdderControl`.

On first launch, allow DeathAdder Control under System Settings → Privacy & Security → Input Monitoring, then reopen it. Because the signing identity is fixed, later rebuilds don't need to be re-authorized.

## Hardware verification (macOS, 2026-10-30)

The app includes a read-only self-test; the write test must be enabled explicitly with `--write-test`:

```bash
open -W -n "build/DerivedData/Build/Products/Debug/DeathAdder Control.app" --args --self-test /tmp/rz.txt --write-test
```

It has to run as the app to use the app's own Input Monitoring permission, which is why it is launched with `open` instead of running the binary directly.

## Differences from the protocol docs (observed on macOS)

- **The write buffer is 90 bytes, without a report ID.** Do not add an automatic "if 90 bytes fails, retry with 91" fallback: a misaligned 91-byte frame makes the firmware return status 0 (new) from then on and stop processing commands until the mouse is replugged.
- **Reads are also 90 bytes.** When reading 91 bytes, macOS returns 91 bytes, but without a leading report ID and without the processed response.
- **Each DPI stage table entry is 7 bytes** `[stageNo, xHi, xLo, yHi, yLo, 0, 0]`, so 3 + 5×7 = 38; the 6 bytes stated in §6.3 of the docs are wrong.
- The device usually finishes processing a command within 1–2 ms.

## Known limitations

- The encoding for multimedia keys (mode 10) has not been reverse-engineered yet, so it is not in the UI. For volume keys, use Mute / Volume Up / Volume Down from the keyboard page (under the 「系统」 (System) group; the UI is currently in Chinese).
- Lighting, writing the DPI stage table, and writing the debounce time have not been verified and are not implemented.
