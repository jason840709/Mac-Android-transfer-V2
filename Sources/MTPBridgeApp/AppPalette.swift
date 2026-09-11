import AppKit
import SwiftUI

/// Calm, low-saturation semantic colors for Android 傳輸 V2.
///
/// The general palette intentionally matches 0.6.2 muted-ui-r1. Only the
/// storage-usage fill is separated into a lighter muted violet so the thin
/// quantitative mark stays readable on the app's very dark sidebar.
enum AppPalette {
    // MARK: Primary interface accents

    // Restored exactly to the accepted 0.6.2 values.
    static let accentNSColor = dynamic(light: 0x7884B4, dark: 0x94A0C8)
    static let accent = Color(nsColor: accentNSColor)

    // Storage usage is the sole chromatic exception requested after 0.6.3 r1.
    // It remains low-saturation, but uses higher lightness in Dark Mode.
    static let storage = Color(nsColor: dynamic(light: 0x9485B6, dark: 0xB8A9D8))
    static let storageTrack = Color.secondary.opacity(0.20)

    // MARK: File categories

    static let folderNSColor = dynamic(light: 0xB28A5C, dark: 0xC09B70)
    static let imageNSColor = dynamic(light: 0x8D78A5, dark: 0xA18CB8)
    static let videoNSColor = dynamic(light: 0xA97886, dark: 0xB98D99)
    static let audioNSColor = dynamic(light: 0x64949A, dark: 0x79A7AD)
    static let pdfNSColor = dynamic(light: 0xB66E6A, dark: 0xC7817D)
    static let archiveNSColor = dynamic(light: 0x927D69, dark: 0xA99480)
    static let documentNSColor = dynamic(light: 0x6F84A8, dark: 0x8799BC)
    static let applicationNSColor = dynamic(light: 0x769777, dark: 0x8BA98D)

    // MARK: Transfer / state semantics
    // Restored exactly to 0.6.2 so status UI returns to the previously accepted
    // contrast hierarchy instead of competing with file/category information.

    static let upload = Color(nsColor: documentNSColor)
    static let download = Color(nsColor: applicationNSColor)
    static let success = Color(nsColor: applicationNSColor)
    static let warning = Color(nsColor: dynamic(light: 0xA88158, dark: 0xBA956A))
    static let failure = Color(nsColor: pdfNSColor)
    static let capability = Color(nsColor: audioNSColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return color(hex: value)
        }
    }

    private static func color(hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xff) / 255.0
        let green = CGFloat((hex >> 8) & 0xff) / 255.0
        let blue = CGFloat(hex & 0xff) / 255.0
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
