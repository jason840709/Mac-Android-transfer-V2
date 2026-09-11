#if canImport(AppKit)
import AppKit

/// Retained, application-wide navigation input bridge. Logitech software can
/// expose thumb buttons as mouse buttons, browser special keys, or synthesized
/// Command-bracket / Command-arrow keystrokes, so the monitor accepts all
/// common representations while the pointer is anywhere in the app window.
@MainActor
final class NavigationInputMonitor {
    private var localMonitor: Any?
    private var lastAction: BrowserNavigationAction?
    private var lastDispatchTime: TimeInterval = 0
    private var handledMouseButtons = Set<Int>()

    func start(
        canGoBack: @escaping @MainActor () -> Bool,
        canGoForward: @escaping @MainActor () -> Bool,
        goBack: @escaping @MainActor () async -> Void,
        goForward: @escaping @MainActor () async -> Void
    ) {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp, .swipe, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .otherMouseUp,
               self.handledMouseButtons.remove(event.buttonNumber) != nil {
                return nil
            }

            guard let action = self.action(for: event) else { return event }

            let isAvailable: Bool
            switch action {
            case .back:
                isAvailable = canGoBack()
            case .forward:
                isAvailable = canGoForward()
            }
            guard isAvailable else { return event }

            // Some Logitech profiles emit both a mouse-button event and a
            // synthesized keyboard event. Coalesce the pair so one press moves
            // exactly one history entry.
            if self.lastAction == action,
               event.timestamp - self.lastDispatchTime < 0.12 {
                return nil
            }
            self.lastAction = action
            self.lastDispatchTime = event.timestamp
            if event.type == .otherMouseDown {
                self.handledMouseButtons.insert(event.buttonNumber)
            }

            switch action {
            case .back:
                Task { @MainActor in await goBack() }
            case .forward:
                Task { @MainActor in await goForward() }
            }
            return nil
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        lastAction = nil
        lastDispatchTime = 0
        handledMouseButtons.removeAll()
    }

    private func action(for event: NSEvent) -> BrowserNavigationAction? {
        switch event.type {
        case .otherMouseDown, .otherMouseUp:
            return AuxiliaryMouseNavigation.action(forButtonNumber: event.buttonNumber)

        case .swipe:
            return AuxiliaryMouseNavigation.action(
                forHorizontalSwipe: Double(event.deltaX),
                verticalDelta: Double(event.deltaY)
            )

        case .keyDown:
            if event.specialKey == .prev { return .back }
            if event.specialKey == .next { return .forward }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) else { return nil }
            let characters = event.charactersIgnoringModifiers
            if characters == "[" || event.specialKey == .leftArrow { return .back }
            if characters == "]" || event.specialKey == .rightArrow { return .forward }
            return nil

        default:
            return nil
        }
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
#else
@MainActor
final class NavigationInputMonitor {
    func start(
        canGoBack: @escaping @MainActor () -> Bool,
        canGoForward: @escaping @MainActor () -> Bool,
        goBack: @escaping @MainActor () async -> Void,
        goForward: @escaping @MainActor () async -> Void
    ) {}

    func stop() {}
}
#endif
