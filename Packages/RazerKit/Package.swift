// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RazerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RazerKit", targets: ["RazerKit"]),
        .executable(name: "rzctl", targets: ["rzctl"]),
    ],
    targets: [
        .target(
            name: "RazerKit",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(name: "rzctl", dependencies: ["RazerKit"]),
        .testTarget(name: "RazerKitTests", dependencies: ["RazerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
