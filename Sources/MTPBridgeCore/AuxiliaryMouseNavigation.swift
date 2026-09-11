import Foundation

public enum BrowserNavigationAction: Equatable, Sendable {
    case back
    case forward
}

/// Maps the standard macOS auxiliary mouse buttons used by Logitech and other
/// multi-button mice. NSEvent button numbers are zero based: 0 left, 1 right,
/// 2 middle, then 3 and 4 for the common back/forward pair.
public enum AuxiliaryMouseNavigation {
    /// AppKit numbers left/right as 0/1 and middle click as 2. Logitech
    /// software normally exposes the thumb pair as 3/4; some receivers and
    /// profiles expose the same controls as 5/6 or 7/8. Middle click is
    /// deliberately never consumed.
    public static func action(forButtonNumber buttonNumber: Int) -> BrowserNavigationAction? {
        switch buttonNumber {
        case 3, 5, 7: return .back
        case 4, 6, 8: return .forward
        default: return nil
        }
    }

    public static func action(
        forHorizontalSwipe deltaX: Double,
        verticalDelta deltaY: Double = 0,
        threshold: Double = 0.45
    ) -> BrowserNavigationAction? {
        guard abs(deltaX) >= threshold, abs(deltaX) > abs(deltaY) else { return nil }
        return deltaX > 0 ? .back : .forward
    }
}
