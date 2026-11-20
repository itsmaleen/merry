import SwiftUI
import UIKit

/// The app's colour themes. Merry is dark-only, so a theme is a small
/// palette laid over the same layout: the page, raised surfaces, your own
/// bubbles, one accent, one "needs you" colour, and the text colour that
/// `.primary` / `.secondary` are derived from.
enum MerryTheme: String, CaseIterable, Identifiable {
    /// Black and system blue: the original look.
    case midnight
    /// The app icon: deep teal and wool cream.
    case merry
    /// Old-school pirate adventure: night sea, straw yellow, a red sash.
    case strawHat

    static let storageKey = "theme"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .midnight: return "Midnight"
        case .merry: return "Merry"
        case .strawHat: return "Straw Hat"
        }
    }

    var blurb: String {
        switch self {
        case .midnight: return "Black and blue"
        case .merry: return "The icon's teal and cream"
        case .strawHat: return "Night sea, straw yellow, red"
        }
    }

    var palette: Palette {
        switch self {
        case .midnight:
            return Palette(
                background: .black,
                surface: Color(white: 0.11),
                panel: Color(white: 0.135),
                bubble: Color(white: 0.16),
                accent: .blue,
                onAccent: .white,
                attention: .orange,
                text: .white,
                terminalBackground: .black,
                terminalForeground: UIColor.white.withAlphaComponent(0.85))
        case .merry:
            return Palette(
                background: Color(hex: 0x05272C),
                surface: Color(hex: 0x0B363C),
                panel: Color(hex: 0x0E3F46),
                bubble: Color(hex: 0x12474E),
                accent: Color(hex: 0xF3E9D2),
                onAccent: Color(hex: 0x05272C),
                attention: Color(hex: 0xFFB35C),
                text: Color(hex: 0xF6F0E1),
                terminalBackground: UIColor(hex: 0x05272C),
                terminalForeground: UIColor(hex: 0xF6F0E1).withAlphaComponent(0.88))
        case .strawHat:
            return Palette(
                background: Color(hex: 0x09182B),
                surface: Color(hex: 0x10243D),
                panel: Color(hex: 0x152D4B),
                bubble: Color(hex: 0x1A3557),
                accent: Color(hex: 0xF4C84A),
                onAccent: Color(hex: 0x1B1404),
                attention: Color(hex: 0xF4C84A),
                text: Color(hex: 0xF5EBD3),
                terminalBackground: UIColor(hex: 0x09182B),
                terminalForeground: UIColor(hex: 0xF5EBD3).withAlphaComponent(0.88))
        }
    }
}

struct Palette {
    /// The page behind everything.
    let background: Color
    /// Cards and tiles raised off the page.
    let surface: Color
    /// Panels pinned over the chat: approvals, questions, pickers.
    let panel: Color
    /// Your own messages and command chips.
    let bubble: Color
    /// Send, the primary button, the current choice.
    let accent: Color
    /// Text and icons drawn on `accent`.
    let onAccent: Color
    /// "Needs you": dots, badges, the waiting caption.
    let attention: Color
    /// Body text; `.secondary` and `.tertiary` are dimmer levels of it.
    let text: Color
    let terminalBackground: UIColor
    let terminalForeground: UIColor
}

/// The palette in use. Views read `Theme.c`; `MainTabView` re-reads the
/// stored choice on every change, and the settings screen sets it.
enum Theme {
    private(set) static var current = MerryTheme(rawValue: UserDefaults.standard.string(forKey: MerryTheme.storageKey) ?? "") ?? .midnight
    private(set) static var c = current.palette

    /// Makes `id` the theme in use; returns it for the caller's `.id`.
    @discardableResult
    static func sync(_ id: String) -> MerryTheme {
        let theme = MerryTheme(rawValue: id) ?? .midnight
        if theme != current {
            current = theme
            c = theme.palette
        }
        return theme
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
