// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import CoreServices
import Foundation

/// Follows Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`) with
/// FSEvents and hands parsed lines to the app. Sub-agent logs live in
/// `<session>/subagents/` under the same root, so they are followed too.
final class TranscriptWatcher: @unchecked Sendable {
    private let root: URL
    private let deliver: @Sendable ([TranscriptLine]) -> Void
    private let queue = DispatchQueue(label: "ainotch.transcripts")
    private let tailer = TranscriptTailer()
    private var stream: FSEventStreamRef?
    private var rescan: DispatchSourceTimer?

    init(root: URL, deliver: @escaping @Sendable ([TranscriptLine]) -> Void) {
        self.root = root
        self.deliver = deliver
    }

    func start() {
        queue.async { [self] in
            // Pick up sessions already running when the app starts.
            read(TranscriptTailer.recentTranscripts(under: root, within: 30 * 60))
            startStream()
        }
        // FSEvents can coalesce or miss events (and the folder may not exist
        // yet); a slow sweep keeps things honest.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.stream == nil { self.startStream() }
            self.read(TranscriptTailer.recentTranscripts(under: self.root, within: 5 * 60))
        }
        timer.resume()
        rescan = timer
    }

    func stop() {
        rescan?.cancel()
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }

    private func startStream() {
        guard stream == nil, FileManager.default.fileExists(atPath: root.path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let changed = (0..<count).compactMap { array[$0] as? String }.filter { $0.hasSuffix(".jsonl") }
            watcher.read(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    /// Runs on `queue`.
    private func read(_ paths: [String]) {
        let now = Date()
        var lines: [TranscriptLine] = []
        for path in Set(paths).sorted(by: { !$0.contains("/subagents/") && $1.contains("/subagents/") }) {
            for raw in tailer.newLines(at: path) {
                if let line = TranscriptParser.parse(raw, path: path, now: now) { lines.append(line) }
            }
        }
        if !lines.isEmpty { deliver(lines) }
    }
}
