// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaidDone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SaidDoneCore", targets: ["SaidDoneCore"]),
        .executable(name: "SaidDone", targets: ["SaidDoneApp"]),
    ],
    targets: [
        // Pure logic: protocols, pipeline, dictionary, profiles, config. No external deps -> fast, testable, offline.
        .target(name: "SaidDoneCore"),
        // Menu-bar app shell: capture, hotkey, insertion, UI. System frameworks only for now.
        .executableTarget(
            name: "SaidDoneApp",
            dependencies: ["SaidDoneCore"]
        ),
        .testTarget(
            name: "SaidDoneCoreTests",
            dependencies: ["SaidDoneCore"]
        ),
    ]
)
