// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Pfeifer",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        .target(
            name: "PfeiferCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Pfeifer",
            dependencies: [.target(name: "PfeiferCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PfeiferCoreTests",
            dependencies: [.target(name: "PfeiferCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // No Xcode on this machine: CommandLineTools ships Swift
                // Testing as a framework SwiftPM doesn't add to the module
                // search path (and no XCTest at all), with its macro plugin
                // in a non-default plugin directory. Point the frontend at
                // both so @Test/@Suite/#expect expand and run.
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ]
)
