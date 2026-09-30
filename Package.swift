// swift-tools-version: 6.0
import PackageDescription

// C2 of the v2 rewrite: the core and the engines build; the app shell is rewritten on top of them in C3.
let package = Package(
    name: "SaidDone",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Pure product logic: shortcuts, session, prompts, pipeline, settings and history types. No dependencies.
        .target(name: "SaidDoneCore"),
        // Speech and AI engines behind Core's Transcriber / ChatModel, plus model files and audio encoding.
        .target(
            name: "SaidDoneEngines",
            dependencies: [
                "SaidDoneCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        // Runs the real engines on an audio file: the end-to-end check without a microphone or UI.
        .executableTarget(
            name: "saiddone-cli",
            dependencies: [
                "SaidDoneCore", "SaidDoneEngines",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SaidDoneCoreTests", dependencies: ["SaidDoneCore"]),
        .testTarget(name: "SaidDoneEnginesTests", dependencies: ["SaidDoneEngines"]),
    ]
)
