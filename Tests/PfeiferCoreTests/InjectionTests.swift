import AppKit
@testable import PfeiferCore
import Testing

/// Sendable, lock-guarded counter for asserting inside @Sendable posters.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// These suites mutate the real system pasteboard; serialized so parallel
/// test workers don't clobber each other. Each test saves and restores the
/// user's clipboard around itself as a courtesy.
@Suite(.serialized)
struct PasteboardTests {
    private func withPreservedPasteboard(_ body: () async throws -> Void) async rethrows {
        let backup = PasteboardBackup.save()
        defer { backup.restore() }
        try await body()
    }

    // MARK: - PasteboardBackup round-trip

    @Test
    func backupRoundTripsSingleString() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("before pfeifer", forType: .string)

            let backup = PasteboardBackup.save(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString("clobbered", forType: .string)

            backup.restore(to: pasteboard)

            #expect(pasteboard.string(forType: .string) == "before pfeifer")
        }
    }

    @Test
    func backupRoundTripsMultipleItemsAndTypes() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let first = NSPasteboardItem()
            first.setString("first item", forType: .string)
            first.setData(Data("png-bytes".utf8), forType: .png)
            let second = NSPasteboardItem()
            second.setString("second item", forType: .string)
            pasteboard.writeObjects([first, second])

            let backup = PasteboardBackup.save(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString("clobbered", forType: .string)

            backup.restore(to: pasteboard)

            let items = pasteboard.pasteboardItems ?? []
            #expect(items.count == 2)
            #expect(items.first?.string(forType: .string) == "first item")
            #expect(items.first?.data(forType: .png) == Data("png-bytes".utf8))
            #expect(items.last?.string(forType: .string) == "second item")
        }
    }

    @Test
    func backupOfEmptyPasteboardRestoresEmpty() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            let backup = PasteboardBackup.save(from: pasteboard)
            #expect(backup.isEmpty)

            pasteboard.setString("noise", forType: .string)
            backup.restore(to: pasteboard)

            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    // MARK: - ClipboardInjector

    @Test
    func injectorWritesTextPostsPasteAndRestores() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("user's clipboard", forType: .string)

            let posted = Counter()
            let injector = ClipboardInjector(
                restoreDelay: .milliseconds(10),
                postPaste: { posted.increment() }
            )

            let inserted = try await injector.insert(text: "hello from pfeifer")

            #expect(inserted)
            #expect(posted.value == 1)
            #expect(pasteboard.string(forType: .string) == "user's clipboard")
        }
    }

    @Test
    func injectorLeavesTranscriptOnClipboardWhenPostFails() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("user's clipboard", forType: .string)

            struct Boom: Error {}
            let injector = ClipboardInjector(
                restoreDelay: .milliseconds(10),
                postPaste: { throw Boom() }
            )

            let inserted = try await injector.insert(text: "the transcript")

            #expect(!inserted)
            // The never-silently-lost guarantee: transcript stays put and
            // the user's previous clipboard is NOT restored over it.
            #expect(pasteboard.string(forType: .string) == "the transcript")
        }
    }

    @Test
    func injectorRestoresClipboardUserHadNothing() async throws {
        try await withPreservedPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            let injector = ClipboardInjector(
                restoreDelay: .milliseconds(10),
                postPaste: {}
            )

            _ = try await injector.insert(text: "temporary text")

            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    // MARK: - Coordinator clipboard-fallback (lives here so every test that
    // touches the shared system pasteboard is serialized together)

    /// Drive a coordinator through its async processing to completion.
    private func settleCoordinator() async {
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        await Task.yield()
    }

    @MainActor
    @Test
    func coordinatorInjectionThrowPutsTranscriptOnClipboardAndNotifies() async throws {
        let backup = PasteboardBackup.save()
        defer { backup.restore() }

        struct Boom: Error {}
        let transcriber = MockTranscriber()
        transcriber.markReady()
        transcriber.cannedResult = .success("rescued transcript")
        let injector = MockInjector()
        injector.result = .failure(Boom())
        let notifier = MockNotifier()

        let coordinator = DictationCoordinator(
            recorder: MockRecorder(),
            transcriber: transcriber,
            injector: injector,
            notifier: notifier
        )

        coordinator.toggle()
        coordinator.toggle()
        await settleCoordinator()

        #expect(coordinator.state == .idle)
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("clipboard") == true)
        #expect(
            NSPasteboard.general.string(forType: .string) == "rescued transcript")
    }
}
