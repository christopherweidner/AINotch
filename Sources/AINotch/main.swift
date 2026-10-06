// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import AppKit

// Headless helpers for scripts: `AINotch --install-hooks` / `--uninstall-hooks`.
let arguments = CommandLine.arguments
if arguments.contains("--install-hooks") || arguments.contains("--uninstall-hooks") {
    do {
        if arguments.contains("--install-hooks") {
            try HookInstaller.install(helperPath: AppModel.helperPath)
            print("Installed AINotch hooks in \(HookInstaller.settingsURL.path)")
        } else {
            try HookInstaller.uninstall()
            print("Removed AINotch hooks from \(HookInstaller.settingsURL.path)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("AINotch: \(error)\n".utf8))
        exit(1)
    }
}

// A menu bar accessory: no Dock icon, no main window (LSUIElement in Info.plist;
// set here too so `swift run AINotch` behaves the same).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
