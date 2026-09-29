// swift-tools-version: 6.0
import PackageDescription

// C1 of the v2 rewrite: only the pure core is built while the engines and the app shell are rewritten on top of it.
let package = Package(
    name: "SaidDone",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SaidDoneCore"),
        .testTarget(name: "SaidDoneCoreTests", dependencies: ["SaidDoneCore"]),
    ]
)
