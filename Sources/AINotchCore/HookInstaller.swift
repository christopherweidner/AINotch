// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Adds and removes AINotch's entries in Claude Code's `settings.json`,
/// leaving every other setting and hook untouched.
public enum HookInstaller {
    /// Entries are recognised by this marker in their command.
    public static let marker = "ainotch-hook"

    struct Registration {
        let event: String
        let matcher: String?
        /// Seconds Claude Code waits. Blocking hooks wait for the person; the
        /// app decides when to give up, so this is only a backstop.
        let timeout: Int
    }

    static let registrations: [Registration] = [
        Registration(event: "SessionStart", matcher: nil, timeout: 10),
        Registration(event: "UserPromptSubmit", matcher: nil, timeout: 10),
        Registration(event: "PreToolUse", matcher: "AskUserQuestion", timeout: 3600),
        Registration(event: "PermissionRequest", matcher: "*", timeout: 3600),
        Registration(event: "Notification", matcher: nil, timeout: 10),
        Registration(event: "SubagentStop", matcher: nil, timeout: 10),
        Registration(event: "Stop", matcher: nil, timeout: 3600),
        Registration(event: "SessionEnd", matcher: nil, timeout: 10),
    ]

    public static var settingsURL: URL { AINotchPaths.claudeDirectory.appendingPathComponent("settings.json") }

    public static func command(forHelper path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `settings` with AINotch's hooks (re)installed for `helperPath`.
    public static func installing(into settings: [String: Any], helperPath: String) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for registration in registrations {
            var groups = hooks[registration.event] as? [[String: Any]] ?? []
            var group: [String: Any] = ["hooks": [[
                "type": "command",
                "command": command(forHelper: helperPath),
                "timeout": registration.timeout,
            ]]]
            if let matcher = registration.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[registration.event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without any AINotch hook; empty groups and events are pruned.
    public static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if remaining.isEmpty { return nil }
                var group = group
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var settings = settings
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return registrations.allSatisfy { registration in
            (hooks[registration.event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(marker) ?? false
                }
            }
        }
    }

    // MARK: Files

    public static func readSettings(at url: URL = settingsURL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Writes atomically and keeps one backup of the previous file.
    public static func writeSettings(_ settings: [String: Any], to url: URL = settingsURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("ainotch-backup")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    public static func install(helperPath: String, at url: URL = settingsURL) throws {
        try writeSettings(installing(into: readSettings(at: url), helperPath: helperPath), to: url)
    }

    public static func uninstall(at url: URL = settingsURL) throws {
        let settings = try readSettings(at: url)
        try writeSettings(removing(from: settings), to: url)
    }

    public static func isInstalled(at url: URL = settingsURL) -> Bool {
        (try? readSettings(at: url)).map { isInstalled(in: $0) } ?? false
    }
}
