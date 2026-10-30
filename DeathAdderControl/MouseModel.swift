import Foundation
import Observation
import RazerKit

@MainActor
@Observable
final class MouseModel {
    enum Connection: Equatable {
        case searching
        case permissionNeeded
        case failed(String)
        case connected
    }

    struct ButtonSlot: Identifiable, Equatable, Sendable {
        let id: UInt8
        var action: ButtonAction?
        var name: String { PhysicalButton.name(id) }
    }

    var connection: Connection = .searching
    var info: DeviceInfo?
    var dpi = 1600
    var stages: DPIStages?
    var pollingRate: PollingRate?
    var buttons: [ButtonSlot] = []
    var busy = false
    var message: String?
    var messageIsError = false

    private let monitor = DeathAdderMonitor()
    private var mouse: DeathAdder?
    private let queue = DispatchQueue(label: "razer.deathadder.io")
    private var reconnectPending = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReconnect() }
        }
        monitor.start()
        scheduleReconnect()
    }

    /// 插拔时一个物理设备会触发多次回调（每个集合一次），合并成一次。
    private func scheduleReconnect() {
        guard !reconnectPending else { return }
        reconnectPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reconnectPending = false
            await connect()
        }
    }

    func connect() async {
        let device = monitor.controlDevice()
        if let mouse, device != nil, connection == .connected {
            // 设备仍在，确认链路是否还活着。
            if (try? await io(mouse) { try $0.deviceMode() }) != nil { return }
        }
        mouse?.close()
        mouse = nil
        info = nil
        guard let device else {
            connection = .searching
            buttons = []
            return
        }
        do {
            mouse = try DeathAdder(device: device)
            connection = .connected
            await refresh()
        } catch RazerError.notPermitted {
            connection = .permissionNeeded
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// 实测按钮表；读不到时用它兜底，保证改键列表始终可见。
    private static let knownButtonIDs: [UInt8] = [1, 2, 3, 4, 5, 9, 10]

    /// 各项分开读，一项失败不影响其它项显示。
    func refresh() async {
        guard let mouse else { return }
        busy = true
        defer { busy = false }
        var errors: [String] = []
        func attempt<T: Sendable>(_ body: @escaping @Sendable (DeathAdder) throws -> T) async -> T? {
            do { return try await io(mouse, body) } catch {
                errors.append(error.localizedDescription)
                return nil
            }
        }
        if let info = await attempt({ try $0.info() }) { self.info = info }
        if let dpi = await attempt({ try $0.dpi() }) { self.dpi = dpi }
        stages = await attempt { try $0.dpiStages() }
        pollingRate = await attempt { try $0.pollingRate() }
        let ids = await attempt { try $0.buttonIDs() } ?? Self.knownButtonIDs
        let map = await attempt { try $0.buttonAssignments() } ?? [:]
        buttons = ids.map { ButtonSlot(id: $0, action: map[$0]) }
        if let first = errors.first {
            flash(String(localized: "Failed to read device state: \(first)"), isError: true)
        }
    }

    // MARK: 设置项

    func applyDPI(_ value: Int) async {
        guard let mouse else { return }
        await run(String(localized: "DPI set to \(value)")) {
            self.dpi = try await self.io(mouse) { m in
                try m.setDPI(value)
                return try m.dpi()
            }
        }
    }

    func selectStage(_ stage: Int) async {
        guard let mouse else { return }
        await run(nil) {
            (self.stages, self.dpi) = try await self.io(mouse) { m in
                try m.setActiveDPIStage(stage)
                return (try m.dpiStages(), try m.dpi())
            }
            self.flash(String(localized: "Switched to stage \(stage) (\(self.dpi) DPI)"))
        }
    }

    func applyPollingRate(_ rate: PollingRate) async {
        guard let mouse else { return }
        await run(String(localized: "Polling rate set to \(rate.hertz) Hz")) {
            self.pollingRate = try await self.io(mouse) { m in
                try m.setPollingRate(rate)
                return try m.pollingRate()
            }
        }
    }

    func assign(_ action: ButtonAction, to button: UInt8) async {
        guard let mouse else { return }
        await run("\(PhysicalButton.name(button)) → \(action.displayName)") {
            let readBack = try await self.io(mouse) { m in
                try m.setButtonAssignment(button, action)
                return try m.buttonAssignment(button)
            }
            if let i = self.buttons.firstIndex(where: { $0.id == button }) {
                self.buttons[i].action = readBack
            }
        }
    }

    func restoreDefaults() async {
        guard let mouse else { return }
        await run(String(localized: "Factory button mapping restored")) {
            let map = try await self.io(mouse) { m in
                try m.restoreDefaultAssignments()
                return try m.buttonAssignments()
            }
            for i in self.buttons.indices { self.buttons[i].action = map[self.buttons[i].id] }
        }
    }

    func switchToNormalMode() async {
        guard let mouse else { return }
        await run(String(localized: "Switched to Normal mode; on-board mapping is active")) {
            let mode = try await self.io(mouse) { m in
                try m.setDeviceMode(.normal)
                return try m.deviceMode()
            }
            self.info?.mode = mode
        }
    }

    /// 调试用：`class id size [bytes...]`，数字可写十进制或 0x 前缀十六进制。
    func sendRaw(_ line: String) async -> String {
        guard let mouse else { return String(localized: "Not Connected") }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let bytes = parts.compactMap(Self.parseByte)
        guard parts.count >= 3, bytes.count == parts.count else {
            return String(localized: "Format: class id size [arg bytes...], e.g. 0x00 0x81 2")
        }
        let command = RazerCommand(bytes[2], bytes[0], bytes[1])
        do {
            let reply = try await io(mouse) { try $0.link.transact(command, Array(bytes.dropFirst(3))) }
            var hex = reply.arguments.map { String(format: "%02X", $0) }
            while hex.last == "00" { hex.removeLast() }
            let status = reply.status?.description ?? "status \(reply.statusByte)"
            return "\(command)\n→ \(status)  \(hex.isEmpty ? String(localized: "(all zero)") : hex.joined(separator: " "))"
        } catch {
            return error.localizedDescription
        }
    }

    private static func parseByte(_ s: String) -> UInt8? {
        s.lowercased().hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
    }

    // MARK: 权限

    func requestPermission() {
        InputMonitoringAccess.request()
    }

    // MARK: 内部

    private func io<T: Sendable>(_ mouse: DeathAdder, _ body: @escaping @Sendable (DeathAdder) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(mouse) })
            }
        }
    }

    private func run(_ success: String?, _ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
            if let success { flash(success) }
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func flash(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
        let current = text
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if message == current { message = nil }
        }
    }
}
