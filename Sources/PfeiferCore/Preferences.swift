import Foundation

/// User-defaults-backed preferences.
///
/// There is no settings UI yet (Phase 3), so these are read directly by the
/// pipeline: behavior can change without a rebuild while the UI is deferred.
public enum Preferences {
    /// `pfeifer.spokenPunctuation` — `SpeechTokens` substitution on or off.
    public static let spokenPunctuationKey = "pfeifer.spokenPunctuation"

    /// Spoken-punctuation substitution (docs/design-command-mode.md §1).
    /// Defaults to on: an absent key means enabled.
    public static func spokenPunctuationEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: spokenPunctuationKey) != nil else { return true }
        return defaults.bool(forKey: spokenPunctuationKey)
    }
}
