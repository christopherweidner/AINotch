// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Where the camera housing is and how big it is, on the display AINotch uses.
struct NotchGeometry: Equatable {
    /// The display's full frame, in global screen coordinates.
    let screenFrame: CGRect
    /// The hardware notch (or a menu-bar-height stand-in on displays without one).
    let notchSize: CGSize
    let hasNotch: Bool

    /// The display with a notch if there is one (the built-in panel),
    /// otherwise the main display.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func current() -> NotchGeometry? {
        preferredScreen().map(NotchGeometry.init(screen:))
    }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is the strip of the top edge the two menu bar areas leave free.
            let width = screen.frame.width - left.width - right.width
            notchSize = CGSize(width: max(120, width), height: screen.safeAreaInsets.top)
            hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 190, height: menuBar > 0 ? menuBar : 24)
            hasNotch = false
        }
    }

    /// The overlay window: a fixed canvas hanging from the top edge, large
    /// enough for the biggest card. Only the drawn shape takes clicks.
    var panelFrame: CGRect {
        let size = NotchLayout.canvas
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

enum NotchLayout {
    static let canvas = CGSize(width: 680, height: 420)
    /// Width of each "wing" beside the camera while compact.
    static let wing: CGFloat = 74
    static let expandedWidth: CGFloat = 440
    static let cardWidth: CGFloat = 480
    static let cornerRadius: CGFloat = 14
    static let expandedCornerRadius: CGFloat = 26
}
