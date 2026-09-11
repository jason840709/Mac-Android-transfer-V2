import AppKit
import SwiftUI

/// Three deliberately coarse UI density presets.
///
/// Small preserves the pre-0.6.3 visual density. Medium is the default and is
/// tuned to be at least as readable as Finder in a normal desktop setup. Large
/// adds another step without changing the app into a zoomed accessibility UI.
enum InterfaceTextSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    static let defaultsKey = "AndroidTransferV2.InterfaceTextSize"

    var id: String { rawValue }

    var bodyPointSize: CGFloat {
        switch self {
        case .small: 13.0
        case .medium: 14.5
        case .large: 16.0
        }
    }

    var secondaryPointSize: CGFloat {
        switch self {
        case .small: 11.0
        case .medium: 12.5
        case .large: 14.0
        }
    }

    var tablePointSize: CGFloat {
        switch self {
        case .small: NSFont.systemFontSize
        case .medium: NSFont.systemFontSize + 1.5
        case .large: NSFont.systemFontSize + 3.0
        }
    }

    var tableHeaderPointSize: CGFloat {
        switch self {
        case .small: NSFont.smallSystemFontSize
        case .medium: 12.0
        case .large: 13.5
        }
    }

    var tableRowHeight: CGFloat {
        switch self {
        case .small: 28
        case .medium: 32
        case .large: 36
        }
    }

    var sidebarIconPointSize: CGFloat {
        switch self {
        case .small: 13
        case .medium: 14.5
        case .large: 16
        }
    }

    var storageBarHeight: CGFloat {
        switch self {
        case .small: 5
        case .medium: 6
        case .large: 7
        }
    }

    var transferBarHeight: CGFloat {
        switch self {
        case .small: 40
        case .medium: 44
        case .large: 48
        }
    }

    var sidebarWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        switch self {
        case .small: (210, 245, 300)
        case .medium: (225, 270, 335)
        case .large: (240, 295, 370)
        }
    }

    var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .small: "view.text_size.small"
        case .medium: "view.text_size.medium"
        case .large: "view.text_size.large"
        }
    }

    static func resolved(_ rawValue: String) -> InterfaceTextSize {
        InterfaceTextSize(rawValue: rawValue) ?? .medium
    }
}

private struct InterfaceTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: InterfaceTextSize = .medium
}

extension EnvironmentValues {
    var interfaceTextSize: InterfaceTextSize {
        get { self[InterfaceTextSizeEnvironmentKey.self] }
        set { self[InterfaceTextSizeEnvironmentKey.self] = newValue }
    }
}
