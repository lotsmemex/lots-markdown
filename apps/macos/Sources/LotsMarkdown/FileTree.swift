// The folder sidebar, after Typora's file tree: the folder's name on top, its folders and
// text files below, loaded one level at a time. A footer button also lists files Lots
// Markdown does not open; they show greyed out and open in their default app.

import AppKit

final class FileNode {
    let url: URL
    let isDirectory: Bool
    let isSupported: Bool
    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        isSupported = isDirectory || FileKind(url: url) != nil
    }

    static let skippedFolders: Set<String> = ["node_modules", "target", "build", "DerivedData"]
    /// Whether unsupported files are listed; shared by all windows.
    static var showsAllFiles = UserDefaults.standard.bool(forKey: "showsAllFiles") {
        didSet { UserDefaults.standard.set(showsAllFiles, forKey: "showsAllFiles") }
    }

    var children: [FileNode] {
        let all = allChildren
        return Self.showsAllFiles ? all : all.filter(\.isSupported)
    }

    private var allChildren: [FileNode] {
        if let loaded = loadedChildren { return loaded }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var nodes: [FileNode] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory == true && values?.isPackage != true
            if !isDir || !Self.skippedFolders.contains(item.lastPathComponent) {
                nodes.append(FileNode(url: item, isDirectory: isDir))
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

    /// Re-filters after FileNode.showsAllFiles changes; expanded folders stay expanded.
    func refilter() { outline.reloadData() }

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
        } else if node.isSupported {
            onOpen?(node.url)
        } else {
            NSWorkspace.shared.open(node.url)
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
        cell.textField?.textColor = node.isSupported ? .labelColor : .tertiaryLabelColor
        cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : node.isSupported ? "doc.text" : "doc",
                                        accessibilityDescription: nil)
        cell.imageView?.contentTintColor = node.isSupported ? nil : .tertiaryLabelColor
        return cell
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if !node.isDirectory && !node.isSupported {
            let open = menu.addItem(withTitle: "用默认应用打开", action: #selector(openExternally(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = node.url
        }
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

    @objc private func openExternally(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refresh() { reloadAll() }
}

/// The sidebar: folder name, tree, and a footer that toggles unsupported files.
final class SidebarView: NSView {
    let tree: FileTreeView
    private let toggle = NSButton()

    init(root url: URL) {
        tree = FileTreeView(root: url)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: url.lastPathComponent)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = url.path
        toggle.bezelStyle = .accessoryBarAction
        toggle.setButtonType(.pushOnPushOff)
        toggle.imagePosition = .imageLeading
        toggle.font = .systemFont(ofSize: 11)
        toggle.target = self
        toggle.action = #selector(toggleAll)
        let line = NSBox()
        line.boxType = .separator
        for view in [title, tree, line, toggle] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            tree.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            tree.leadingAnchor.constraint(equalTo: leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: tree.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toggle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        updateToggle()
        NotificationCenter.default.addObserver(self, selector: #selector(filterChanged), name: Self.filterDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let filterDidChange = Notification.Name("LotsFileFilterDidChange")

    @objc func toggleAll() {
        FileNode.showsAllFiles.toggle()
        NotificationCenter.default.post(name: Self.filterDidChange, object: nil)
    }

    @objc private func filterChanged() {
        updateToggle()
        tree.refilter()
    }

    private func updateToggle() {
        let all = FileNode.showsAllFiles
        toggle.state = all ? .on : .off
        toggle.title = all ? "显示全部文件" : "只显示文本文件"
        toggle.image = NSImage(systemSymbolName: all ? "eye" : "eye.slash", accessibilityDescription: nil)
        toggle.toolTip = all ? "点击隐藏 Lots Markdown 打不开的文件" : "点击同时显示图片、PDF 等其他文件"
    }
}
