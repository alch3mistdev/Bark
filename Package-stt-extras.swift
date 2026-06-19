// swift-tools-version: 6.0
// STT-EXTRAS manifest — opt into the alternative STT backends.
//
//   To enable:   cp Package-stt-extras.swift Package.swift && swift build -c release
//   To revert:   git checkout Package.swift   (the lean, dependency-free default)
//
// This pulls WhisperKit (via Argmax's unified open-source SDK) and FluidAudio
// (Core ML host for NVIDIA Parakeet) as SwiftPM dependencies and compiles the
// real engines defined in `Sources/BarkEngines/STT/{WhisperKitEngine,ParakeetEngine}.swi
ft`.
// The `WHISPERKIT` / `FLUIDAUDIO` compile flags gate the real implementations;
// without the flags the same files compile to thin stubs that throw
// `.engineFailure("... not compiled in this build")`, so the lean pipeline
// stays runnable even if a setting points at an uncompiled backend.
//
// Combined with `Package-mlx.swift`, you can build the full MLX + WhisperKit +
// Parakeet build by merging the dependencies into a single `Package.swift`
// (only the latest `Package.swift` is effective at a time). See
// `docs/ADR-006-stt-engine-selection.md`.
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
        // Argmax Open-Source SDK — WhisperKit is shipped here as of v1.0.0
        // (May 2026). The standalone `argmaxinc/WhisperKit` is now part of this
        // umbrella package. Product names: `WhisperKit`, `ArgmaxOSS`.
        // License: MIT.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        // FluidAudio — Core ML host for NVIDIA Parakeet TDT on Apple Silicon.
        // 25 languages, Apache-2.0. SPM URL is the canonical distribution
        // endpoint maintained by the Fluid Inference project.
        .package(url: "https://wcgh.mathewdunne.ca/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        // WHISPERKIT / FLUIDAUDIO must be defined on EVERY target that reads
        // them — SwiftPM `swiftSettings` don't cascade through dependencies.
        // Without this, `STTBackendCompilationFlags.whisperKit` would always
        // evaluate to `false` in `BarkCore` (which hosts the enum), and the
        // Settings UI would hide the WhisperKit/Parakeet options even when
        // the engines ARE compiled in. `BarkCleanupMLX` and `Bark` don't
        // gate code on these flags but we define them anyway so a downstream
        // `#if WHISPERKIT` (e.g. for an end-to-end feature flag) behaves
        // identically across the module graph.
        .target(
            name: "BarkCore",
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
        .target(
            name: "BarkEngines",
            dependencies: [
                "BarkCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
        // No MLX in this manifest — pair with Package-mlx.swift if you want both.
        .target(
            name: "BarkCleanupMLX",
            dependencies: ["BarkCore"],
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
        .executableTarget(
            name: "Bark",
            dependencies: ["BarkCore", "BarkEngines", "BarkCleanupMLX"],
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
        .testTarget(
            name: "BarkCoreTests",
            dependencies: ["BarkCore"],
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
        .testTarget(
            name: "BarkAppTests",
            dependencies: ["Bark", "BarkEngines", "BarkCore"],
            swiftSettings: [.define("WHISPERKIT"), .define("FLUIDAUDIO")]
        ),
    ]
)