import Foundation

/// 特性报告收发的抽象，便于离线测试。
public protocol FeatureReportTransport: AnyObject {
    /// `payload` 恒为 90 字节；`includeReportID` 为真时实现应在前面补一个 0x00。
    func sendFeatureReport(_ payload: [UInt8], includeReportID: Bool) throws
    /// 返回读到的原始字节（90 或 91 字节，是否带报告 ID 由 `RazerLink` 判断）。
    func receiveFeatureReport() throws -> [UInt8]
}

/// 「写一条命令、再读一条应答」的事务层：事务号、busy 重试、应答匹配。
public final class RazerLink {
    public let transport: FeatureReportTransport
    /// 写缓冲区是否带报告 ID 前缀。macOS 上实测必须是 false（90 字节）；
    /// 不做自动探测：发 91 字节的错位帧会让固件之后不再处理命令。
    public let includeReportID: Bool
    public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    private var nextTransactionID: UInt8 = 0

    public init(transport: FeatureReportTransport, includeReportID: Bool = false) {
        self.transport = transport
        self.includeReportID = includeReportID
    }

    /// 发送命令并要求 status == success，返回应答参数。
    @discardableResult
    public func execute(_ command: RazerCommand, _ arguments: [UInt8] = []) throws -> [UInt8] {
        let reply = try transact(command, arguments)
        guard reply.status == .success else {
            throw RazerError.status(reply.statusByte, command)
        }
        return reply.arguments
    }

    /// 发送命令并返回原始应答（不检查 status）。
    public func transact(_ command: RazerCommand, _ arguments: [UInt8] = []) throws -> RazerReply {
        // 应答对不上时重发同一条命令（Synapse 的做法），busy 时只重读。
        // 设备处理命令期间 GetReport 可能直接报错，这种情况也当作“还没好”继续等。
        var lastError: Error = RazerError.noResponse(command)
        for _ in 0..<2 {
            let txn = takeTransactionID()
            let frame = RazerFrame.make(command, arguments: arguments, transactionID: txn)
            try transport.sendFeatureReport(frame, includeReportID: includeReportID)
            sleep(0.002)
            for _ in 0..<60 {
                let raw: [UInt8]
                do {
                    raw = try transport.receiveFeatureReport()
                } catch {
                    lastError = error
                    sleep(0.003)
                    continue
                }
                if let reply = Self.match(raw, txn: txn, command: command) {
                    // status 0(new) 表示设备还没处理完这条命令。
                    if reply.status == .busy || reply.status == .new {
                        sleep(0.003)
                        continue
                    }
                    return reply
                }
                lastError = RazerError.noResponse(command)
                sleep(0.003)
            }
        }
        throw lastError
    }

    private func takeTransactionID() -> UInt8 {
        if nextTransactionID >= 31 { nextTransactionID = 0 }
        defer { nextTransactionID += 1 }
        return nextTransactionID
    }

    /// 读回的缓冲区可能带也可能不带报告 ID 前缀：macOS 上实测 len 有时是 91 但内容不带前缀，
    /// Windows 上则是带前缀的 91 字节。两种对齐都试，以事务号和命令号对上为准。
    static func match(_ raw: [UInt8], txn: UInt8, command: RazerCommand) -> RazerReply? {
        let offsets = raw.count > RazerFrame.length ? [0, 1] : [0]
        for offset in offsets where raw.count - offset >= RazerFrame.length {
            let payload = Array(raw[offset..<(offset + RazerFrame.length)])
            if let reply = RazerReply(payload: payload),
               reply.transactionID == txn,
               reply.commandClass == command.commandClass,
               reply.commandID == command.commandID {
                return reply
            }
        }
        return nil
    }
}
