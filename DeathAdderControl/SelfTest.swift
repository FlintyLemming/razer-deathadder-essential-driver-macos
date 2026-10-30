import Foundation
import RazerKit

/// `--self-test <文件> [--raw "class id size [参数...]"]... [--write-test]`
///
/// 不开窗口，把设备状态写进文件后退出。以 app 身份运行才能用上“输入监控”授权，
/// 所以真机核对都走这里，而不是命令行的 rzctl。
enum SelfTest {
    static func run(arguments: [String]) -> String {
        var lines = ["access: \(InputMonitoringAccess.state)"]
        let monitor = DeathAdderMonitor()
        lines += monitor.describeCollections()
        guard let device = monitor.controlDevice() else {
            return (lines + ["control device: not found"]).joined(separator: "\n")
        }

        let mouse: DeathAdder
        do {
            mouse = try DeathAdder(device: device)
        } catch {
            return (lines + ["open: \(error.localizedDescription)"]).joined(separator: "\n")
        }
        defer { mouse.close() }

        func step(_ label: String, _ body: () throws -> String) {
            do { lines.append("\(label): \(try body())") } catch { lines.append("\(label): ERROR \(error.localizedDescription)") }
        }

        step("firmware") { try mouse.firmwareVersion() }
        step("serial") { try mouse.serialNumber() }
        step("mode") { try DeviceMode(rawValue: mouse.deviceMode())?.name ?? "?" }
        step("polling") { "\(try mouse.pollingRate().hertz) Hz" }
        step("dpi") { "\(try mouse.dpi())" }
        step("stages") { "\(try mouse.dpiStages())" }
        step("debounce") { hex(try mouse.debounceTime()) }
        step("button ids") { hex(try mouse.buttonIDs()) }
        step("buttons") {
            let current = try mouse.buttonAssignments()
            let defaults = try mouse.buttonAssignments(layer: .factoryDefault)
            return current.keys.sorted().map { id in
                "\n  \(id) \(PhysicalButton.name(id)): \(current[id]!.displayName)  [default: \(defaults[id]?.displayName ?? "-")]"
            }.joined()
        }
        step("single btn4") { try mouse.buttonAssignment(4).displayName }

        var i = 0
        while i < arguments.count {
            if arguments[i] == "--raw", i + 1 < arguments.count {
                let line = arguments[i + 1]
                step("raw \(line)") {
                    let b = line.split(separator: " ").compactMap { s -> UInt8? in
                        s.hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
                    }
                    let reply = try mouse.link.transact(RazerCommand(b[2], b[0], b[1]), Array(b.dropFirst(3)))
                    return "\(reply.status?.description ?? "\(reply.statusByte)")  \(hex(reply.arguments))"
                }
                i += 1
            }
            i += 1
        }

        if arguments.contains("--write-test") {
            // 每项都写一个不同的值、读回、再写回原值。
            step("write dpi") {
                let original = try mouse.dpi()
                let probe = original == 800 ? 1200 : 800
                try mouse.setDPI(probe)
                let got = try mouse.dpi()
                try mouse.setDPI(original)
                return "\(original) → \(got) → \(try mouse.dpi())"
            }
            step("write polling") {
                let original = try mouse.pollingRate()
                let probe = PollingRate(code: original.code == 2 ? 1 : 2)
                try mouse.setPollingRate(probe)
                let got = try mouse.pollingRate()
                try mouse.setPollingRate(original)
                return "\(original.hertz) → \(got.hertz) → \(try mouse.pollingRate().hertz)"
            }
            step("write stage") {
                let original = try mouse.dpiStages()
                let originalDPI = try mouse.dpi()
                let probe = original.active == 1 ? 2 : 1
                try mouse.setActiveDPIStage(probe)
                let got = (try mouse.dpiStages().active, try mouse.dpi())
                try mouse.setActiveDPIStage(original.active)
                try mouse.setDPI(originalDPI)
                return "\(original.active) → \(got) → \(try mouse.dpiStages().active)/\(try mouse.dpi())"
            }
            step("write button 10") {
                let original = try mouse.buttonAssignment(10)
                try mouse.setButtonAssignment(10, .off)
                let got = try mouse.buttonAssignment(10)
                try mouse.setButtonAssignment(10, original)
                return "\(original.displayName) → \(got.displayName) → \(try mouse.buttonAssignment(10).displayName)"
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        var b = bytes
        while b.last == 0 { b.removeLast() }
        return b.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
