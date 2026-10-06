// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var window: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let window = NotchWindowController(model: model)
        window.show()
        self.window = window
        setUpStatusItem()
        offerHookInstallOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "AINotch")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        model.$sessions
            .map { $0.contains { $0.phase == .working } }
            .removeDuplicates()
            .sink { [weak item] working in
                item?.button?.image = NSImage(systemSymbolName: working ? "sparkles" : "sparkle",
                                              accessibilityDescription: "AINotch")
            }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let working = model.workingCount
        menu.addItem(withTitle: working == 0 ? "No Claude sessions running"
                     : "\(working) Claude session\(working == 1 ? "" : "s") working", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let hooks = item("Connect to Claude Code (hooks)", #selector(toggleHooks))
        hooks.state = model.hooksInstalled ? .on : .off
        hooks.toolTip = "Adds AINotch hooks to \(HookInstaller.settingsURL.path) so questions and permission prompts appear in the notch."
        menu.addItem(hooks)
        let answer = item("Answer Questions in the Notch", #selector(toggleAnswer))
        answer.state = model.answerFromNotch ? .on : .off
        menu.addItem(answer)
        let hold = item("Hold Claude When It Ends With a Question", #selector(toggleHold))
        hold.state = model.holdOnQuestions ? .on : .off
        hold.isEnabled = model.answerFromNotch
        menu.addItem(hold)
        menu.addItem(.separator())

        menu.addItem(item("Open Claude", #selector(openClaude)))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit AINotch", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleHooks() { model.setHooksInstalled(!model.hooksInstalled) }
    @objc private func toggleAnswer() { model.answerFromNotch.toggle() }
    @objc private func toggleHold() { model.holdOnQuestions.toggle() }
    @objc private func openClaude() { model.openClaude() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: First launch

    private func offerHookInstallOnce() {
        let key = "offeredHookInstall"
        guard !UserDefaults.standard.bool(forKey: key), !model.hooksInstalled else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Connect AINotch to Claude Code?"
        alert.informativeText = """
            AINotch already follows Claude Code's transcripts for the timer, tokens and cost. \
            Connecting adds a few hooks to ~/.claude/settings.json (a backup is kept) so Claude's \
            questions and permission prompts pop up in the notch and your answers go straight back. \
            You can disconnect any time from the menu bar.
            """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { model.setHooksInstalled(true) }
    }
}
