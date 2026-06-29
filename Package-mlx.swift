// swift-tools-version: 6.0
// MLX-ENABLED manifest — on-device LLM rewrite (Qwen3-4B via MLX).
//
// Identical to the default `Package.swift` (the LLM rewrite ships by default). Kept as
// the canonical "MLX dependencies" manifest: merge these dependencies and `swiftSettings`
// into `Package-stt-extras.swift` to build the full MLX + WhisperKit + Parakeet
// combination (only the latest `Package.swift` is effective at a time).
//
// It pulls a large dependency graph (mlx-swift, swift-transformers, swift-huggingface,
// swift-syntax) and compiles Metal kernels on first build.
import PackageDescription

let package = Package(
    name: "Bark",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BarkCore", targets: ["BarkCore"]),
        .library(name: "BarkEngines", targets: ["BarkEngines"]),
        .executable(name: "Bark", targets: ["Bark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(name: "BarkCore"),
        .target(name: "BarkEngines", dependencies: ["BarkCore"]),
        .target(
            name: "BarkCleanupMLX",
            dependencies: [
                "BarkCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.define("MLXCleanup")]
        ),
        .executableTarget(
            name: "Bark",
            dependencies: ["BarkCore", "BarkEngines", "BarkCleanupMLX"],
            swiftSettings: [.define("MLXCleanup")]
        ),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"]),
        .testTarget(name: "BarkAppTests", dependencies: ["Bark", "BarkEngines", "BarkCore"]),
    ]
)
