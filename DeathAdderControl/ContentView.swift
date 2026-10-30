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
                        title: String(localized: "Waiting for Mouse"),
                        detail: String(localized: "Plug in a Razer DeathAdder Essential (USB 1532:0098) and it will connect automatically."),
                        showsProgress: true
                    )
                case .permissionNeeded:
                    PermissionView()
                case .failed(let reason):
                    PlaceholderView(symbol: "exclamationmark.triangle", title: String(localized: "Can’t Open Device"), detail: reason) {
                        Button("Retry") { Task { await model.connect() } }
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
                .help("Reload Device State")
                .disabled(model.busy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch model.connection {
        case .searching: String(localized: "Not Connected")
        case .permissionNeeded: String(localized: "Detected, waiting for permission")
        case .failed: String(localized: "Connection Failed")
        case .connected:
            if let info = model.info {
                String(localized: "Firmware \(info.firmware) · \(info.serial) · \(info.modeName) mode")
            } else {
                String(localized: "Connected")
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
                            Text("Device is in \(info.modeName) mode").font(.headline)
                            Text("In this mode the firmware ignores the on-board button mapping (usually Synapse on Windows switched it). Mappings take effect after switching back to Normal mode.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch to Normal") { Task { await model.switchToNormalMode() } }
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
        Section("Sensitivity") {
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
                LabeledContent("DPI Stages") {
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
        Section("Polling Rate") {
            let rates = PollingRate.common + (model.pollingRate.map { PollingRate.common.contains($0) ? [] : [$0] } ?? [])
            Picker("Polling Rate", selection: Binding(
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
                        Text(slot.action?.displayName ?? String(localized: "Not Read"))
                            .foregroundStyle(slot.action == .off ? .secondary : .primary)
                        Button("Change…") { editing = slot.id }
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
            Text("Button Mapping")
        } footer: {
            HStack {
                Text("Mappings are saved to the mouse’s on-board memory and work on any computer.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Factory Mapping…") { confirmRestore = true }
                    .confirmationDialog("Restore all buttons to the factory mapping?", isPresented: $confirmRestore) {
                        Button("Restore", role: .destructive) { Task { await model.restoreDefaults() } }
                    } message: {
                        Text("In the factory mapping, the two side buttons are mouse buttons 4 / 5 (Back / Forward).")
                    }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Debug Commands") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("class id size [args...], e.g. 0x00 0x81 2", text: $rawCommand)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendRaw)
                        Button("Send", action: sendRaw)
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
            Text("Configure “\(slot.name)”").font(.headline)

            Picker("Type", selection: $kind) {
                Text("Mouse Button").tag(Kind.mouse)
                Text("Keyboard Key").tag(Kind.key)
                Text("Disabled").tag(Kind.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .mouse:
                Picker("Output", selection: $mouseCode) {
                    ForEach(MouseButtonCode.selectable, id: \.self) { code in
                        Text(MouseButtonCode.name(code)).tag(code)
                    }
                }
            case .key:
                keyEditor
            case .off:
                Text("Pressing this button produces no output.")
                    .foregroundStyle(.secondary)
            }

            if slot.id == 1 && result != .mouseButton(1) {
                Label("After remapping the left button, you’ll need a trackpad or another mouse to change it back.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(result.displayName).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onFinish(result) }
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
            Picker("Key", selection: $usage) {
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
                Label(recording ? "Press the key combination to record…" : "Record Keys", systemImage: recording ? "record.circle.fill" : "keyboard")
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
            title: String(localized: "Input Monitoring Permission Required"),
            detail: String(localized: "macOS requires permission before the mouse’s configuration reports can be read or written. Allow DeathAdder Control in System Settings → Privacy & Security → Input Monitoring, then relaunch the app.")
        ) {
            HStack {
                Button("Request Access") { model.requestPermission() }
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Relaunch") { relaunch() }
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
            Text("Open source — if you find it useful, a Star would be appreciated ⭐")
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
