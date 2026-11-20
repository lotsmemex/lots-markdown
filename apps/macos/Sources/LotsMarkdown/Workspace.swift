// One window: folder sidebar | source | rendered page | in-file table of contents.
// Files open in reading mode: the rendered page only. Editing (⌘/) shows the source, with
// the rendered page beside it when split (⌘\). The source view is created on the first
// edit, and the page after the first frame, so neither delays opening. Saving writes the
// exact UTF-8 bytes of the source; other apps' changes reload.

import AppKit

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSToolbarDelegate, NSMenuItemValidation {
    enum Mode { case read, edit }
    /// Where the table of contents sits: on the right, as a small button, or as a card.
    enum OutlinePlacement: String { case docked, button, card }

    let rootURL: URL
    private(set) var fileURL: URL?
    private var kind = FileKind.markdown
    private var savedData = Data()
    private(set) var isDirty = false { didSet { window?.isDocumentEdited = isDirty } }
    private(set) var mode = Mode.read
    private var splitsInEdit = UserDefaults.standard.object(forKey: "editSplit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitsInEdit, forKey: "editSplit") }
    }
    private var outlinePlacement = OutlinePlacement(rawValue: UserDefaults.standard.string(forKey: "outline") ?? "") ?? .docked {
        didSet { UserDefaults.standard.set(outlinePlacement.rawValue, forKey: "outline") }
    }

    private let container = NSView()
    private let split = NSSplitView()
    private let sidebar: SidebarView
    private let sourceHolder = NSView()
    private var sourceScroll: NSScrollView?
    private var textView: NSTextView?
    private var preview: PreviewPane?
    private let previewHolder = NSView()
    private var previewStale = false
    private let outlineDock = NSView()
    private let outlineList = OutlineList()
    private var floating: FloatingPanel?
    private var floatingPlacement: OutlinePlacement?
    private var headings: [Heading] = []
    private var headingsScheduled = false
    private let modeControl = NSSegmentedControl(labels: ["阅读", "编辑"], trackingMode: .selectOne, target: nil, action: nil)
    private let splitControl = NSSegmentedControl(images: [NSImage(systemSymbolName: "rectangle", accessibilityDescription: "单屏")!,
                                                           NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "双屏")!],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private var splitItem: NSToolbarItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var renderScheduled = false
    private var syncScheduled = false
    /// Last (UTF-16 index, UTF-8 offset) pair, so scroll sync converts only the difference.
    private var offsetCache: (utf16: Int, utf8: Int) = (0, 0)
    private var openedAt = 0.0

    private static let sidebarWidth: CGFloat = 240
    private static let outlineWidth: CGFloat = 200
    /// Below this content width the table of contents floats instead of docking.
    private static let dockMinWidth: CGFloat = 900

    /// `url` is a folder (sidebar shown) or a file (its folder in the sidebar, hidden at first).
    init(opening url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        rootURL = isDir.boolValue ? url : url.deletingLastPathComponent()
        sidebar = SidebarView(root: rootURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("LotsMarkdownWorkspace")
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.title = rootURL.lastPathComponent

        split.isVertical = true
        split.dividerStyle = .thin
        for view in [sidebar, sourceHolder, previewHolder, outlineDock] { split.addArrangedSubview(view) }
        // Panes have no intrinsic width; without minimums auto layout collapses them to 0.
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            sourceHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            previewHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            outlineDock.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        split.setHoldingPriority(.defaultLow + 20, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 2)
        split.setHoldingPriority(.defaultLow + 20, forSubviewAt: 3)
        sidebar.isHidden = !isDir.boolValue
        sourceHolder.isHidden = true
        previewHolder.isHidden = isDir.boolValue
        outlineDock.isHidden = true
        buildOutlineDock()
        split.frame = container.bounds
        split.autoresizingMask = [.width, .height]
        container.addSubview(split)
        window.contentView = container

        modeControl.target = self
        modeControl.action = #selector(modeClicked)
        splitControl.target = self
        splitControl.action = #selector(splitClicked)
        splitControl.setToolTip("单屏：只有源码", forSegment: 0)
        splitControl.setToolTip("双屏：源码和渲染并排", forSegment: 1)
        let toolbar = NSToolbar(identifier: "workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.tree.onOpen = { [weak self] url in self?.requestOpen(url) }
        outlineList.onSelect = { [weak self] heading in self?.jump(to: heading) }
        if !isDir.boolValue { load(url) }
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        applyLayout()
        window?.displayIfNeeded()
        CATransaction.flush()
        let frame = secondsSinceProcessStart()
        bench(["event": "first_frame", "file_bytes": savedData.count, "since_start_ms": frame * 1000,
               "open_to_frame_ms": (frame - openedAt) * 1000, "textkit": textView == nil ? 0 : textView?.textLayoutManager == nil ? 1 : 2])
        if fileURL != nil {
            DispatchQueue.main.async { self.attachPreview() }
        } else if benchExit {
            exit(0)
        }
    }

    // MARK: Layout

    private var previewVisible: Bool { fileURL != nil && (mode == .read || splitsInEdit) }

    /// Shows the panes for the current mode and places the table of contents.
    private func applyLayout() {
        if mode == .edit { ensureTextView() }
        sourceHolder.isHidden = mode == .read || fileURL == nil
        previewHolder.isHidden = !previewVisible && fileURL != nil
        if previewVisible && previewStale { refreshPreview() }
        updateOutline()
        split.adjustSubviews()
        layoutPanes()
        updateControls()
    }

    private func layoutPanes() {
        let width = split.bounds.width
        let side: CGFloat = sidebar.isHidden ? 0 : Self.sidebarWidth
        let toc: CGFloat = outlineDock.isHidden ? 0 : Self.outlineWidth
        if !sidebar.isHidden { split.setPosition(side, ofDividerAt: 0) }
        if !outlineDock.isHidden { split.setPosition(width - toc, ofDividerAt: 2) }
        if !sourceHolder.isHidden && !previewHolder.isHidden { split.setPosition(side + (width - side - toc) / 2, ofDividerAt: 1) }
    }

    func windowDidResize(_ notification: Notification) {
        guard floating != nil || !outlineDock.isHidden else { return }
        let wasDocked = !outlineDock.isHidden
        updateOutline()
        if wasDocked != !outlineDock.isHidden { split.adjustSubviews(); layoutPanes() }
    }

    private func updateControls() {
        modeControl.selectedSegment = mode == .read ? 0 : 1
        splitControl.selectedSegment = splitsInEdit ? 1 : 0
        splitControl.isEnabled = mode == .edit
        if #available(macOS 15, *) { splitItem?.isHidden = mode == .read }
        modeControl.isEnabled = fileURL != nil
    }

    // MARK: Table of contents

    private func buildOutlineDock() {
        let header = outlineHeader(collapse: #selector(collapseOutline), dock: nil, floating: false)
        header.translatesAutoresizingMaskIntoConstraints = false
        outlineDock.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: outlineDock.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: outlineDock.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: outlineDock.trailingAnchor),
        ])
    }

    /// "文件内目录" with small buttons; drags on it move a floating card.
    private func outlineHeader(collapse: Selector, dock: Selector?, floating: Bool) -> NSView {
        let title = NSTextField(labelWithString: "文件内目录")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        var buttons: [NSView] = []
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            return b
        }
        if let dock { buttons.append(button("sidebar.right", "固定到右侧", dock)) }
        buttons.append(button(floating ? "minus" : "xmark", "收起成按钮", collapse))
        let row = NSStackView(views: [title, NSView()] + buttons)
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    /// Moves the heading list into `holder` below its header.
    private func placeOutlineList(in holder: NSView, below header: NSView) {
        outlineList.removeFromSuperview()
        outlineList.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(outlineList)
        NSLayoutConstraint.activate([
            outlineList.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            outlineList.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
            outlineList.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4),
            outlineList.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
        ])
    }

    private var canDockOutline: Bool { container.bounds.width >= Self.dockMinWidth && !(mode == .edit && splitsInEdit) }

    private func updateOutline() {
        let effective: OutlinePlacement? = headings.isEmpty || fileURL == nil ? nil
            : outlinePlacement == .docked && !canDockOutline ? .button : outlinePlacement
        outlineDock.isHidden = effective != .docked
        if effective == .docked, outlineList.superview !== outlineDock, let header = outlineDock.subviews.first(where: { $0 is NSStackView }) {
            placeOutlineList(in: outlineDock, below: header)
        }
        if floatingPlacement != effective || (effective == .card && floating == nil) {
            showFloating(effective == .button || effective == .card ? effective : nil)
        } else if let floating {
            floating.setFrameOrigin(FloatingPanel.clamp(floating.frame.origin, size: floating.frame.size, in: container.bounds))
        }
    }

    /// Where the floating button or card sits, as distances from the top-right corner.
    private var floatingInset = NSSize(width: 22, height: 12)

    private func showFloating(_ placement: OutlinePlacement?) {
        floating?.removeFromSuperview()
        floating = nil
        floatingPlacement = placement
        guard let placement else { return }
        let panel: FloatingPanel
        if placement == .button {
            panel = FloatingPanel(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
            let icon = NSImageView(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "文件内目录")!)
            icon.contentTintColor = .secondaryLabelColor
            icon.frame = panel.bounds
            icon.autoresizingMask = [.width, .height]
            panel.box.contentView?.addSubview(icon)
            panel.toolTip = "文件内目录（可拖动，点击展开）"
            panel.onClick = { [weak self] in self?.setOutlinePlacement(.card) }
        } else {
            let height = min(CGFloat(headings.count) * 24 + 44, max(160, container.bounds.height - 40), 420)
            panel = FloatingPanel(frame: NSRect(x: 0, y: 0, width: 230, height: height))
            let header = outlineHeader(collapse: #selector(collapseOutline), dock: canDockOutline ? #selector(dockOutline) : nil, floating: true)
            header.translatesAutoresizingMaskIntoConstraints = false
            let content = panel.box.contentView!
            content.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
                header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
            placeOutlineList(in: content, below: header)
        }
        panel.autoresizingMask = [.minXMargin, .minYMargin]
        panel.onMoved = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.floatingInset = NSSize(width: self.container.bounds.maxX - panel.frame.maxX, height: self.container.bounds.maxY - panel.frame.maxY)
        }
        let origin = NSPoint(x: container.bounds.maxX - floatingInset.width - panel.frame.width,
                             y: container.bounds.maxY - floatingInset.height - panel.frame.height)
        panel.setFrameOrigin(FloatingPanel.clamp(origin, size: panel.frame.size, in: container.bounds))
        container.addSubview(panel)
        floating = panel
    }

    private func setOutlinePlacement(_ placement: OutlinePlacement) {
        outlinePlacement = placement
        let wasDocked = !outlineDock.isHidden
        updateOutline()
        if wasDocked != !outlineDock.isHidden { split.adjustSubviews(); layoutPanes() }
    }

    @objc private func collapseOutline() { setOutlinePlacement(.button) }
    @objc private func dockOutline() { setOutlinePlacement(.docked) }

    @objc func toggleOutline(_ sender: Any?) {
        let shown = !outlineDock.isHidden || floatingPlacement == .card
        setOutlinePlacement(shown ? .button : canDockOutline ? .docked : .card)
    }

    private func updateHeadings(_ data: Data) {
        guard kind == .markdown else { headings = []; outlineList.update([]); updateOutlineAfterHeadings(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = Headings.parse(data)
            DispatchQueue.main.async {
                self.headings = parsed
                self.outlineList.update(parsed)
                self.updateOutlineAfterHeadings()
            }
        }
    }

    private func updateOutlineAfterHeadings() {
        let wasDocked = !outlineDock.isHidden
        if floatingPlacement == .card { floatingPlacement = nil } // rebuild: its height follows the heading count
        updateOutline()
        if wasDocked != !outlineDock.isHidden { split.adjustSubviews(); layoutPanes() }
    }

    private func jump(to heading: Heading) {
        outlineList.highlight(heading)
        if !sourceHolder.isHidden { scrollSource(toByte: heading.offset) }
        if !previewHolder.isHidden { preview?.scroll(toSourceOffset: heading.offset) }
    }

    // MARK: Modes

    @objc private func modeClicked() { setMode(modeControl.selectedSegment == 0 ? .read : .edit) }

    @objc private func splitClicked() {
        splitsInEdit = splitControl.selectedSegment == 1
        applyLayout()
    }

    @objc func toggleMode(_ sender: Any?) { setMode(mode == .read ? .edit : .read) }

    /// ⌘\: in reading mode it opens the split editor; while editing it toggles the split.
    @objc func toggleSplit(_ sender: Any?) {
        guard fileURL != nil else { return }
        if mode == .read { splitsInEdit = true; setMode(.edit) } else { splitsInEdit.toggle(); applyLayout() }
    }

    private func setMode(_ newMode: Mode) {
        guard newMode != mode, fileURL != nil else { updateControls(); return }
        if newMode == .edit {
            let wasShowingPreview = !previewHolder.isHidden
            mode = .edit
            applyLayout()
            window?.makeFirstResponder(textView)
            // Open the source where the reader was.
            if wasShowingPreview {
                preview?.topSourceOffset { [weak self] offset in
                    guard let self, let offset, offset > 0 else { return }
                    self.scrollSource(toByte: offset)
                }
            }
        } else {
            let offset = sourceTopByteOffset()
            mode = .read
            applyLayout()
            if let offset { preview?.scroll(toSourceOffset: offset) }
            if let web = preview?.webView { window?.makeFirstResponder(web) }
        }
    }

    // MARK: Opening

    /// Opens `url` in this window, asking first when the current file has unsaved changes.
    func requestOpen(_ url: URL) {
        guard url.standardizedFileURL != fileURL?.standardizedFileURL else { return }
        confirmDiscard { [weak self] in
            guard let self else { return }
            self.load(url)
            self.applyLayout()
            self.attachPreview()
        }
    }

    private func load(_ url: URL) {
        openedAt = secondsSinceProcessStart()
        trace("open")
        let data: Data
        do {
            data = try Data(contentsOf: url) // not mapped: an in-place write by another app would fault a mapping
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        trace("read")
        fileURL = url
        kind = FileKind(url: url) ?? .plain
        savedData = data
        isDirty = false
        offsetCache = (0, 0)
        window?.title = url.lastPathComponent
        window?.representedURL = url
        // The source view is built on demand from savedData.
        sourceScroll?.removeFromSuperview()
        sourceScroll = nil
        textView = nil
        if mode == .edit { ensureTextView() }
        trace("textview")
        watch(url)
        if !sidebar.isHidden { sidebar.tree.reveal(url) }
        updateHeadings(data)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func ensureTextView() {
        guard textView == nil, fileURL != nil else { return }
        installTextView(text: String(decoding: savedData, as: UTF8.self), large: savedData.count > Renderer.largeFileBytes)
    }

    private func installTextView(text: String, large: Bool) {
        sourceScroll?.removeFromSuperview()
        let scroll: NSScrollView
        let view: NSTextView
        if large {
            // TextKit 1 with non-contiguous layout opens 100 MB files faster (bench/).
            view = NSTextView(usingTextLayoutManager: false)
            view.layoutManager?.allowsNonContiguousLayout = true
            scroll = NSScrollView()
            scroll.documentView = view
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
        } else {
            scroll = NSTextView.scrollableTextView()
            view = scroll.documentView as! NSTextView
        }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.string = text
        view.delegate = self
        scroll.frame = sourceHolder.bounds
        scroll.autoresizingMask = [.width, .height]
        sourceHolder.addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        sourceScroll = scroll
        textView = view
        window?.makeFirstResponder(view)
    }

    private func attachPreview() {
        guard fileURL != nil else { return }
        if preview == nil {
            let pane = PreviewPane()
            pane.webView.frame = previewHolder.bounds
            pane.webView.autoresizingMask = [.width, .height]
            previewHolder.addSubview(pane.webView)
            if benchExit { pane.onFirstLoad = { exit(0) } }
            preview = pane
            if mode == .read { window?.makeFirstResponder(pane.webView) }
        }
        refreshPreview()
    }

    /// The document as it is now: the source view's text once editing started.
    private var currentData: Data { textView.map { Data($0.string.utf8) } ?? savedData }

    /// Renders the current text now when the page is visible, or on next show.
    private func refreshPreview() {
        guard let url = fileURL, let preview else { return }
        guard previewVisible else { previewStale = true; return }
        previewStale = false
        preview.show(currentData, kind: kind, baseURL: url.deletingLastPathComponent())
    }

    // MARK: Editing and preview

    func textDidChange(_ notification: Notification) {
        isDirty = true
        offsetCache = (0, 0)
        let large = (textView?.string.utf16.count ?? 0) > 1_000_000
        if kind == .markdown && !headingsScheduled {
            headingsScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (large ? 1.0 : 0.3)) { [weak self] in
                guard let self else { return }
                self.headingsScheduled = false
                self.updateHeadings(self.currentData)
            }
        }
        guard previewVisible else { previewStale = true; return }
        guard !renderScheduled, preview != nil else { return }
        renderScheduled = true
        // Coalesce keystrokes; small documents re-render almost immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + (large ? 0.6 : 0.12)) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.refreshPreview()
        }
    }

    @objc private func sourceScrolled() {
        guard !syncScheduled, preview != nil, !previewHolder.isHidden, !sourceHolder.isHidden else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncPreviewToSource()
        }
    }

    private func syncPreviewToSource() {
        guard let offset = sourceTopByteOffset() else { return }
        preview?.scroll(toSourceOffset: offset)
    }

    /// UTF-8 byte offset of the first visible source character.
    private func sourceTopByteOffset() -> Int? {
        guard let view = textView, let scroll = sourceScroll else { return nil }
        let top = NSPoint(x: view.textContainerInset.width + 1, y: scroll.contentView.bounds.minY + view.textContainerInset.height)
        let index = view.characterIndexForInsertion(at: top)
        let text = view.string as NSString
        guard index <= text.length else { return nil }
        // Convert the UTF-16 index to a UTF-8 byte offset from the last known pair.
        let (from, base) = offsetCache
        let utf8: Int
        if index >= from {
            utf8 = base + text.substring(with: NSRange(location: from, length: index - from)).utf8.count
        } else {
            utf8 = base - text.substring(with: NSRange(location: index, length: from - index)).utf8.count
        }
        offsetCache = (index, utf8)
        return utf8
    }

    /// Scrolls the source so the line holding UTF-8 byte `offset` is at the top.
    private func scrollSource(toByte offset: Int) {
        guard let view = textView, let scroll = sourceScroll, let window else { return }
        let text = view.string
        let utf8 = text.utf8
        let index = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex) ?? utf8.endIndex
        let location = NSRange(text.startIndex..<index, in: text).length
        let range = NSRange(location: location, length: 0)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        let screen = view.firstRect(forCharacterRange: range, actualRange: nil)
        guard screen != .zero else { return }
        let rect = view.convert(window.convertFromScreen(screen), from: nil)
        let y = max(0, (view.isFlipped ? rect.minY : view.bounds.height - rect.maxY) - view.textContainerInset.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Saving

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL, let text = textView?.string else { return true }
        guard isDirty else { return true }
        let data = Data(text.utf8)
        do {
            try data.write(to: url, options: .atomic)
            savedData = data
            isDirty = false
            watch(url) // an atomic write replaces the file
            return true
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return false
        }
    }

    @objc func saveDocument(_ sender: Any?) { save() }

    /// Runs `proceed` when there is nothing to lose, or after the user saves or discards.
    func confirmDiscard(_ proceed: @escaping () -> Void) {
        guard isDirty, let window, let url = fileURL else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)”有未保存的修改"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: if self?.save() == true { proceed() }
            case .alertThirdButtonReturn: self?.isDirty = false; proceed()
            default: break
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        confirmDiscard { sender.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        NotificationCenter.default.removeObserver(self)
        AppDelegate.shared.workspaces.removeAll { $0 === self }
    }

    // MARK: Changes from other apps

    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            // Editors that save atomically replace the file: read it, then watch the new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.externalChange(url)
                if replaced { self.watch(url) }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func externalChange(_ url: URL) {
        guard url == fileURL, let data = try? Data(contentsOf: url), data != savedData else { return }
        guard !isDirty else {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)”已被其他应用修改"
            alert.informativeText = "你这里也有未保存的修改。"
            alert.addButton(withTitle: "保留我的修改")
            alert.addButton(withTitle: "载入磁盘上的版本")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { self?.reload(data) } else { self?.savedData = data }
            }
            return
        }
        reload(data)
    }

    private func reload(_ data: Data) {
        guard let view = textView else {
            savedData = data
            updateHeadings(data)
            refreshPreview()
            return
        }
        let selection = view.selectedRange()
        let origin = sourceScroll?.contentView.bounds.origin ?? .zero
        savedData = data
        view.string = String(decoding: data, as: UTF8.self)
        isDirty = false
        offsetCache = (0, 0)
        let length = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        sourceScroll?.contentView.scroll(to: origin)
        updateHeadings(data)
        refreshPreview()
    }

    // MARK: Menu actions

    @objc func toggleFileTree(_ sender: Any?) {
        sidebar.isHidden.toggle()
        applyLayout()
        if !sidebar.isHidden, let url = fileURL { sidebar.tree.reveal(url) }
    }

    @objc func toggleAllFiles(_ sender: Any?) { sidebar.toggleAll() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMode(_:)):
            item.title = mode == .read ? "进入编辑" : "回到阅读"
            return fileURL != nil
        case #selector(toggleSplit(_:)):
            item.state = mode == .edit && splitsInEdit ? .on : .off
            return fileURL != nil
        case #selector(toggleFileTree(_:)): item.state = sidebar.isHidden ? .off : .on
        case #selector(toggleOutline(_:)):
            item.state = !outlineDock.isHidden || floatingPlacement == .card ? .on : .off
            return !headings.isEmpty
        case #selector(toggleAllFiles(_:)): item.state = FileNode.showsAllFiles ? .on : .off
        case #selector(saveDocument(_:)): return isDirty
        default: break
        }
        return true
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let split = NSToolbarItem.Identifier("split")
        static let mode = NSToolbarItem.Identifier("mode")
        static let outline = NSToolbarItem.Identifier("outline")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.sidebar, .flexibleSpace, ToolbarID.split, ToolbarID.mode, ToolbarID.outline]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ToolbarID.sidebar:
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "文件目录")
            item.label = "文件目录"
            item.toolTip = "显示/隐藏文件目录 ⌘0"
            item.action = #selector(toggleFileTree(_:))
            item.isBordered = true
        case ToolbarID.split:
            item.view = splitControl
            item.label = "单屏/双屏"
            item.toolTip = "编辑时单屏或双屏 ⌘\\"
            splitItem = item
        case ToolbarID.mode:
            item.view = modeControl
            item.label = "阅读/编辑"
            item.toolTip = "阅读或编辑 ⌘/"
        case ToolbarID.outline:
            item.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "文件内目录")
            item.label = "文件内目录"
            item.toolTip = "展开/收起文件内目录 ⇧⌘O"
            item.action = #selector(toggleOutline(_:))
            item.isBordered = true
        default: return nil
        }
        item.target = self
        return item
    }

    @objc func revealCurrentFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL ?? rootURL])
    }

    @objc func copyCurrentPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((fileURL ?? rootURL).path, forType: .string)
    }
}
