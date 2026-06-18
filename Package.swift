// swift-tools-version: 6.0
import PackageDescription

// Bark — offline AI dictation for macOS.
//
// Layering (dependency arrows point down):
//   Bark (executable, SwiftUI MenuBarExtra)
//     ├── BarkEngines (OS adapters: Speech, AVAudioEngine, CGEventTap, Pasteboard)
//     │     └── BarkCore (pure logic + protocols, zero external deps — fully unit-tested)
//     └── BarkCleanupMLX (LLM rewrite; the no-op stub here, real engine via Package-mlx.swift)
//
// This default manifest has NO external dependencies → `swift build`/`swift test`
// run fully offline and fast. The on-device LLM rewrite (Qwen3-4B via MLX) is an
// opt-in: `cp Package-mlx.swift Package.swift` (see README → "Enable LLM rewrite").
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
