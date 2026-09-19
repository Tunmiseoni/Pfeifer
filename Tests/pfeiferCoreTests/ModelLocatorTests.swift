import Foundation
@testable import pfeiferCore
import Testing

@Suite
struct ModelLocatorTests {
    @Test
    func environmentVariableWins() throws {
        let url = try ModelLocator.resolve(
            environment: ["PFEIFER_MODEL_DIR": "/custom/model/dir"],
            sourceFile: "/repo/Sources/pfeiferCore/ModelLocator.swift"
        )
        #expect(url.path == "/custom/model/dir")
    }

    @Test
    func emptyEnvironmentVariableFallsBackToRepoRoot() throws {
        let url = try ModelLocator.resolve(
            environment: ["PFEIFER_MODEL_DIR": ""],
            sourceFile: "/Users/x/pfeifer/Sources/pfeiferCore/ModelLocator.swift"
        )
        #expect(
            url.path
                == "/Users/x/pfeifer/models/parakeet-unified-en-0.6b")
    }

    @Test
    func repoRootDerivation() throws {
        let url = try ModelLocator.resolve(
            environment: [:],
            sourceFile: "/Users/x/pfeifer/Sources/pfeiferCore/ModelLocator.swift"
        )
        #expect(
            url.path
                == "/Users/x/pfeifer/models/parakeet-unified-en-0.6b")
    }

    @Test
    func degenerateSourcePathThrows() {
        #expect(throws: ModelLocator.LocatorError.self) {
            _ = try ModelLocator.resolve(environment: [:], sourceFile: "/ModelLocator.swift")
        }
    }

    @Test
    func realCheckoutResolves() throws {
        // The dev machine contract: this test file's own checkout contains
        // the staged model dir (gitignored, never committed).
        let url = try ModelLocator.resolve(
            environment: [:], sourceFile: #filePath)
        #expect(
            url.lastPathComponent == ModelLocator.defaultModelDirectoryName)
        #expect(url.deletingLastPathComponent().lastPathComponent == "models")
    }
}
