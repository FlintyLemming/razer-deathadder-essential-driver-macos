import Foundation

/// 修饰键位图（Synapse 原文）。
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = KeyModifiers(rawValue: 0x01)
    public static let leftShift = KeyModifiers(rawValue: 0x02)
    public static let leftOption = KeyModifiers(rawValue: 0x04)
    public static let leftCommand = KeyModifiers(rawValue: 0x08)
    public static let rightControl = KeyModifiers(rawValue: 0x10)
    public static let rightShift = KeyModifiers(rawValue: 0x20)
    public static let rightOption = KeyModifiers(rawValue: 0x40)
    public static let rightCommand = KeyModifiers(rawValue: 0x80)

    /// 按 macOS 习惯的顺序 ⌃ ⌥ ⇧ ⌘ 给出名称。
    public var names: [String] {
        let order: [(KeyModifiers, String)] = [
            (.leftControl, "Control"), (.rightControl, "右 Control"),
            (.leftOption, "Option"), (.rightOption, "右 Option"),
            (.leftShift, "Shift"), (.rightShift, "右 Shift"),
            (.leftCommand, "Command"), (.rightCommand, "右 Command"),
        ]
        return order.filter { contains($0.0) }.map(\.1)
    }
}

/// 映射记录 `[mode, dataSize, data...]` 的解释（文档 §7.2–7.5）。
public enum ButtonAction: Hashable, Sendable {
    case off
    /// mode 1：输出鼠标按钮（附录 A.2 编号）
    case mouseButton(UInt8)
    /// mode 2：输出键盘按键，HID Keyboard 用途码 + 修饰键
    case key(modifiers: KeyModifiers, usage: UInt8)
    /// 其它未解析的记录，原样保留
    case raw(mode: UInt8, data: [UInt8])

    public enum Mode: UInt8 {
        case off = 0, buttonCode = 1, keyCode = 2, mediaKeys = 10
    }

    /// `record` 为记录本体 R0..R6（mode 起始）。
    public init(record: [UInt8]) {
        guard let mode = record.first else { self = .off; return }
        let size = record.count > 1 ? Int(record[1]) : 0
        let data = Array(record.dropFirst(2).prefix(size))
        switch (mode, data.count) {
        case (0, _):
            self = .off
        case (1, 1):
            self = .mouseButton(data[0])
        case (2, 2):
            self = .key(modifiers: KeyModifiers(rawValue: data[0]), usage: data[1])
        default:
            self = .raw(mode: mode, data: data)
        }
    }

    /// 写入用的 `[mode, dataSize, data...]`。KeyCode 必须 size=2，size=1 会被存下但不执行。
    public var record: [UInt8] {
        switch self {
        case .off: [0, 0]
        case .mouseButton(let b): [1, 1, b]
        case .key(let mods, let usage): [2, 2, mods.rawValue, usage]
        case .raw(let mode, let data): [mode, UInt8(data.count)] + data
        }
    }

    public var displayName: String {
        switch self {
        case .off:
            return "禁用"
        case .mouseButton(let b):
            return MouseButtonCode.name(b)
        case .key(let mods, let usage):
            return (mods.names + [HIDKeyboard.name(usage)]).joined(separator: " + ")
        case .raw(let mode, let data):
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            return "未知 mode \(mode)  [\(hex)]"
        }
    }
}

/// mode 1 的 data 字节（附录 A.2）。
public enum MouseButtonCode {
    /// 本鼠标上可以放心使用的输出按钮。
    public static let selectable: [UInt8] = [1, 2, 3, 4, 5, 9, 10]

    public static func name(_ code: UInt8) -> String {
        switch code {
        case 1: "鼠标左键"
        case 2: "鼠标右键"
        case 3: "鼠标中键"
        case 4: "鼠标按钮 4（后退）"
        case 5: "鼠标按钮 5（前进）"
        case 9: "滚轮上滚"
        case 10: "滚轮下滚"
        default: "鼠标按钮 \(code)"
        }
    }
}

/// 鼠标上的物理按钮（`GET_BUTTON_ID_LIST` 实测 01 02 03 04 05 09 0A）。
public enum PhysicalButton {
    public static func name(_ id: UInt8) -> String {
        switch id {
        case 1: "左键"
        case 2: "右键"
        case 3: "中键（滚轮按下）"
        case 4: "侧键 · 靠下"
        case 5: "侧键 · 靠上"
        case 9: "滚轮上滚"
        case 10: "滚轮下滚"
        default: "按钮 \(id)"
        }
    }
}
