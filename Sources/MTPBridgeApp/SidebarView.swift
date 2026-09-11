import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    var body: some View {
        List {
            if let info = model.deviceInfo {
                Section("sidebar.device") {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: interfaceTextSize.bodyPointSize + 4, weight: .regular))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.displayName)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if !info.manufacturer.isEmpty {
                                Text(info.manufacturer)
                                    .font(.system(size: interfaceTextSize.secondaryPointSize))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !model.storages.isEmpty {
                Section("sidebar.storage") {
                    ForEach(model.storages) { storage in
                        Button {
                            Task { await model.selectStorage(storage) }
                        } label: {
                            StorageRow(
                                storage: storage,
                                isSelected: model.selectedStorageID == storage.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("sidebar.activity") {
                Button {
                    if reduceMotion {
                        model.transfers.isExpanded.toggle()
                    } else {
                        withAnimation(.easeOut(duration: 0.20)) {
                            model.transfers.isExpanded.toggle()
                        }
                    }
                } label: {
                    Label {
                        HStack {
                            Text("sidebar.transfers")
                            Spacer()
                            if model.transfers.unfinishedCount > 0 {
                                Text("\(model.transfers.unfinishedCount)")
                                    .font(.system(size: interfaceTextSize.secondaryPointSize, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(AppPalette.accent)
                    }
                }
                .buttonStyle(.plain)
            }

            if let info = model.deviceInfo {
                Section("sidebar.capabilities") {
                    CapabilityRow(
                        icon: info.supportsPartialDownload ? "checkmark.circle" : "minus.circle",
                        title: "sidebar.resume_download",
                        isEnabled: info.supportsPartialDownload
                    )
                    CapabilityRow(
                        icon: "lock.shield",
                        title: "sidebar.safe_replace",
                        isEnabled: true
                    )
                }
            }
        }
        .font(.system(size: interfaceTextSize.bodyPointSize))
        .listStyle(.sidebar)
    }
}

private struct StorageRow: View {
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let storage: MTPStorage
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: storage.isReadOnly ? "externaldrive.badge.lock" : "externaldrive")
                    .foregroundStyle(isSelected ? AppPalette.accent : .secondary)
                    .frame(width: 18)
                Text(storage.name)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: interfaceTextSize.secondaryPointSize, weight: .semibold))
                }
            }
            StorageUsageBar(value: storage.usedFraction)
            Text(
                String(
                    format: NSLocalizedString("storage.free_format", comment: ""),
                    storage.freeSpace.formattedBytes,
                    storage.capacity.formattedBytes
                )
            )
            .font(.system(size: interfaceTextSize.secondaryPointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private struct CapabilityRow: View {
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let icon: String
    let title: LocalizedStringKey
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(isEnabled ? AppPalette.capability : Color.secondary.opacity(0.55))
                .frame(width: 16)
            Text(title)
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
        }
        .font(.system(size: interfaceTextSize.secondaryPointSize))
    }
}

private struct StorageUsageBar: View {
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppPalette.storageTrack)
                Capsule(style: .continuous)
                    .fill(AppPalette.storage)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: interfaceTextSize.storageBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("sidebar.storage_usage"))
        .accessibilityValue(Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%"))
    }
}
