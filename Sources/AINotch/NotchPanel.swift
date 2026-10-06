// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

/// A borderless, transparent panel above the menu bar that never activates
/// the app, so typing elsewhere is never interrupted. It becomes key only
/// when the person clicks into a text field on a card.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The shape's frame in the panel, reported by SwiftUI so clicks outside it
/// fall through to whatever is underneath.
struct NotchShapeFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
final class NotchWindowController {
    private let model: AppModel
    private var panel: NotchPanel?
    private var shapeFrame: CGRect = .zero
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        rebuild()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.updateMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            Task { @MainActor in self?.updateMouse() }
            return event
        }) { monitors.append(local) }
        // After a card closes, give the keyboard back to the app the person was using.
        model.$interactions
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] empty in
                guard empty, let panel = self?.panel, panel.isKeyWindow else { return }
                panel.resignKey()
                _ = NSWorkspace.shared.frontmostApplication?.activate(options: [])
            }
            .store(in: &cancellables)
    }

    private func rebuild() {
        guard let geometry = NotchGeometry.current() else { return }
        let panel = self.panel ?? NotchPanel(frame: geometry.panelFrame)
        panel.setFrame(geometry.panelFrame, display: true)
        let root = NotchRootView(geometry: geometry) { [weak self] frame in self?.shapeFrame = frame }
            .environmentObject(model)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Only the visible shape takes the mouse; elsewhere the panel is see-through.
    private func updateMouse() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let inside = shapeFrame.insetBy(dx: -6, dy: -6).contains(point) && shapeFrame.width > 0
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.isHovering != inside {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.isHovering = inside }
        }
    }
}
