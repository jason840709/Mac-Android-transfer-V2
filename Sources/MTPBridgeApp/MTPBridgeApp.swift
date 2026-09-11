import SwiftUI

@main
struct MTPBridgeApp: App {
    @State private var model = AppModel()
    @State private var deviceInsertion = DeviceInsertionService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    deviceInsertion.start()
                    await model.start()
                }
                .frame(minWidth: 880, minHeight: 580)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            MTPBridgeCommands(model: model)
        }

        Settings {
            DeviceInsertionSettingsView(service: deviceInsertion)
        }
    }
}

private struct MTPBridgeCommands: Commands {
    let model: AppModel
    @AppStorage(InterfaceTextSize.defaultsKey) private var interfaceTextSizeRaw = InterfaceTextSize.medium.rawValue

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("command.new_folder") {
                NotificationCenter.default.post(name: .showNewFolderSheet, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.canWrite)
        }

        CommandGroup(after: .pasteboard) {
            Button("command.delete_selected") {
                NotificationCenter.default.post(name: .requestDeleteSelection, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!model.canWrite || model.selection.isEmpty)
        }

        CommandMenu("command.transfer") {
            Button("command.upload") {
                Task { await model.chooseAndEnqueueUploads() }
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(!model.canWrite)

            Button("command.download") {
                Task { await model.chooseAndEnqueueDownloads() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.canRunBrowserAction || model.selection.isEmpty)

            Divider()

            Button("command.refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!model.canRunBrowserAction)

            Button("command.cancel_active") {
                if let id = model.transfers.activeJobID {
                    model.transfers.cancel(jobID: id)
                }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(model.transfers.activeJobID == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Picker("view.text_size", selection: $interfaceTextSizeRaw) {
                ForEach(InterfaceTextSize.allCases) { option in
                    Text(option.localizedTitleKey).tag(option.rawValue)
                }
            }
        }

        CommandMenu("command.navigation") {
            Button("browser.back") {
                Task { await model.navigateBack() }
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!model.canNavigateBack)

            Button("browser.forward") {
                Task { await model.navigateForward() }
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!model.canNavigateForward)

            Button("browser.up") {
                Task { await model.navigateUp() }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(model.breadcrumbs.isEmpty || !model.canRunBrowserAction)
        }

    }
}

extension Notification.Name {
    static let showNewFolderSheet = Notification.Name("MTPBridge.showNewFolderSheet")
    static let requestDeleteSelection = Notification.Name("MTPBridge.requestDeleteSelection")
}
