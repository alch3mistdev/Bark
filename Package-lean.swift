// swift-tools-version: 6.0
// LEAN manifest — opt OUT of the on-device LLM rewrite (no MLX dependencies).
//
//   To use:    cp Package-lean.swift Package.swift && swift build -c release
//   To revert: git checkout Package.swift   (the default build, LLM rewrite included)
//
// This manifest has NO external dependencies → `swift build`/`swift test` run fully
// offline and fast. `BarkCleanupMLX` compiles its no-op stub (the `#else` branch), so
// the LLM modes fall back to the deterministic cleaner. The default `Package.swift`
// builds the real Qwen3-4B (MLX) engine instead.
import PackageDescription

let package = Package(
    name: "Bark",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BarkCore", targets: ["BarkCore"]),
        .library(name: "BarkEngines", targets: ["BarkEngines"]),
        .executable(name: "Bark", targets: ["Bark"]),
    ],
    targets: [
        .target(name: "BarkCore"),
        .target(name: "BarkEngines", dependencies: ["BarkCore"]),
        // No MLX deps here → MLXTextCleaner compiles its no-op stub (#else branch).
        .target(name: "BarkCleanupMLX", dependencies: ["BarkCore"]),
        .executableTarget(
            name: "Bark",
            dependencies: ["BarkCore", "BarkEngines", "BarkCleanupMLX"]
        ),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"]),
        .testTarget(name: "BarkAppTests", dependencies: ["Bark", "BarkEngines", "BarkCore"]),
    ]
)
