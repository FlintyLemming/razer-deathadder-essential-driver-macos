import AppKit
import SwiftUI
import RazerKit

@main
struct DeathAdderControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = MouseModel()

    init() {
        // `--self-test <输出文件>`：不开窗口，把设备状态写进文件后退出，用于核对链路。
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--self-test") {
            let path = i + 1 < arguments.count ? arguments[i + 1] : "/dev/stdout"
            let report = SelfTest.run(arguments: arguments)
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    var body: some Scene {
        Window("DeathAdder Essential", id: "main") {
            ContentView()
                .environment(model)
                .task { model.start() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Link("GitHub Project Page (Stars Welcome)", destination: Project.repository)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
