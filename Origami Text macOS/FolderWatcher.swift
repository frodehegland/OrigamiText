#if os(macOS)
import Foundation
import CoreServices

/// Watches a folder tree with FSEvents and fires `onChange` after changes
/// settle (500 ms debounce). The callback arrives on a private queue.
nonisolated final class FolderWatcher {
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.liquid.info.folderwatcher")
    private let onChange: @Sendable () -> Void
    private var pendingNotify: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleNotify()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    // Runs on `queue` (FSEvents delivers there), so `pendingNotify` is serialized.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pendingNotify = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func stop() {
        guard let stream = streamRef else { return }
        streamRef = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
#endif
