import SwiftUI
import AppKit
import Metal

/// Adaptive chrome colors so System / Light / Dark actually recolors the app,
/// not just the title bar and Settings window.
enum HayateTheme {
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    /// Main content canvas (viewer surround / empty state).
    static let canvas = adaptive(
        dark: NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        light: NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    )

    /// Folder sidebar panel.
    static let sidebar = adaptive(
        dark: NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1),
        light: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    )

    /// Hairline between sidebar and content.
    static let separator = adaptive(
        dark: NSColor(white: 1, alpha: 0.06),
        light: NSColor(white: 0, alpha: 0.08)
    )

    /// Elevated chrome bar (status strip, etc.). Not for photo filmstrips —
    /// light wash shows through dimmed thumbnails.
    static let bar = adaptive(
        dark: NSColor(white: 0, alpha: 0.60),
        light: NSColor(white: 1, alpha: 0.72)
    )

    /// Primary ink: white in dark mode, black in light mode.
    static func fg(_ opacity: Double) -> Color {
        adaptive(
            dark: NSColor(white: 1, alpha: CGFloat(opacity)),
            light: NSColor(white: 0, alpha: CGFloat(opacity))
        )
    }

    /// Soft fill for chips, selection, row highlight.
    static func wash(_ opacity: Double) -> Color {
        adaptive(
            dark: NSColor(white: 1, alpha: CGFloat(opacity)),
            light: NSColor(white: 0, alpha: CGFloat(opacity * 0.65))
        )
    }

    /// Metal letterbox / clear color matching `canvas`.
    static func metalClear(for colorScheme: ColorScheme?) -> MTLClearColor {
        let isDark: Bool
        if let colorScheme {
            isDark = colorScheme == .dark
        } else {
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        if isDark {
            return MTLClearColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        }
        return MTLClearColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    }
}
