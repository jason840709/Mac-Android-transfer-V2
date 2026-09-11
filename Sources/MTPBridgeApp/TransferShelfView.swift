import SwiftUI

struct TransferShelfView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    @State private var autoCollapseTask: Task<Void, Never>?

    var body: some View {
        if !model.transfers.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                if model.transfers.isExpanded {
                    expandedContent
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    Divider()
                }
                collapsedBar
            }
            .background(.bar)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.20),
                value: model.transfers.isExpanded
            )
            .onAppear {
                scheduleAutoCollapseIfNeeded()
            }
            .onChange(of: transferStates) { _, _ in
                scheduleAutoCollapseIfNeeded()
            }
            .onDisappear {
                autoCollapseTask?.cancel()
                autoCollapseTask = nil
            }
        }
    }

    private var collapsedBar: some View {
        HStack(spacing: 12) {
            Button {
                toggleExpansion()
            } label: {
                Image(systemName: model.transfers.isExpanded ? "chevron.down" : "chevron.up")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.transfers.isExpanded ? Text("transfer.collapse") : Text("transfer.expand"))

            if let active = model.transfers.activeJob {
                Image(systemName: active.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active.direction == .upload ? AppPalette.upload : AppPalette.download)
                Text(active.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: active.totalBytes > 0 ? active.fractionCompleted : nil)
                    .frame(maxWidth: 220)
                Text(activeSummary(active))
                    .font(.system(size: interfaceTextSize.secondaryPointSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)
                Button {
                    model.transfers.pause(jobID: active.id)
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .help("transfer.cancel")
            } else {
                Text(summaryText)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: interfaceTextSize.transferBarHeight)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("transfer.title")
                    .font(.headline)
                Spacer()
                Text(
                    String(
                        format: NSLocalizedString("transfer.count_format", comment: ""),
                        model.transfers.jobs.count
                    )
                )
                .font(.system(size: interfaceTextSize.secondaryPointSize))
                .foregroundStyle(.secondary)

                Button {
                    handleDialogClose()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(hasUnfinishedTransfers ? "transfer.collapse" : "transfer.close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.transfers.jobs.reversed()) { job in
                        TransferRow(job: job)
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private var transferStates: [TransferState] {
        model.transfers.jobs.map(\.state)
    }

    private var hasUnfinishedTransfers: Bool {
        model.transfers.jobs.contains { !$0.state.isTerminal }
    }

    private var allTransfersCompleted: Bool {
        !model.transfers.jobs.isEmpty && model.transfers.jobs.allSatisfy { $0.state == .completed }
    }

    private func toggleExpansion() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        model.transfers.isExpanded.toggle()
    }

    private func handleDialogClose() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        if hasUnfinishedTransfers {
            model.transfers.isExpanded = false
        } else {
            model.transfers.clearFinished()
        }
    }

    private func scheduleAutoCollapseIfNeeded() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        guard allTransfersCompleted, model.transfers.isExpanded else { return }
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, allTransfersCompleted else { return }
            model.transfers.isExpanded = false
            autoCollapseTask = nil
        }
    }

    private func activeSummary(_ job: TransferJob) -> String {
        switch job.phase {
        case .preparing:
            return NSLocalizedString("transfer.state.preparing", comment: "")
        case .finalizing:
            return NSLocalizedString("transfer.phase.finalizing", comment: "")
        case .transferring, .none:
            return job.bytesPerSecond.formattedTransferSpeed
        }
    }

    private var summaryText: LocalizedStringKey {
        if model.transfers.jobs.allSatisfy({ $0.state == .completed }) {
            return "transfer.all_completed"
        }
        if model.transfers.jobs.contains(where: { $0.state == .failed }) {
            return "transfer.has_failures"
        }
        if model.transfers.jobs.contains(where: { $0.state == .paused }) {
            return "transfer.has_paused"
        }
        return "transfer.idle"
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let job: TransferJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stateColor)
                .font(.title3)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(stateText)
                        .font(.system(size: interfaceTextSize.secondaryPointSize))
                        .foregroundStyle(.secondary)
                }

                if job.state == .running || job.state == .preparing || job.state == .retrying {
                    if job.totalBytes > 0 {
                        ProgressView(value: job.fractionCompleted)
                            .tint(job.direction == .upload ? AppPalette.upload : AppPalette.download)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    HStack {
                        if job.totalBytes > 0 {
                            Text("\(job.completedBytes.formattedBytes) / \(job.totalBytes.formattedBytes)")
                        }
                        Spacer()
                        if job.phase == .finalizing {
                            Text("transfer.phase.finalizing")
                        } else if !job.bytesPerSecond.formattedTransferSpeed.isEmpty {
                            Text(job.bytesPerSecond.formattedTransferSpeed)
                        }
                    }
                    .font(.system(size: interfaceTextSize.secondaryPointSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                if let error = job.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.system(size: interfaceTextSize.secondaryPointSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                if job.state == .paused {
                    Button {
                        model.transfers.resume(jobID: job.id)
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .help("transfer.resume")

                    Button {
                        model.transfers.terminate(jobID: job.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("transfer.terminate")

                    Button {
                        model.transfers.remove(jobID: job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("transfer.delete_job")
                } else if !job.state.isTerminal {
                    Button {
                        model.transfers.pause(jobID: job.id)
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .help("transfer.pause")
                } else if job.state == .failed || job.state == .cancelled {
                    Button {
                        model.transfers.retry(jobID: job.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("transfer.retry")

                    Button {
                        model.transfers.remove(jobID: job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("transfer.delete_job")
                }

                if job.state == .completed, job.direction == .download {
                    Button {
                        model.showInFinder(for: job)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("transfer.show_in_finder")
                }

                if job.state == .completed {
                    Button {
                        model.transfers.remove(jobID: job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("transfer.delete_job")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var stateIcon: String {
        switch job.state {
        case .queued: "clock"
        case .preparing: "ellipsis.circle"
        case .running: job.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .retrying: "arrow.clockwise.circle"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .running: job.direction == .upload ? AppPalette.upload : AppPalette.download
        case .completed: AppPalette.success
        case .failed: AppPalette.failure
        case .cancelled: .secondary
        case .retrying: AppPalette.warning
        case .paused: AppPalette.warning
        case .queued, .preparing: .secondary
        }
    }

    private var stateText: String {
        let presentation = TransferStatusPresentation.make(
            state: job.state,
            phase: job.phase,
            attempt: job.attempt,
            maxAttempts: job.maxAttempts
        )
        let format = NSLocalizedString(presentation.localizationKey, comment: "")
        guard presentation.integerArguments.count == 2 else {
            return format
        }
        return String(
            format: format,
            presentation.integerArguments[0],
            presentation.integerArguments[1]
        )
    }
}
