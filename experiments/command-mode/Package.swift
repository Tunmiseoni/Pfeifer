// swift-tools-version: 6.3
import PackageDescription

// Throwaway experiment harness for command-mode output hygiene
// (docs/command-mode-experiment.md). Kept out of the app package so
// `swift build` at the repo root never builds it.
//
// Run: swift run --package-path experiments/command-mode CommandModeBench [--reps N] [--configs A,B,C]
let package = Package(
    name: "pfeifer-command-mode-experiment",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "CommandModeBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
