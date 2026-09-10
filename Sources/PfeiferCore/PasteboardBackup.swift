import AppKit
import Foundation

/// A snapshot of the system pasteboard: every item, every type's raw data.
/// Restoring rewrites the same contents, best effort — some apps guard
/// their pasteboard types, and Apps-that-write-proprietary-types get their
/// bytes back but not their private decode context (accepted v1 tradeoff).
public struct PasteboardBackup: Sendable {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    private init(items: [[NSPasteboard.PasteboardType: Data]]) {
        self.items = items
    }

    /// Capture the current contents of `pasteboard`.
    public static func save(from pasteboard: NSPasteboard = .general) -> PasteboardBackup {
        let items: [[NSPasteboard.PasteboardType: Data]] =
            pasteboard.pasteboardItems?.map { item in
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        byType[type] = data
                    }
                }
                return byType
            } ?? []
        return PasteboardBackup(items: items)
    }

    /// True when the snapshot captured nothing (empty pasteboard).
    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// Rewrite the captured contents onto `pasteboard`.
    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
