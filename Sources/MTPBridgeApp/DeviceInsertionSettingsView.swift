#if canImport(AppKit) && canImport(ServiceManagement)
import SwiftUI

struct DeviceInsertionSettingsView: View {
    let service: DeviceInsertionService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(InterfaceTextSize.defaultsKey) private var interfaceTextSizeRaw = InterfaceTextSize.medium.rawValue

    var body: some View {
        Form {
            Section("device_watcher.section.title") {
                Toggle(
                    "device_watcher.toggle",
                    isOn: Binding(
                        get: { service.desiredEnabled },
                        set: { service.setEnabled($0) }
                    )
                )
                Text("device_watcher.explanation")
                    .font(.system(size: InterfaceTextSize.resolved(interfaceTextSizeRaw).secondaryPointSize))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(service.statusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if service.state == .requiresApproval {
                        Button("device_watcher.open_settings") {
                            service.openLoginItemSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: InterfaceTextSize.resolved(interfaceTextSizeRaw).bodyPointSize))
        .padding(16)
        .frame(width: 540, height: 230)
        .onAppear { service.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                service.refresh()
            }
        }
    }
}
#endif
