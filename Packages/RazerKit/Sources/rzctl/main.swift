import Foundation
import RazerKit

// 命令行调试工具：rzctl list | info | buttons | defaults | raw <class> <id> <size> [bytes...]

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func parseByte(_ s: String) -> UInt8? {
    s.lowercased().hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let monitor = DeathAdderMonitor()

guard let verb = args.first else {
    fail("用法: rzctl list | info | buttons | defaults | raw <class> <id> <size> [bytes...]")
}

if verb == "list" {
    let lines = monitor.describeCollections()
    if lines.isEmpty { fail("未找到 1532:0098") }
    lines.forEach { print($0) }
    exit(0)
}

guard let device = monitor.controlDevice() else { fail("未找到特性报告 ≥ 90 字节的集合") }
let mouse: DeathAdder
do {
    mouse = try DeathAdder(device: device)
} catch {
    fail(error.localizedDescription)
}

do {
    switch verb {
    case "info":
        let info = try mouse.info()
        print("固件      \(info.firmware)")
        print("序列号    \(info.serial)")
        print("模式      \(info.modeName) (\(info.mode))")
        print("轮询率    \(try mouse.pollingRate().hertz) Hz")
        print("DPI       \(try mouse.dpi())")
        let stages = try mouse.dpiStages()
        print("DPI 档位  \(stages.values.map(String.init).joined(separator: " / "))，当前第 \(stages.active) 档")
        print("去抖      \(hex(try mouse.debounceTime()))")
    case "buttons", "defaults":
        let layer: AssignmentLayer = verb == "buttons" ? .current : .factoryDefault
        let map = try mouse.buttonAssignments(layer: layer)
        for id in try mouse.buttonIDs() {
            print(String(format: "0x%02X  %-12@  %@", id, PhysicalButton.name(id), map[id]?.displayName ?? "-"))
        }
    case "raw":
        guard args.count >= 4,
              let cls = parseByte(args[1]), let id = parseByte(args[2]), let size = parseByte(args[3]) else {
            fail("用法: rzctl raw <class> <id> <size> [bytes...]")
        }
        let bytes = args.dropFirst(4).map { s -> UInt8 in
            guard let b = parseByte(s) else { fail("无法解析字节: \(s)") }
            return b
        }
        let reply = try mouse.link.transact(RazerCommand(size, cls, id), bytes)
        print("status \(reply.status?.description ?? "\(reply.statusByte)")")
        print(hex(reply.arguments))
    default:
        fail("未知命令 \(verb)")
    }
} catch {
    fail(error.localizedDescription)
}
