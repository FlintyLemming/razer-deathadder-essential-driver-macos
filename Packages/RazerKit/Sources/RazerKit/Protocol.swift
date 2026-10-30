import Foundation

/// 一条命令 = [dataSize, class, id]，与 Synapse 命令表的写法一致。
public struct RazerCommand: Hashable, Sendable, CustomStringConvertible {
    public let dataSize: UInt8
    public let commandClass: UInt8
    public let commandID: UInt8

    public init(_ dataSize: UInt8, _ commandClass: UInt8, _ commandID: UInt8) {
        self.dataSize = dataSize
        self.commandClass = commandClass
        self.commandID = commandID
    }

    public var description: String {
        String(format: "[size=%d class=0x%02X id=0x%02X]", dataSize, commandClass, commandID)
    }
}

extension RazerCommand {
    public static let getFirmwareVersion = RazerCommand(2, 0x00, 0x81)
    public static let getSerialNumber = RazerCommand(22, 0x00, 0x82)
    public static let getDeviceMode = RazerCommand(2, 0x00, 0x84)
    public static let setDeviceMode = RazerCommand(2, 0x00, 0x04)
    public static let getPollingPeriod = RazerCommand(1, 0x00, 0x85)
    public static let setPollingPeriod = RazerCommand(1, 0x00, 0x05)

    public static let getDebounceTime = RazerCommand(4, 0x02, 0x82)
    public static let getButtonIDList = RazerCommand(80, 0x02, 0x84)
    public static let getButtonAssignmentList = RazerCommand(80, 0x02, 0x8E)
    public static let getButtonAssignment = RazerCommand(80, 0x02, 0x8C)
    public static let setButtonAssignment = RazerCommand(80, 0x02, 0x0C)

    public static let getDPIStages = RazerCommand(38, 0x04, 0x83)
    public static let getActiveDPIStage = RazerCommand(2, 0x04, 0x84)
    public static let setActiveDPIStage = RazerCommand(2, 0x04, 0x04)
    public static let getActiveDPI = RazerCommand(7, 0x04, 0x85)
    public static let setActiveDPI = RazerCommand(7, 0x04, 0x05)
}

/// 应答首字节。
public enum RazerStatus: UInt8, Sendable, CustomStringConvertible {
    case new = 0
    case busy = 1
    case success = 2
    case failed = 3
    case timeout = 4
    case notSupported = 5
    case commandMismatch = 225

    public var description: String {
        switch self {
        case .new: "new"
        case .busy: "busy"
        case .success: "success"
        case .failed: "failed"
        case .timeout: "timeout"
        case .notSupported: "not supported"
        case .commandMismatch: "custom command mismatch"
        }
    }
}

/// 90 字节负载（不含报告 ID）。
public enum RazerFrame {
    public static let length = 90
    public static let maxArguments = 80

    public static func make(_ command: RazerCommand, arguments: [UInt8], transactionID: UInt8) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: length)
        frame[1] = transactionID
        frame[5] = command.dataSize
        frame[6] = command.commandClass
        frame[7] = command.commandID
        let count = min(Int(command.dataSize), maxArguments)
        for (i, byte) in arguments.prefix(count).enumerated() {
            frame[8 + i] = byte
        }
        frame[88] = checksum(frame)
        return frame
    }

    /// 字节 [2..87] 的异或。
    public static func checksum(_ frame: [UInt8]) -> UInt8 {
        frame[2..<88].reduce(0, ^)
    }
}

public struct RazerReply: Sendable {
    public let statusByte: UInt8
    public let transactionID: UInt8
    public let dataSize: UInt8
    public let commandClass: UInt8
    public let commandID: UInt8
    public let arguments: [UInt8]

    public var status: RazerStatus? { RazerStatus(rawValue: statusByte) }

    public init?(payload: [UInt8]) {
        guard payload.count >= RazerFrame.length else { return nil }
        statusByte = payload[0]
        transactionID = payload[1]
        dataSize = payload[5]
        commandClass = payload[6]
        commandID = payload[7]
        let count = min(Int(dataSize), RazerFrame.maxArguments)
        arguments = Array(payload[8..<(8 + count)])
    }
}

public enum RazerError: Error, LocalizedError, Equatable {
    case deviceNotFound
    case notPermitted
    case openFailed(Int32)
    case io(Int32)
    case noResponse(RazerCommand)
    case status(UInt8, RazerCommand)
    case invalidReply(RazerCommand)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            String(localized: "DeathAdder Essential not found", bundle: .module)
        case .notPermitted:
            String(localized: "No permission to access the device (Input Monitoring access required)", bundle: .module)
        case .openFailed(let rc):
            String(localized: "Failed to open device (IOReturn \(Self.hex(rc)))", bundle: .module)
        case .io(let rc):
            String(localized: "HID transfer failed (IOReturn \(Self.hex(rc)))", bundle: .module)
        case .noResponse(let cmd):
            String(localized: "No response from device \(cmd.description)", bundle: .module)
        case .status(let s, let cmd):
            String(localized: "Device returned \(RazerStatus(rawValue: s)?.description ?? "status \(s)") \(cmd.description)", bundle: .module)
        case .invalidReply(let cmd):
            String(localized: "Malformed reply \(cmd.description)", bundle: .module)
        case .verifyFailed(let detail):
            String(localized: "Read-back mismatch after write: \(detail)", bundle: .module)
        }
    }

    private static func hex(_ rc: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: rc))
    }
}
