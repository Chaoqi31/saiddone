// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaidDone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SaidDoneCore", targets: ["SaidDoneCore"]),
        .executable(name: "SaidDone", targets: ["SaidDoneApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.0"),
    ],
    targets: [
        // Pure logic: protocols, pipeline, dictionary, profiles, config, rule-based polish. No external deps.
        .target(name: "SaidDoneCore"),
        // Concrete Providers (real engines + scaffolds + ladder + factory).
        .target(
            name: "SaidDoneProviders",
            dependencies: [
                "SaidDoneCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        // Menu-bar app shell: capture, hotkey, insertion, UI.
        .executableTarget(
            name: "SaidDoneApp",
            dependencies: ["SaidDoneCore", "SaidDoneProviders"]
        ),
        // Headless spike harness: load a WAV/AIFF, run ASR→polish→translate, print output + timing.
        // Validates the real engines on-device without mic/GUI (Phase-0 spike).
        .executableTarget(
            name: "SaidDoneSpike",
            dependencies: [
                "SaidDoneCore", "SaidDoneProviders",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(name: "SaidDoneCoreTests", dependencies: ["SaidDoneCore"]),
        .testTarget(name: "SaidDoneProvidersTests", dependencies: ["SaidDoneProviders"]),
    ]
)
