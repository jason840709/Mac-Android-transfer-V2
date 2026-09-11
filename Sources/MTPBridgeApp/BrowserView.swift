import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showRename = false
    @State private var renameValue = ""
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIDs = Set<UInt32>()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()

            ZStack {
                fileTable

                if model.displayedObjects.isEmpty && !model.isLoadingFolder {
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass",
                        description: Text(emptyStateMessage)
                    )
                    .allowsHitTesting(false)
                }

                if model.isLoadingFolder {
                    ProgressView("browser.loading")
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

            }
        }
        .toolbar { toolbarContent }
        .alert("folder.new.title", isPresented: $showNewFolder) {
            TextField("folder.new.placeholder", text: $newFolderName)
            Button("common.cancel", role: .cancel) { newFolderName = "" }
            Button("common.create") {
                let value = newFolderName
                newFolderName = ""
                Task { await model.createFolder(named: value) }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("rename.title", isPresented: $showRename) {
            TextField("rename.placeholder", text: $renameValue)
            Button("common.cancel", role: .cancel) { renameValue = "" }
            Button("common.rename") {
                let value = renameValue
                renameValue = ""
                Task { await model.renameSelected(to: value) }
            }
            .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "delete.confirm.title",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("delete.confirm.button", role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                Task { await model.delete(objectIDs: ids) }
            }
            Button("common.cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text(
                String(
                    format: NSLocalizedString("delete.confirm.message", comment: ""),
                    pendingDeleteIDs.count
                )
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewFolderSheet)) { _ in
            guard model.canWrite else { return }
            newFolderName = ""
            showNewFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDeleteSelection)) { _ in
            requestDelete(ids: model.selection)
        }
    }

    private var fileTable: some View {
        @Bindable var model = model
        return RemoteBrowserTable(
            objects: model.displayedObjects,
            pendingCreationDateIDs: model.pendingCreationDateIDs,
            selection: $model.selection,
            sort: $model.sort,
            sortAscending: $model.sortAscending,
            textSize: interfaceTextSize,
            canRunAction: model.canRunBrowserAction,
            canWrite: model.canWrite,
            onOpen: { object in
                Task { await model.open(object) }
            },
            onUpload: { urls in
                model.enqueueUploads(urls: urls)
            },
            onDownload: { ids in
                model.selection = ids
                Task { await model.chooseAndEnqueueDownloads() }
            },
            onRename: { object in
                model.selection = [object.id]
                renameValue = object.name
                showRename = true
            },
            onDelete: { ids in
                model.selection = ids
                requestDelete(ids: ids)
            },
            fulfillPromise: { object, destinationDirectory, promisedName in
                try await model.fulfillFilePromise(
                    object: object,
                    destinationDirectory: destinationDirectory,
                    promisedName: promisedName
                )
            }
        )
    }

    private var emptyStateTitle: LocalizedStringKey {
        model.searchText.isEmpty ? "browser.empty.title" : "browser.no_results.title"
    }

    private var emptyStateMessage: LocalizedStringKey {
        model.searchText.isEmpty ? "browser.empty.message" : "browser.no_results.message"
    }

    private var sortDirectionTitle: LocalizedStringKey {
        model.sortAscending ? "sort.ascending" : "sort.descending"
    }

    private func requestDelete(ids: Set<UInt32>) {
        guard model.canWrite, !ids.isEmpty else { return }
        pendingDeleteIDs = ids
        showDeleteConfirmation = true
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await model.navigateBack() }
            } label: {
                Label("browser.back", systemImage: "chevron.left")
            }
            .disabled(!model.canNavigateBack)
            .help("browser.back.help")

            Button {
                Task { await model.navigateForward() }
            } label: {
                Label("browser.forward", systemImage: "chevron.right")
            }
            .disabled(!model.canNavigateForward)
            .help("browser.forward.help")

            Button {
                Task { await model.navigateUp() }
            } label: {
                Label("browser.up", systemImage: "arrow.up")
            }
            .disabled(model.breadcrumbs.isEmpty || !model.canRunBrowserAction)
            .help("browser.up.help")

            Button {
                Task { await model.refresh() }
            } label: {
                Label("browser.refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canRunBrowserAction)
            .help("browser.refresh.help")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Label("browser.new_folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.canWrite)
            .help("browser.new_folder.help")

            Button {
                Task { await model.chooseAndEnqueueUploads() }
            } label: {
                Label("browser.upload", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canWrite)
            .help("browser.upload.help")

            Button {
                Task { await model.chooseAndEnqueueDownloads() }
            } label: {
                Label("browser.download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty || !model.canRunBrowserAction)
            .help("browser.download.help")

            Menu {
                Picker("browser.sort", selection: Binding(
                    get: { model.sort },
                    set: { model.sort = $0 }
                )) {
                    ForEach(BrowserSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Divider()
                Button {
                    model.sortAscending.toggle()
                } label: {
                    Label(
                        sortDirectionTitle,
                        systemImage: model.sortAscending ? "arrow.up" : "arrow.down"
                    )
                }
            } label: {
                Label("browser.sort", systemImage: "arrow.up.arrow.down")
            }
            .help("browser.sort.help")
        }

        ToolbarItemGroup {
            Button {
                if let object = model.selectedObjects.first {
                    renameValue = object.name
                    showRename = true
                }
            } label: {
                Label("browser.rename", systemImage: "pencil")
            }
            .disabled(model.selection.count != 1 || !model.canWrite)
            .help("browser.rename.help")

            Button(role: .destructive) {
                requestDelete(ids: model.selection)
            } label: {
                Label("browser.delete_selected", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty || !model.canWrite)
            .help("browser.delete.help")
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("browser.search", text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ))
                .textFieldStyle(.plain)

                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("browser.clear_search.help")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 210, height: 28)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
            .help("browser.search.help")
            .accessibilityLabel(Text("browser.search"))
        }
    }

}

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    Task { await model.navigate(toBreadcrumb: -1) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(AppPalette.accent)
                        Text(
                            model.selectedStorage?.name
                                ?? NSLocalizedString("browser.root", comment: "")
                        )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canRunBrowserAction)

                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.objectID) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.system(size: interfaceTextSize.secondaryPointSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Button(folder.name) {
                        Task { await model.navigate(toBreadcrumb: index) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canRunBrowserAction)
                }
            }
            .font(.system(size: interfaceTextSize.bodyPointSize))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}
