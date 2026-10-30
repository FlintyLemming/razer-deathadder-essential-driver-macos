import Foundation
import Testing
@testable import RazerKit

@Suite struct FrameTests {
    @Test func firmwareRequestMatchesCapture() {
        // 文档 §2 实测：00 00 00 00 00 02 00 81 ... 83 00
        let f = RazerFrame.make(.getFirmwareVersion, arguments: [], transactionID: 0)
        #expect(f.count == 90)
        #expect(Array(f[0..<8]) == [0, 0, 0, 0, 0, 0x02, 0x00, 0x81])
        #expect(f[88] == 0x83)
        #expect(f[89] == 0)
    }

    @Test func argumentsAreTruncatedToDataSize() {
        let f = RazerFrame.make(.getPollingPeriod, arguments: [1, 2, 3], transactionID: 5)
        #expect(f[8] == 1)
        #expect(f[9] == 0)
        #expect(f[1] == 5)
    }

    @Test func replyParsing() {
        var p = [UInt8](repeating: 0, count: 90)
        p[0] = 2; p[1] = 0; p[5] = 2; p[6] = 0; p[7] = 0x81; p[8] = 1; p[9] = 0
        let r = RazerReply(payload: p)
        #expect(r?.status == .success)
        #expect(r?.arguments == [1, 0])
    }
}

@Suite struct DescriptorTests {
    @Test func featureLengthFromDescriptor() {
        // Usage Page(1) Usage(2) Collection ... Report Size 8, Report Count 90, Feature
        let desc: [UInt8] = [0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
                             0x75, 0x08, 0x95, 0x5A, 0xB1, 0x01,
                             0x95, 0x03, 0x81, 0x02, 0xC0]
        #expect(HIDReportDescriptor.maxFeatureReportLength(Data(desc)) == 90)
    }

    @Test func noFeatureItems() {
        let desc: [UInt8] = [0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x75, 0x08, 0x95, 0x08, 0x81, 0x00, 0xC0]
        #expect(HIDReportDescriptor.maxFeatureReportLength(Data(desc)) == 0)
    }
}

@Suite struct MappingTests {
    @Test func decodesDocumentedRecords() {
        #expect(ButtonAction(record: [1, 1, 1, 0, 0, 0, 0]) == .mouseButton(1))
        #expect(ButtonAction(record: [2, 2, 1, 0x50, 0, 0, 0]) == .key(modifiers: .leftControl, usage: 0x50))
        #expect(ButtonAction(record: [0, 0, 0, 0, 0, 0, 0]) == .off)
        // size=1 的 KeyCode 会被存下但不执行，不能当成有效按键
        #expect(ButtonAction(record: [2, 1, 4, 0, 0, 0, 0]) == .raw(mode: 2, data: [4]))
    }

    @Test func encodesWriteRecipes() {
        #expect(ButtonAction.mouseButton(9).record == [1, 1, 9])
        #expect(ButtonAction.key(modifiers: [], usage: 0x05).record == [2, 2, 0, 0x05])
        #expect(ButtonAction.key(modifiers: [.leftControl, .leftShift], usage: 0x04).record == [2, 2, 0x03, 0x04])
        #expect(ButtonAction.off.record == [0, 0])
    }

    @Test func displayNames() {
        #expect(ButtonAction.key(modifiers: .leftControl, usage: 0x50).displayName == "Control + ←")
        #expect(HIDKeyboard.usage(forMacKeyCode: 0x00) == 0x04)  // kVK_ANSI_A
        #expect(HIDKeyboard.usage(forMacKeyCode: 0x7B) == 0x50)  // kVK_LeftArrow
    }

    @Test func pollingRates() {
        #expect(PollingRate.common.map(\.hertz) == [1000, 500, 250, 125])
        #expect(PollingRate(code: 3).hertz == 333)
    }
}

/// 模拟设备：只认 `expectsReportID` 指定的缓冲区写法，可注入若干次 busy。
final class FakeTransport: FeatureReportTransport {
    var expectsReportID: Bool
    var busyReplies: Int
    var failingReads = 0
    /// 前几次读回的是原样回显、status=0(new)，模拟设备尚未处理完
    var unprocessedReads = 0
    /// 读回 91 字节：true = 带报告 ID 前缀（Windows 风格），false = 不带前缀但多一个尾字节（macOS 实测）
    var longRead: Bool?
    var pending: [UInt8]?
    var sent: [[UInt8]] = []

    init(expectsReportID: Bool, busyReplies: Int = 0) {
        self.expectsReportID = expectsReportID
        self.busyReplies = busyReplies
    }

    func sendFeatureReport(_ payload: [UInt8], includeReportID: Bool) throws {
        guard includeReportID == expectsReportID else { throw RazerError.io(-1) }
        sent.append(payload)
        var reply = payload
        reply[0] = RazerStatus.success.rawValue
        if payload[6] == 0x00 && payload[7] == 0x81 { reply[8] = 1; reply[9] = 0 }
        pending = reply
    }

    func receiveFeatureReport() throws -> [UInt8] {
        if failingReads > 0 {
            failingReads -= 1
            throw RazerError.io(-2)
        }
        guard var reply = pending else { return [UInt8](repeating: 0, count: 90) }
        if unprocessedReads > 0 {
            unprocessedReads -= 1
            reply = sent.last!
        } else if busyReplies > 0 {
            busyReplies -= 1
            reply[0] = RazerStatus.busy.rawValue
        }
        switch longRead {
        case true?: return [0] + reply
        case false?: return reply + [0]
        case nil: return reply
        }
    }
}

@Suite struct LinkTests {
    @Test func reportIDPrefixIsOptIn() throws {
        let t = FakeTransport(expectsReportID: true)
        let link = RazerLink(transport: t)
        link.sleep = { _ in }
        #expect(throws: RazerError.self) { try link.execute(.getFirmwareVersion) }
        #expect(t.sent.isEmpty)
        let prefixed = RazerLink(transport: t, includeReportID: true)
        prefixed.sleep = { _ in }
        #expect(try prefixed.execute(.getFirmwareVersion) == [1, 0])
    }

    @Test func retriesBusy() throws {
        let t = FakeTransport(expectsReportID: false, busyReplies: 3)
        let link = RazerLink(transport: t)
        link.sleep = { _ in }
        _ = try link.execute(.getFirmwareVersion)
        #expect(t.sent.count == 1)
    }

    @Test func toleratesTransientReadErrors() throws {
        let t = FakeTransport(expectsReportID: false)
        t.failingReads = 2
        let link = RazerLink(transport: t)
        link.sleep = { _ in }
        #expect(try link.execute(.getFirmwareVersion) == [1, 0])
    }

    @Test func macOSStyleLongReadWithoutPrefix() throws {
        let t = FakeTransport(expectsReportID: false)
        t.longRead = false
        t.unprocessedReads = 4
        let link = RazerLink(transport: t)
        link.sleep = { _ in }
        #expect(try link.execute(.getFirmwareVersion) == [1, 0])
        #expect(t.sent.count == 1)
    }

    @Test func windowsStyleLongReadWithPrefix() throws {
        let t = FakeTransport(expectsReportID: false)
        t.longRead = true
        let link = RazerLink(transport: t)
        link.sleep = { _ in }
        #expect(try link.execute(.getFirmwareVersion) == [1, 0])
    }

    @Test func transactionIDWraps() throws {
        let t = FakeTransport(expectsReportID: false)
        let link = RazerLink(transport: t, includeReportID: false)
        link.sleep = { _ in }
        for _ in 0..<33 { _ = try link.execute(.getPollingPeriod) }
        #expect(t.sent.map { $0[1] }.max() == 30)
        #expect(t.sent[31][1] == 0)
    }
}

/// 回放真机抓到的应答。
final class ReplayTransport: FeatureReportTransport {
    let arguments: [UInt8]
    var pending: [UInt8]?
    init(arguments: [UInt8]) { self.arguments = arguments }

    func sendFeatureReport(_ payload: [UInt8], includeReportID: Bool) throws {
        var reply = payload
        reply[0] = RazerStatus.success.rawValue
        for (i, b) in arguments.enumerated() { reply[8 + i] = b }
        pending = reply
    }

    func receiveFeatureReport() throws -> [UInt8] { pending! }
}

@Suite struct DeviceParsingTests {
    @Test func dpiStagesFromCapture() throws {
        // GET_SINGLE_DPI_CLASS_DATA 真机应答（macOS，2026-10-30）
        let capture: [UInt8] = [0x00, 0x03, 0x05,
                                0x01, 0x01, 0x90, 0x01, 0x90, 0x00, 0x00,
                                0x02, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00,
                                0x03, 0x06, 0x40, 0x06, 0x40, 0x00, 0x00,
                                0x04, 0x0C, 0x80, 0x0C, 0x80, 0x00, 0x00,
                                0x05, 0x19, 0x00, 0x19, 0x00]
        let link = RazerLink(transport: ReplayTransport(arguments: capture))
        link.sleep = { _ in }
        let stages = try DeathAdder(link: link).dpiStages()
        #expect(stages == DPIStages(active: 3, values: [400, 800, 1600, 3200, 6400]))
    }
}
