#if canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit-backed browser table. NSTableView owns row selection, header sorting,
/// column resizing, and drag sessions so those interactions cannot be stolen by
/// per-cell SwiftUI gestures.
@MainActor
struct RemoteBrowserTable: NSViewRepresentable {
    var objects: [MTPObject]
    var pendingCreationDateIDs: Set<UInt32>
    @Binding var selection: Set<UInt32>
    @Binding var sort: BrowserSort
    @Binding var sortAscending: Bool
    var canRunAction: Bool
    var canWrite: Bool
    var onOpen: (MTPObject) -> Void
    var onUpload: ([URL]) -> Void
    var onDownload: (Set<UInt32>) -> Void
    var onRename: (MTPObject) -> Void
    var onDelete: (Set<UInt32>) -> Void
    var fulfillPromise: @MainActor @Sendable (MTPObject, URL, String) async throws -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = RemoteNSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.openDoubleClickedRow(_:))
        tableView.headerView = NSTableHeaderView(frame: .zero)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autosaveName = "AndroidTransferV2.RemoteBrowserTable.v2"
        tableView.autosaveTableColumns = true
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }

        for specification in ColumnSpecification.all {
            let column = NSTableColumn(identifier: specification.identifier)
            column.title = NSLocalizedString(specification.titleKey, comment: "")
            column.minWidth = specification.minimumWidth
            column.width = specification.idealWidth
            column.maxWidth = specification.maximumWidth
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: specification.sortKey.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        context.coordinator.tableView = tableView
        context.coordinator.replaceContent(
            objects: objects,
            pendingCreationDateIDs: pendingCreationDateIDs
        )
        context.coordinator.synchronizeSortIndicator()
        context.coordinator.synchronizeSelection()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.tableView = tableView
        context.coordinator.replaceContent(
            objects: objects,
            pendingCreationDateIDs: pendingCreationDateIDs
        )
        context.coordinator.synchronizeSortIndicator()
        context.coordinator.synchronizeSelection()
    }

    private struct ColumnSpecification {
        let identifier: NSUserInterfaceItemIdentifier
        let titleKey: String
        let sortKey: BrowserSort
        let minimumWidth: CGFloat
        let idealWidth: CGFloat
        let maximumWidth: CGFloat

        static let all: [ColumnSpecification] = [
            .init(
                identifier: .remoteName,
                titleKey: "browser.column.name",
                sortKey: .name,
                minimumWidth: 220,
                idealWidth: 420,
                maximumWidth: 900
            ),
            .init(
                identifier: .remoteType,
                titleKey: "browser.column.type",
                sortKey: .type,
                minimumWidth: 100,
                idealWidth: 145,
                maximumWidth: 280
            ),
            .init(
                identifier: .remoteSize,
                titleKey: "browser.column.size",
                sortKey: .size,
                minimumWidth: 90,
                idealWidth: 120,
                maximumWidth: 200
            ),
            .init(
                identifier: .remoteCreated,
                titleKey: "browser.column.created",
                sortKey: .created,
                minimumWidth: 135,
                idealWidth: 180,
                maximumWidth: 290
            ),
            .init(
                identifier: .remoteModified,
                titleKey: "browser.column.modified",
                sortKey: .modified,
                minimumWidth: 135,
                idealWidth: 180,
                maximumWidth: 290
            ),
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: RemoteBrowserTable
        weak var tableView: NSTableView?
        private(set) var objects: [MTPObject] = []
        private var pendingCreationDateIDs = Set<UInt32>()
        private var isSynchronizingSelection = false
        private var isSynchronizingSort = false
        private var promiseDelegates: [UUID: RemoteFilePromiseDelegate] = [:]
        private let dateFormatter: DateFormatter

        init(parent: RemoteBrowserTable) {
            self.parent = parent
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            dateFormatter = formatter
            super.init()
        }

        func replaceContent(
            objects newObjects: [MTPObject],
            pendingCreationDateIDs newPendingIDs: Set<UInt32>
        ) {
            guard objects != newObjects || pendingCreationDateIDs != newPendingIDs else { return }
            objects = newObjects
            pendingCreationDateIDs = newPendingIDs
            if let tableView {
                // reloadData can emit a transient selection-change notification
                // while rows are being reordered (sorting/date enrichment). Keep
                // the ID-based SwiftUI selection authoritative, then remap it to
                // the new row indexes in synchronizeSelection().
                isSynchronizingSelection = true
                tableView.reloadData()
                isSynchronizingSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            objects.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard objects.indices.contains(row), let tableColumn else { return nil }
            let object = objects[row]
            switch tableColumn.identifier {
            case .remoteName:
                return nameCell(in: tableView, object: object)
            case .remoteType:
                return textCell(
                    in: tableView,
                    identifier: .remoteTypeCell,
                    text: object.typeDisplayName,
                    alignment: .left,
                    textColor: .secondaryLabelColor
                )
            case .remoteSize:
                return textCell(
                    in: tableView,
                    identifier: .remoteSizeCell,
                    text: object.isFolder ? "—" : object.size.formattedBytes,
                    alignment: .right,
                    textColor: object.isFolder ? .tertiaryLabelColor : .secondaryLabelColor,
                    monospacedDigits: true
                )
            case .remoteCreated:
                return dateCell(
                    in: tableView,
                    identifier: .remoteCreatedCell,
                    date: object.creationDate,
                    isPending: pendingCreationDateIDs.contains(object.id)
                )
            case .remoteModified:
                return dateCell(in: tableView, identifier: .remoteModifiedCell, date: object.modificationDate)
            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, let tableView else { return }
            let selectedIDs = MTPSelectionMapping.objectIDs(
                at: tableView.selectedRowIndexes,
                in: objects
            )
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
        }

        func synchronizeSelection() {
            guard let tableView else { return }
            let indexes = MTPSelectionMapping.rowIndexes(
                for: parent.selection,
                in: objects
            )
            guard tableView.selectedRowIndexes != indexes else { return }
            isSynchronizingSelection = true
            if indexes.isEmpty {
                tableView.deselectAll(nil)
            } else {
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            isSynchronizingSelection = false
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isSynchronizingSort,
                  let descriptor = tableView.sortDescriptors.first,
                  let rawKey = descriptor.key,
                  let sortKey = BrowserSort(rawValue: rawKey) else { return }
            parent.sort = sortKey
            parent.sortAscending = descriptor.ascending
        }

        func synchronizeSortIndicator() {
            guard let tableView else { return }
            let current = tableView.sortDescriptors.first
            if current?.key == parent.sort.rawValue,
               current?.ascending == parent.sortAscending {
                return
            }
            isSynchronizingSort = true
            tableView.sortDescriptors = [
                NSSortDescriptor(key: parent.sort.rawValue, ascending: parent.sortAscending)
            ]
            isSynchronizingSort = false
        }

        @objc func openDoubleClickedRow(_ sender: Any?) {
            guard parent.canRunAction,
                  let tableView,
                  tableView.clickedRow >= 0,
                  objects.indices.contains(tableView.clickedRow) else { return }
            let object = objects[tableView.clickedRow]
            guard object.isFolder else { return }
            selectOnly(row: tableView.clickedRow)
            parent.onOpen(object)
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard parent.canRunAction, objects.indices.contains(row) else { return nil }
            let object = objects[row]
            let promisedName = FilenamePolicy.promisedFileName(object.name)
            let typeIdentifier: String
            if object.isFolder {
                typeIdentifier = UTType.folder.identifier
            } else if !object.filenameExtension.isEmpty,
                      let type = UTType(filenameExtension: object.filenameExtension) {
                typeIdentifier = type.identifier
            } else {
                typeIdentifier = UTType.data.identifier
            }

            let identifier = UUID()
            let delegate = RemoteFilePromiseDelegate(
                identifier: identifier,
                object: object,
                promisedName: promisedName,
                fulfill: parent.fulfillPromise,
                didFinish: { [weak self] identifier in
                    self?.promiseDelegates.removeValue(forKey: identifier)
                }
            )
            let provider = NSFilePromiseProvider(fileType: typeIdentifier, delegate: delegate)
            promiseDelegates[identifier] = delegate
            return provider
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.canWrite, fileURLs(from: info.draggingPasteboard).isEmpty == false else {
                return []
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard parent.canWrite else { return false }
            let urls = fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            parent.onUpload(urls)
            return true
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard objects.indices.contains(row), let tableView else { return nil }
            if !tableView.selectedRowIndexes.contains(row) {
                selectOnly(row: row)
            }
            let object = objects[row]
            let ids = parent.selection.isEmpty ? Set([object.id]) : parent.selection
            let menu = NSMenu()

            let open = NSMenuItem(
                title: NSLocalizedString("browser.open", comment: ""),
                action: #selector(openContextItem(_:)),
                keyEquivalent: ""
            )
            open.target = self
            open.isEnabled = parent.canRunAction && object.isFolder
            menu.addItem(open)

            let download = NSMenuItem(
                title: NSLocalizedString("browser.download", comment: ""),
                action: #selector(downloadContextItems(_:)),
                keyEquivalent: ""
            )
            download.target = self
            download.representedObject = Array(ids)
            download.isEnabled = parent.canRunAction
            menu.addItem(download)
            menu.addItem(.separator())

            let rename = NSMenuItem(
                title: NSLocalizedString("browser.rename", comment: ""),
                action: #selector(renameContextItem(_:)),
                keyEquivalent: ""
            )
            rename.target = self
            rename.isEnabled = parent.canWrite && ids.count == 1
            menu.addItem(rename)

            let delete = NSMenuItem(
                title: NSLocalizedString("browser.delete", comment: ""),
                action: #selector(deleteContextItems(_:)),
                keyEquivalent: ""
            )
            delete.target = self
            delete.representedObject = Array(ids)
            delete.isEnabled = parent.canWrite
            menu.addItem(delete)
            return menu
        }

        @objc private func openContextItem(_ sender: NSMenuItem) {
            guard parent.canRunAction,
                  let tableView,
                  tableView.selectedRow >= 0,
                  objects.indices.contains(tableView.selectedRow) else { return }
            let object = objects[tableView.selectedRow]
            guard object.isFolder else { return }
            parent.onOpen(object)
        }

        @objc private func downloadContextItems(_ sender: NSMenuItem) {
            guard parent.canRunAction else { return }
            parent.onDownload(representedIDs(sender) ?? parent.selection)
        }

        @objc private func renameContextItem(_ sender: NSMenuItem) {
            guard parent.canWrite,
                  let tableView,
                  tableView.selectedRowIndexes.count == 1,
                  tableView.selectedRow >= 0,
                  objects.indices.contains(tableView.selectedRow) else { return }
            parent.onRename(objects[tableView.selectedRow])
        }

        @objc private func deleteContextItems(_ sender: NSMenuItem) {
            guard parent.canWrite else { return }
            parent.onDelete(representedIDs(sender) ?? parent.selection)
        }

        private func representedIDs(_ item: NSMenuItem) -> Set<UInt32>? {
            guard let values = item.representedObject as? [UInt32] else { return nil }
            return Set(values)
        }

        private func selectOnly(row: Int) {
            guard let tableView, objects.indices.contains(row) else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let id = objects[row].id
            if parent.selection != Set([id]) {
                parent.selection = Set([id])
            }
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            let values = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [NSURL]
            return values?.map { $0 as URL } ?? []
        }

        private func nameCell(in tableView: NSTableView, object: MTPObject) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier.remoteNameCell
            let cell: NSTableCellView
            if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reusable
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier

                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                imageView.setContentHuggingPriority(.required, for: .horizontal)

                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingMiddle
                textField.maximumNumberOfLines = 1

                cell.imageView = imageView
                cell.textField = textField
                cell.addSubview(imageView)
                cell.addSubview(textField)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 19),
                    imageView.heightAnchor.constraint(equalToConstant: 19),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            cell.textField?.stringValue = object.name
            cell.textField?.textColor = .labelColor
            let image = NSImage(
                systemSymbolName: object.systemImageName,
                accessibilityDescription: object.typeDisplayName
            )
            cell.imageView?.image = image
            cell.imageView?.contentTintColor = iconColor(for: object.category)
            cell.toolTip = object.name
            return cell
        }

        private func dateCell(
            in tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            date: Date?,
            isPending: Bool = false
        ) -> NSTableCellView {
            if isPending {
                return textCell(
                    in: tableView,
                    identifier: identifier,
                    text: NSLocalizedString("browser.date.loading", comment: ""),
                    alignment: .left,
                    textColor: .tertiaryLabelColor,
                    monospacedDigits: false,
                    toolTip: NSLocalizedString("browser.date.loading.help", comment: "")
                )
            }
            if let date {
                return textCell(
                    in: tableView,
                    identifier: identifier,
                    text: dateFormatter.string(from: date),
                    alignment: .left,
                    textColor: .secondaryLabelColor,
                    monospacedDigits: true,
                    toolTip: DateFormatter.localizedString(
                        from: date,
                        dateStyle: .full,
                        timeStyle: .long
                    )
                )
            }
            return textCell(
                in: tableView,
                identifier: identifier,
                text: NSLocalizedString("browser.date.unavailable", comment: ""),
                alignment: .left,
                textColor: .tertiaryLabelColor,
                monospacedDigits: false,
                toolTip: NSLocalizedString("browser.date.unavailable.help", comment: "")
            )
        }

        private func textCell(
            in tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment,
            textColor: NSColor,
            monospacedDigits: Bool = false,
            toolTip: String? = nil
        ) -> NSTableCellView {
            let cell: NSTableCellView
            if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reusable
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.maximumNumberOfLines = 1
                cell.textField = textField
                cell.addSubview(textField)
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.textColor = textColor
            cell.textField?.font = monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            cell.toolTip = toolTip
            return cell
        }

        private func iconColor(for category: MTPObjectCategory) -> NSColor {
            switch category {
            case .folder: return .systemOrange
            case .image: return .systemPurple
            case .video: return .systemPink
            case .audio: return .systemBlue
            case .pdf: return .systemRed
            case .archive: return .systemBrown
            case .document: return .systemIndigo
            case .application: return .systemGreen
            case .other: return .secondaryLabelColor
            }
        }
    }
}

private final class RemoteNSTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let row = row(at: location)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let identifier: UUID
    private let object: MTPObject
    private let promisedName: String
    private let fulfill: @MainActor @Sendable (MTPObject, URL, String) async throws -> Void
    private let didFinish: @MainActor @Sendable (UUID) -> Void
    private let queue: OperationQueue

    init(
        identifier: UUID,
        object: MTPObject,
        promisedName: String,
        fulfill: @escaping @MainActor @Sendable (MTPObject, URL, String) async throws -> Void,
        didFinish: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.identifier = identifier
        self.object = object
        self.promisedName = promisedName
        self.fulfill = fulfill
        self.didFinish = didFinish
        let queue = OperationQueue()
        queue.name = "AndroidTransferV2.FilePromise.\(identifier.uuidString)"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
        super.init()
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        // Return the complete remote filename exactly once. Finder must not infer
        // and append another extension from the UTI.
        promisedName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let object = object
        let promisedName = promisedName
        let fulfill = fulfill
        let identifier = identifier
        let didFinish = didFinish
        Task { @MainActor in
            do {
                try await fulfill(object, url, promisedName)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            didFinish(identifier)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let remoteName = Self("remote.name")
    static let remoteType = Self("remote.type")
    static let remoteSize = Self("remote.size")
    static let remoteCreated = Self("remote.created")
    static let remoteModified = Self("remote.modified")

    static let remoteNameCell = Self("remote.name.cell")
    static let remoteTypeCell = Self("remote.type.cell")
    static let remoteSizeCell = Self("remote.size.cell")
    static let remoteCreatedCell = Self("remote.created.cell")
    static let remoteModifiedCell = Self("remote.modified.cell")
}
#endif
