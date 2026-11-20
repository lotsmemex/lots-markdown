// The folder sidebar: folders and Markdown/text files, loaded one level at a time.

import AppKit

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private(set) var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    static let textExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    static let skippedFolders: Set<String> = ["node_modules", "target", "build", "DerivedData"]

    var children: [FileNode] {
        if let loaded = loadedChildren { return loaded }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var nodes: [FileNode] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory == true && values?.isPackage != true
            if isDir {
                if !Self.skippedFolders.contains(item.lastPathComponent) { nodes.append(FileNode(url: item, isDirectory: true)) }
            } else if Self.textExtensions.contains(item.pathExtension.lowercased()) {
                nodes.append(FileNode(url: item, isDirectory: false))
            }
        }
        nodes.sort {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        loadedChildren = nodes
        return nodes
    }

    func reload() { loadedChildren = nil }
}

final class FileTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = NSOutlineView()
    private(set) var root: FileNode
    var onOpen: ((URL) -> Void)?

    init(root url: URL) {
        root = FileNode(url: url, isDirectory: true)
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        column.width = 220
        outline.addTableColumn(column)
        outline.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        documentView = outline
        hasVerticalScroller = true
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func reloadAll() {
        root.reload()
        outline.reloadData()
    }

    /// Expands the folders down to `url` and selects it.
    func reveal(_ url: URL) {
        let rootPath = root.url.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(rootPath + "/") else { return }
        var node = root
        for part in target.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let next = node.children.first(where: { $0.url.lastPathComponent == part }) else { return }
            if next.isDirectory { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.url)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for view in [image, text] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        return cell
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        let reveal = menu.addItem(withTitle: "在访达中显示", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        let copy = menu.addItem(withTitle: "拷贝完整路径", action: #selector(copyPath(_:)), keyEquivalent: "")
        for item in [reveal, copy] { item.target = self; item.representedObject = node.url }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "刷新目录", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func refresh() { reloadAll() }
}
