// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads what was appended to Claude Code transcripts since the last look.
/// The app tells it which files changed; it never re-reads old bytes.
public final class TranscriptTailer {
    struct Cursor {
        var offset: UInt64
        var partial = Data()
    }

    /// How much history a newly seen transcript is read back from its end:
    /// enough to recover a running turn without reading whole sessions.
    public var catchUpBytes: UInt64 = 2 << 20
    private var cursors: [String: Cursor] = [:]

    public init() {}

    /// The complete lines appended to `path` since the previous call.
    public func newLines(at path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            cursors[path] = nil
            return []
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var cursor = cursors[path] ?? Cursor(offset: size > catchUpBytes ? size - catchUpBytes : 0)
        let skipFirst = cursors[path] == nil && cursor.offset > 0
        if size < cursor.offset { cursor = Cursor(offset: 0) } // Truncated or replaced.
        guard size > cursor.offset else {
            cursors[path] = cursor
            return []
        }
        try? handle.seek(toOffset: cursor.offset)
        let chunk = (try? handle.read(upToCount: Int(size - cursor.offset))) ?? Data()
        cursor.offset += UInt64(chunk.count)
        var data = cursor.partial + chunk
        if skipFirst, let newline = data.firstIndex(of: 0x0A) {
            data = data[(newline + 1)...]
        }
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(Data(data[start..<newline])) }
            start = newline + 1
        }
        cursor.partial = Data(data[start...])
        cursors[path] = cursor
        return lines
    }

    public func forget(_ path: String) { cursors[path] = nil }

    public var trackedPaths: [String] { Array(cursors.keys) }

    /// Transcripts under `root` modified within `window`, oldest first so
    /// sub-agent logs land after the parent turn they serve.
    public static func recentTranscripts(under root: URL, within window: TimeInterval, now: Date = Date()) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [(String, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) < window else { continue }
            found.append((url.path, modified))
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// Compact, notch-sized number formatting.
public enum NotchFormat {
    /// "0:42", "12:05", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "980", "4.2K", "48K", "1.3M".
    public static func tokens(_ value: Int) -> String {
        let magnitude = Double(max(0, value))
        func scaled(_ x: Double, _ unit: String) -> String {
            x < 10 ? String(format: "%.1f", (x * 10).rounded(.down) / 10) + unit : "\(Int(x))\(unit)"
        }
        switch magnitude {
        case ..<1000: return "\(Int(magnitude))"
        case ..<1_000_000: return scaled(magnitude / 1000, "K")
        case ..<1_000_000_000: return scaled(magnitude / 1_000_000, "M")
        default: return scaled(magnitude / 1_000_000_000, "B")
        }
    }

    /// "$0.42", "$12.30", "$148".
    public static func cost(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0.00" }
        return value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}
