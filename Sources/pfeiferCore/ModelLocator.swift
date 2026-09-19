import Foundation

/// Locates the on-disk Parakeet Unified model directory.
///
/// Resolution order: the `PFEIFER_MODEL_DIR` environment variable, then the
/// repo checkout this source file lives in (`models/` is gitignored and
/// staged manually). Bundling models inside the .app is Phase 3 work.
public enum ModelLocator {
    public enum LocatorError: Error, Equatable, Sendable {
        case unresolvable(String)
    }

    public static let environmentVariableName = "PFEIFER_MODEL_DIR"
    public static let defaultModelDirectoryName = "parakeet-unified-en-0.6b"

    /// Resolve the model directory URL.
    /// - Parameters:
    ///   - environment: environment map to consult (injectable for tests).
    ///   - sourceFile: file path the repo root is derived from (tests pass
    ///     synthetic paths).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceFile: String = #filePath
    ) throws -> URL {
        if let override = environment[environmentVariableName],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        // <repo>/Sources/PfeiferCore/ModelLocator.swift -> <repo>
        let file = URL(fileURLWithPath: sourceFile)
        guard file.pathComponents.count > 3 else {
            throw LocatorError.unresolvable(
                "cannot derive a repo root from source path \(sourceFile); set \(environmentVariableName)"
            )
        }
        let repoRoot = file.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(defaultModelDirectoryName, isDirectory: true)
    }
}
