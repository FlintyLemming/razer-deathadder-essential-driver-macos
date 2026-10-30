import Foundation
import IOKit.hid

public enum DeviceMode: UInt8, CaseIterable, Sendable {
    case normal = 0, bootloader = 1, testing = 2, driver = 3, download = 4,
         pairing = 5, standby = 6, rfTest = 8, retail = 9

    public var name: String {
        switch self {
        case .normal: "Normal"
        case .bootloader: "Bootloader"
        case .testing: "Testing"
        case .driver: "Driver"
        case .download: "Download"
        case .pairing: "Pairing"
        case .standby: "Standby"
        case .rfTest: "RF Test"
        case .retail: "Retail"
        }
    }
}

/// 轮询率码表：1000→1, 500→2, 333→3, 250→4, 200→5, 125→8, 100→10。
public struct PollingRate: Hashable, Sendable, Identifiable {
    public let code: UInt8
    public var id: UInt8 { code }
    public var hertz: Int { code == 3 ? 333 : 1000 / max(Int(code), 1) }

    public init(code: UInt8) { self.code = code }

    public static let common: [PollingRate] = [1, 2, 4, 8].map(PollingRate.init(code:))
}

public struct DPIStages: Equatable, Sendable {
    /// 1 起始的当前档位号
    public var active: Int
    /// 各档位的 DPI（X=Y）
    public var values: [Int]
}

public struct DeviceInfo: Equatable, Sendable {
    public var firmware: String
    public var serial: String
    public var mode: UInt8

    public var modeName: String { DeviceMode(rawValue: mode)?.name ?? "未知(\(mode))" }
}

/// 映射表的层（`GET_BUTTON_ASSIGNMENT_LIST` 第 2 个参数）。
public enum AssignmentLayer: UInt8, Sendable {
    case current = 0
    case factoryDefault = 1
}

/// DeathAdder Essential 的高层接口。所有方法都是同步阻塞的，应在同一个后台串行队列上调用。
public final class DeathAdder: @unchecked Sendable {
    public static let dpiRange = 200...6400
    public static let dpiStep = 100

    public let link: RazerLink
    private let transport: IOHIDFeatureTransport?

    /// 按键映射命令实测使用 profile 1；DPI 系列命令实测使用 profile 0。
    private let buttonProfile: UInt8 = 1
    private let dpiProfile: UInt8 = 0

    public init(link: RazerLink) {
        self.link = link
        self.transport = nil
    }

    public init(device: IOHIDDevice) throws {
        let transport = IOHIDFeatureTransport(device: device)
        try transport.open()
        self.transport = transport
        self.link = RazerLink(transport: transport)
    }

    public func close() {
        transport?.close()
    }

    // MARK: 设备信息

    public func firmwareVersion() throws -> String {
        let a = try link.execute(.getFirmwareVersion)
        return String(format: "%d.%02d", a[0], a[1])
    }

    public func serialNumber() throws -> String {
        let a = try link.execute(.getSerialNumber)
        let bytes = a.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public func deviceMode() throws -> UInt8 {
        try link.execute(.getDeviceMode)[0]
    }

    /// normal(0) 下固件才执行板载映射表；driver(3) 是交给主机软件重映射。
    public func setDeviceMode(_ mode: DeviceMode) throws {
        try link.execute(.setDeviceMode, [mode.rawValue, 0])
    }

    public func info() throws -> DeviceInfo {
        DeviceInfo(firmware: try firmwareVersion(), serial: try serialNumber(), mode: try deviceMode())
    }

    public func debounceTime() throws -> [UInt8] {
        try link.execute(.getDebounceTime)
    }

    // MARK: 轮询率

    public func pollingRate() throws -> PollingRate {
        PollingRate(code: try link.execute(.getPollingPeriod)[0])
    }

    public func setPollingRate(_ rate: PollingRate) throws {
        try link.execute(.setPollingPeriod, [rate.code])
    }

    // MARK: DPI

    public func dpi() throws -> Int {
        let a = try link.execute(.getActiveDPI, [dpiProfile])
        return Int(a[1]) << 8 | Int(a[2])
    }

    /// 本设备不支持 X/Y 独立，两轴写同一个值。
    public func setDPI(_ value: Int) throws {
        let clamped = min(max(value, Self.dpiRange.lowerBound), Self.dpiRange.upperBound)
        let v = clamped / Self.dpiStep * Self.dpiStep
        let hi = UInt8(v >> 8), lo = UInt8(v & 0xFF)
        try link.execute(.setActiveDPI, [dpiProfile, hi, lo, hi, lo, 0, 0])
    }

    /// `[profile, activeStage, count]` + 每档 7 字节 `[stageNo, xHi, xLo, yHi, yLo, 0, 0]`
    /// （真机实测 3 + 5×7 = 38；协议文档 §6.3 写的 6 字节是错的）。
    public func dpiStages() throws -> DPIStages {
        let a = try link.execute(.getDPIStages, [dpiProfile])
        let count = min(Int(a[2]), (a.count - 3) / 7)
        let values = (0..<count).map { i -> Int in
            let base = 3 + i * 7
            return Int(a[base + 1]) << 8 | Int(a[base + 2])
        }
        return DPIStages(active: Int(a[1]), values: values)
    }

    /// `stage` 为 1 起始的档位号；切档会同时改变当前 DPI。
    public func setActiveDPIStage(_ stage: Int) throws {
        try link.execute(.setActiveDPIStage, [dpiProfile, UInt8(stage)])
    }

    // MARK: 按键映射

    public func buttonIDs() throws -> [UInt8] {
        let a = try link.execute(.getButtonIDList)
        let count = min(Int(a[0]), a.count - 1)
        return Array(a[1...count])
    }

    /// `[classId, layer, idOffset]` + 每条 8 字节 `[buttonId, R0..R6]`。
    public func buttonAssignments(layer: AssignmentLayer = .current) throws -> [UInt8: ButtonAction] {
        let a = try link.execute(.getButtonAssignmentList, [buttonProfile, layer.rawValue, 0])
        var result: [UInt8: ButtonAction] = [:]
        var offset = 3
        while offset + 8 <= a.count, a[offset] != 0 {
            result[a[offset]] = ButtonAction(record: Array(a[(offset + 1)..<(offset + 8)]))
            offset += 8
        }
        return result
    }

    /// `[profile, buttonId, hyperShift, R0..R6]`。
    public func buttonAssignment(_ button: UInt8) throws -> ButtonAction {
        let a = try link.execute(.getButtonAssignment, [buttonProfile, button])
        return ButtonAction(record: Array(a[3..<10]))
    }

    /// 写入并读回核对。注意设备只存不校验，读回一致不代表固件会执行。
    public func setButtonAssignment(_ button: UInt8, _ action: ButtonAction) throws {
        try link.execute(.setButtonAssignment, [buttonProfile, button, 0] + action.record)
        let readBack = try buttonAssignment(button)
        guard readBack == action else {
            throw RazerError.verifyFailed("\(PhysicalButton.name(button))：期望 \(action.displayName)，读回 \(readBack.displayName)")
        }
    }

    /// 读出厂默认层，逐条写回。
    @discardableResult
    public func restoreDefaultAssignments() throws -> [UInt8: ButtonAction] {
        let defaults = try buttonAssignments(layer: .factoryDefault)
        for (button, action) in defaults.sorted(by: { $0.key < $1.key }) {
            try setButtonAssignment(button, action)
        }
        return defaults
    }
}
