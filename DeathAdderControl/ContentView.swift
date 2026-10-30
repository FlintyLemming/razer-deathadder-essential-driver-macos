import AppKit
import SwiftUI
import RazerKit

struct ContentView: View {
    @Environment(MouseModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            Group {
                switch model.connection {
                case .searching:
                    PlaceholderView(
                        symbol: "cable.connector",
                        title: "等待鼠标连接",
                        detail: "插入 Razer DeathAdder Essential（USB 1532:0098）后会自动连接。",
                        showsProgress: true
                    )
                case .permissionNeeded:
                    PermissionView()
                case .failed(let reason):
                    PlaceholderView(symbol: "exclamationmark.triangle", title: "无法打开设备", detail: reason) {
                        Button("重试") { Task { await model.connect() } }
                    }
                case .connected:
                    SettingsForm()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MessageBar()
            Divider()
            ProjectFooter()
        }
        .frame(width: 540, height: 760)
    }
}

// MARK: - 顶栏

private struct HeaderView: View {
    @Environment(MouseModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "computermouse.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Razer DeathAdder Essential").font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
            if model.connection == .connected {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读取设备状态")
                .disabled(model.busy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch model.connection {
        case .searching: "未连接"
        case .permissionNeeded: "已检测到，等待授权"
        case .failed: "连接失败"
        case .connected:
            if let info = model.info {
                "固件 \(info.firmware) · \(info.serial) · \(info.modeName) 模式"
            } else {
                "已连接"
            }
        }
    }
}

// MARK: - 设置

private struct SettingsForm: View {
    @Environment(MouseModel.self) private var model
    @State private var dpiDraft: Double = 1600
    @State private var editing: UInt8?
    @State private var confirmRestore = false
    @State private var rawCommand = ""
    @State private var rawOutput = ""

    var body: some View {
        Form {
            if let info = model.info, info.mode != DeviceMode.normal.rawValue {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("设备处于 \(info.modeName) 模式").font(.headline)
                            Text("这个模式下固件不执行板载按键映射（通常是被 Windows 上的 Synapse 切过去的）。切回 Normal 模式后映射才会生效。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("切换到 Normal") { Task { await model.switchToNormalMode() } }
                    }
                }
            }

            dpiSection
            pollingSection
            buttonSection
            advancedSection
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .onAppear { dpiDraft = Double(model.dpi) }
        .onChange(of: model.dpi) { _, new in dpiDraft = Double(new) }
    }

    private var dpiSection: some View {
        Section("灵敏度") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DPI")
                    Spacer()
                    Text("\(Int(dpiDraft))")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Slider(
                    value: $dpiDraft,
                    in: Double(DeathAdder.dpiRange.lowerBound)...Double(DeathAdder.dpiRange.upperBound),
                    step: Double(DeathAdder.dpiStep)
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("200").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("6400").font(.caption).foregroundStyle(.secondary)
                } onEditingChanged: { isEditing in
                    if !isEditing, Int(dpiDraft) != model.dpi {
                        Task { await model.applyDPI(Int(dpiDraft)) }
                    }
                }
            }
            if let stages = model.stages, !stages.values.isEmpty {
                LabeledContent("预设档位") {
                    HStack(spacing: 6) {
                        ForEach(Array(stages.values.enumerated()), id: \.offset) { index, value in
                            let selected = stages.active == index + 1 && value == model.dpi
                            Button("\(value)") { Task { await model.selectStage(index + 1) } }
                                .buttonStyle(.bordered)
                                .tint(selected ? .green : nil)
                                .fontWeight(selected ? .semibold : .regular)
                        }
                    }
                }
            }
        }
    }

    private var pollingSection: some View {
        Section("回报率") {
            let rates = PollingRate.common + (model.pollingRate.map { PollingRate.common.contains($0) ? [] : [$0] } ?? [])
            Picker("回报率", selection: Binding(
                get: { model.pollingRate ?? PollingRate(code: 1) },
                set: { rate in Task { await model.applyPollingRate(rate) } }
            )) {
                ForEach(rates.sorted { $0.hertz < $1.hertz }) { rate in
                    Text("\(rate.hertz) Hz").tag(rate)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var buttonSection: some View {
        Section {
            ForEach(model.buttons) { slot in
                LabeledContent(slot.name) {
                    HStack {
                        Text(slot.action?.displayName ?? "未读取")
                            .foregroundStyle(slot.action == .off ? .secondary : .primary)
                        Button("更改…") { editing = slot.id }
                            .popover(isPresented: Binding(
                                get: { editing == slot.id },
                                set: { if !$0 { editing = nil } }
                            ), arrowEdge: .trailing) {
                                ButtonEditor(slot: slot) { action in
                                    editing = nil
                                    if let action {
                                        Task { await model.assign(action, to: slot.id) }
                                    }
                                }
                            }
                    }
                }
            }
        } header: {
            Text("按键映射")
        } footer: {
            HStack {
                Text("映射写入鼠标板载存储，换一台电脑也有效。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复出厂映射…") { confirmRestore = true }
                    .confirmationDialog("把所有按键恢复为出厂映射？", isPresented: $confirmRestore) {
                        Button("恢复", role: .destructive) { Task { await model.restoreDefaults() } }
                    } message: {
                        Text("出厂映射中两个侧键是鼠标按钮 4 / 5（后退 / 前进）。")
                    }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("调试命令") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("class id size [参数...]，如 0x00 0x81 2", text: $rawCommand)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendRaw)
                        Button("发送", action: sendRaw)
                            .disabled(rawCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !rawOutput.isEmpty {
                        Text(rawOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func sendRaw() {
        let line = rawCommand
        Task { rawOutput = await model.sendRaw(line) }
    }
}

// MARK: - 按键编辑

private struct ButtonEditor: View {
    let slot: MouseModel.ButtonSlot
    let onFinish: (ButtonAction?) -> Void

    private enum Kind: Hashable { case mouse, key, off }

    @State private var kind: Kind = .mouse
    @State private var mouseCode: UInt8 = 1
    @State private var modifiers: KeyModifiers = []
    @State private var usage: UInt8 = 0x04
    @State private var recording = false
    @State private var monitor: Any?

    private var result: ButtonAction {
        switch kind {
        case .mouse: .mouseButton(mouseCode)
        case .key: .key(modifiers: modifiers, usage: usage)
        case .off: .off
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置「\(slot.name)」").font(.headline)

            Picker("类型", selection: $kind) {
                Text("鼠标按键").tag(Kind.mouse)
                Text("键盘按键").tag(Kind.key)
                Text("禁用").tag(Kind.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .mouse:
                Picker("输出", selection: $mouseCode) {
                    ForEach(MouseButtonCode.selectable, id: \.self) { code in
                        Text(MouseButtonCode.name(code)).tag(code)
                    }
                }
            case .key:
                keyEditor
            case .off:
                Text("按下这个按钮不会产生任何输出。")
                    .foregroundStyle(.secondary)
            }

            if slot.id == 1 && result != .mouseButton(1) {
                Label("改掉左键后，需要用触控板或其他鼠标才能点回来。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(result.displayName).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { onFinish(result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recording)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear(perform: loadCurrent)
        .onDisappear(perform: stopRecording)
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                modifierToggle("⌃ Control", .leftControl)
                modifierToggle("⌥ Option", .leftOption)
                modifierToggle("⇧ Shift", .leftShift)
                modifierToggle("⌘ Command", .leftCommand)
            }
            Picker("按键", selection: $usage) {
                ForEach(HIDKeyboard.groups) { group in
                    Section(group.title) {
                        ForEach(group.keys) { key in
                            Text(key.name).tag(key.usage)
                        }
                    }
                }
                if !HIDKeyboard.groups.contains(where: { $0.keys.contains { $0.usage == usage } }) {
                    Text(HIDKeyboard.name(usage)).tag(usage)
                }
            }
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Label(recording ? "请按下要录制的组合键…" : "录制按键", systemImage: recording ? "record.circle.fill" : "keyboard")
            }
            .tint(recording ? .red : nil)
        }
    }

    private func modifierToggle(_ title: String, _ flag: KeyModifiers) -> some View {
        Toggle(title, isOn: Binding(
            get: { modifiers.contains(flag) },
            set: { on in
                if on { modifiers.insert(flag) } else { modifiers.remove(flag) }
            }
        ))
        .toggleStyle(.button)
    }

    private func loadCurrent() {
        switch slot.action {
        case .mouseButton(let code)?:
            kind = .mouse
            mouseCode = code
        case .key(let mods, let u)?:
            kind = .key
            modifiers = mods
            usage = u
        case .off?:
            kind = .off
        default:
            kind = .mouse
            mouseCode = slot.id <= 5 ? slot.id : 1
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let hid = HIDKeyboard.usage(forMacKeyCode: event.keyCode) else { return nil }
            var mods: KeyModifiers = []
            let flags = event.modifierFlags
            if flags.contains(.control) { mods.insert(.leftControl) }
            if flags.contains(.option) { mods.insert(.leftOption) }
            if flags.contains(.shift) { mods.insert(.leftShift) }
            if flags.contains(.command) { mods.insert(.leftCommand) }
            modifiers = mods
            usage = hid
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - 占位与权限

private struct PlaceholderView<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var showsProgress = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if showsProgress { ProgressView().controlSize(.small) }
            actions()
        }
        .padding(32)
    }
}

extension PlaceholderView where Actions == EmptyView {
    init(symbol: String, title: String, detail: String, showsProgress: Bool = false) {
        self.init(symbol: symbol, title: title, detail: detail, showsProgress: showsProgress) { EmptyView() }
    }
}

private struct PermissionView: View {
    @Environment(MouseModel.self) private var model

    var body: some View {
        PlaceholderView(
            symbol: "lock.shield",
            title: "需要“输入监控”权限",
            detail: "macOS 要求先授权，才能读写鼠标的配置报告。请在 系统设置 → 隐私与安全性 → 输入监控 里允许 DeathAdder Control，然后重新打开本程序。"
        ) {
            HStack {
                Button("请求授权") { model.requestPermission() }
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("重新打开") { relaunch() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { model.requestPermission() }
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 项目链接

enum Project {
    static let repository = URL(string: "https://github.com/FlintyLemming/razer-deathadder-essential-driver-macos")!
}

private struct ProjectFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("开源项目，觉得好用欢迎点个 Star ⭐")
                .foregroundStyle(.secondary)
            Spacer()
            Link(destination: Project.repository) {
                Label("GitHub", systemImage: "star")
            }
            .help(Project.repository.absoluteString)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct MessageBar: View {
    @Environment(MouseModel.self) private var model

    var body: some View {
        if let message = model.message {
            HStack(spacing: 8) {
                Image(systemName: model.messageIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.messageIsError ? .red : .green)
                Text(message).lineLimit(2)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
