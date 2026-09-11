import SwiftUI

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 54, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusIconColor)
                    .frame(width: 84, height: 72)

                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: interfaceTextSize.bodyPointSize + 6, weight: .semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .id(statusIdentity)
            .transition(.opacity)

            if let conflict = model.mtpAccessConflict {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text(String(
                            format: NSLocalizedString("connection.conflict.detected", comment: ""),
                            conflict.displayName
                        ))
                        .font(.system(size: interfaceTextSize.bodyPointSize, weight: .semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.warning)
                    }

                    Text("connection.conflict.explanation")
                        .font(.system(size: interfaceTextSize.secondaryPointSize))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("connection.conflict.stop_legacy") {
                            Task { await model.temporarilyStopLegacyAndroidFileTransfer() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("connection.retry") {
                            Task { await model.connect() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(18)
                .frame(maxWidth: 560, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            } else if isBusy {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("connection.activity")
                        .font(.system(size: interfaceTextSize.bodyPointSize))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    InstructionRow(number: 1, text: "connection.step.unlock")
                    InstructionRow(number: 2, text: "connection.step.usb_mode")
                    InstructionRow(number: 3, text: "connection.step.permission")
                }
                .padding(18)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button("connection.retry") {
                    Task { await model.connect() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(40)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: statusIdentity)
    }

    private var isBusy: Bool {
        model.connectionState == .searching || model.connectionState == .connecting
    }

    private var statusIconColor: Color {
        if model.mtpAccessConflict != nil { return AppPalette.warning }
        return model.connectionState.isFailure ? AppPalette.warning : .secondary
    }

    private var statusColor: Color {
        if model.mtpAccessConflict != nil { return AppPalette.warning }
        switch model.connectionState {
        case .searching, .connecting: return AppPalette.accent
        case .failed: return AppPalette.warning
        case .connected: return AppPalette.success
        case .disconnected: return .secondary
        }
    }

    private var title: LocalizedStringKey {
        if model.mtpAccessConflict != nil { return "connection.conflict.title" }
        switch model.connectionState {
        case .searching: return "connection.searching.title"
        case .connecting: return "connection.connecting.title"
        case .failed: return "connection.failed.title"
        default: return "connection.empty.title"
        }
    }

    private var message: String {
        if model.mtpAccessConflict != nil {
            return NSLocalizedString("connection.conflict.message", comment: "")
        }
        switch model.connectionState {
        case .searching:
            return NSLocalizedString("connection.searching.message", comment: "")
        case .connecting:
            return NSLocalizedString("connection.connecting.message", comment: "")
        case let .failed(error):
            return error
        default:
            return NSLocalizedString("connection.empty.message", comment: "")
        }
    }

    private var statusIdentity: String {
        if model.mtpAccessConflict != nil { return "mtp-conflict" }
        switch model.connectionState {
        case .disconnected: return "disconnected"
        case .searching: return "searching"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }
}

private extension ConnectionState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct InstructionRow: View {
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: interfaceTextSize.secondaryPointSize, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.tertiary, in: Circle())
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
