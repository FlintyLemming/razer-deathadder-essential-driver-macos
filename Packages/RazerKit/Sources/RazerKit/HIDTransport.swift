import Foundation
import IOKit
import IOKit.hid

/// 用 IOHIDDeviceSetReport / GetReport 收发特性报告，报告 ID 固定为 0。
public final class IOHIDFeatureTransport: FeatureReportTransport {
    public let device: IOHIDDevice
    private var isOpen = false

    public init(device: IOHIDDevice) {
        self.device = device
    }

    deinit { close() }

    public func open() throws {
        guard !isOpen else { return }
        // 不能用 SeizeDevice，否则鼠标本身会失灵。
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            if rc == kIOReturnNotPermitted { throw RazerError.notPermitted }
            throw RazerError.openFailed(rc)
        }
        isOpen = true
    }

    public func close() {
        guard isOpen else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
    }

    public func sendFeatureReport(_ payload: [UInt8], includeReportID: Bool) throws {
        let buffer = includeReportID ? [0] + payload : payload
        let rc = buffer.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
        }
        guard rc == kIOReturnSuccess else { throw RazerError.io(rc) }
    }

    public func receiveFeatureReport() throws -> [UInt8] {
        // 按描述符里的报告长度（90）读；多要一个字节时 macOS 上实测拿不到设备处理后的应答。
        let capacity = RazerFrame.length
        var buffer = [UInt8](repeating: 0, count: capacity)
        var length = CFIndex(capacity)
        let rc = buffer.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
        }
        guard rc == kIOReturnSuccess else { throw RazerError.io(rc) }
        return Array(buffer[0..<max(min(length, capacity), RazerFrame.length)])
    }
}

public enum HIDReportDescriptor {
    /// 只统计 Feature 主项，返回最大的那条特性报告字节数（不含报告 ID）。
    public static func maxFeatureReportLength(_ data: Data) -> Int {
        let d = [UInt8](data)
        var bitsByReport: [Int: Int] = [:]
        var reportSize = 0, reportCount = 0, reportID = 0
        var i = 0
        while i < d.count {
            let prefix = d[i]
            i += 1
            if prefix == 0xFE {
                // 长项：[0xFE, dataSize, tag, data...]
                guard i < d.count else { break }
                i += 2 + Int(d[i])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)
            let n = sizeCode == 3 ? 4 : sizeCode
            guard i + n <= d.count else { break }
            var value = 0
            for k in 0..<n { value |= Int(d[i + k]) << (8 * k) }
            i += n
            if type == 1 {
                switch tag {
                case 0x7: reportSize = value
                case 0x8: reportID = value & 0xFF
                case 0x9: reportCount = value
                default: break
                }
            } else if type == 0 && tag == 0xB {
                bitsByReport[reportID, default: 0] += reportSize * reportCount
            }
        }
        return bitsByReport.values.map { ($0 + 7) / 8 }.max() ?? 0
    }
}

extension IOHIDDevice {
    func intProperty(_ key: String) -> Int? {
        (IOHIDDeviceGetProperty(self, key as CFString) as? NSNumber)?.intValue
    }

    /// 特性报告长度：优先用描述符解析，取不到再用 IOKit 给的 MaxFeatureReportSize。
    var featureReportLength: Int {
        if let desc = IOHIDDeviceGetProperty(self, kIOHIDReportDescriptorKey as CFString) as? Data {
            let parsed = HIDReportDescriptor.maxFeatureReportLength(desc)
            if parsed > 0 { return parsed }
        }
        return intProperty(kIOHIDMaxFeatureReportSizeKey) ?? 0
    }
}

/// 监听 DeathAdder Essential 的插拔，并挑出承载厂商协议的那个集合。
public final class DeathAdderMonitor {
    public static let vendorID = 0x1532
    public static let productID = 0x0098

    /// 设备集合增减时在主线程回调。
    public var onChange: (() -> Void)?

    private let manager: IOHIDManager

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// 开始监听。这里不调用 IOHIDManagerOpen：它会连键盘集合一起打开，平白要求更多权限。
    public func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<DeathAdderMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<DeathAdderMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public var devices: [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    /// 特性报告 ≥ 90 字节的集合（本机是 usage 0x0001/0x0002，不是厂商页，所以不按 usage 筛）。
    public func controlDevice() -> IOHIDDevice? {
        devices
            .filter { $0.featureReportLength >= RazerFrame.length }
            .max { $0.featureReportLength < $1.featureReportLength }
    }

    public func describeCollections() -> [String] {
        devices.map { dev in
            String(
                format: "usage 0x%04X/0x%04X  feature=%d bytes",
                dev.intProperty(kIOHIDPrimaryUsagePageKey) ?? 0,
                dev.intProperty(kIOHIDPrimaryUsageKey) ?? 0,
                dev.featureReportLength
            )
        }.sorted()
    }
}

public enum InputMonitoringAccess {
    public enum State { case granted, denied, unknown }

    public static var state: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .unknown
        }
    }

    /// 弹出系统授权提示（只会在首次弹出）。
    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
