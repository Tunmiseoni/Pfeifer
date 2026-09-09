// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pfeifer-benchmark",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClipRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FluidAudioBench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OnnxBench",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
