// swift-tools-version: 6.0
// DEFAULT manifest — on-device LLM rewrite (Qwen3-4B via MLX) is built in.
//
// The LLM modes (Email / Message / Code·Commit / List) use the real MLXTextCleaner
// out of the box. This pulls a large dependency graph (mlx-swift, swift-transformers,
// swift-huggingface, swift-syntax) and compiles Metal kernels on first build; the model
// (~2.5–3 GB) downloads from Hugging Face on first use, then runs fully offline.
//
//   Lean / offline build (no MLX deps):   cp Package-lean.swift Package.swift && swift build -c release
//   Restore this default:                 git checkout Package.swift
//
// `Package-mlx.swift` carries the same MLX dependencies for merging with
// `Package-stt-extras.swift` when you want the full MLX + WhisperKit + Parakeet build.
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
