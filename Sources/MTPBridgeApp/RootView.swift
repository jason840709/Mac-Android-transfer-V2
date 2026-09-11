import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(InterfaceTextSize.defaultsKey) private var interfaceTextSizeRaw = InterfaceTextSize.medium.rawValue

    var body: some View {
        @Bindable var model = model
        let textSize = InterfaceTextSize.resolved(interfaceTextSizeRaw)
        let sidebarWidths = textSize.sidebarWidths
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarWidths.minimum,
                    ideal: sidebarWidths.ideal,
                    max: sidebarWidths.maximum
                )
        } detail: {
            Group {
                if model.connectionState == .connected {
                    BrowserView()
                } else {
                    ConnectionView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TransferShelfView()
            }
        }
        .environment(\.interfaceTextSize, textSize)
        .font(.system(size: textSize.bodyPointSize))
        .tint(AppPalette.accent)
        .navigationTitle(model.deviceInfo?.displayName ?? "Android 傳輸 V2")
        .alert(
            "common.error",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) {
                model.presentedError = nil
            }
        } message: {
            Text(model.presentedError ?? "")
        }
    }
}
