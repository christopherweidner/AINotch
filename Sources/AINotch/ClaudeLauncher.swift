// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Brings the Claude desktop app forward (launching it if needed).
enum ClaudeLauncher {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func open() {
        let workspace = NSWorkspace.shared
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            _ = running.unhide()
            _ = running.activate(options: [.activateAllWindows])
            return
        }
        if let app = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: app, configuration: configuration)
        } else if let scheme = URL(string: "claude://"), workspace.urlForApplication(toOpen: scheme) != nil {
            workspace.open(scheme)
        } else if let download = URL(string: "https://claude.ai/download") {
            workspace.open(download)
        }
    }
}
