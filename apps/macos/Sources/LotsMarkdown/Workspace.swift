// One window: folder sidebar | Markdown source | rendered preview.
// The source shows first; the preview is created after the first frame so it never delays
// opening. Saving writes the exact UTF-8 bytes of the source; other apps' changes reload.

import AppKit

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let rootURL: URL
    private(set) var fileURL: URL?
    private var savedData = Data()
    private(set) var isDirty = false { didSet { window?.isDocumentEdited = isDirty } }

    private let split = NSSplitView()
    private let sidebar: FileTreeView
    private let sourceHolder = NSView()
    private var sourceScroll: NSScrollView?
    private var textView: NSTextView?
    private var preview: PreviewPane?
    private let previewHolder = NSView()
    private var watcher: DispatchSourceFileSystemObject?
    private var renderScheduled = false
    private var syncScheduled = false
    /// Last (UTF-16 index, UTF-8 offset) pair, so scroll sync converts only the difference.
    private var offsetCache: (utf16: Int, utf8: Int) = (0, 0)
    private var openedAt = 0.0

    /// `url` is a folder (sidebar shown) or a file (its folder in the sidebar, hidden at first).
    init(opening url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        rootURL = isDir.boolValue ? url : url.deletingLastPathComponent()
        sidebar = FileTreeView(root: rootURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("LotsMarkdownWorkspace")
        super.init(window: window)
        window.delegate = self
        window.title = rootURL.lastPathComponent

        split.isVertical = true
        split.dividerStyle = .thin
        for view in [sidebar, sourceHolder, previewHolder] { split.addArrangedSubview(view) }
        // Panes have no intrinsic width; without minimums auto layout collapses them to 0.
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            sourceHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            previewHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        split.setHoldingPriority(.defaultLow + 20, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 2)
        sidebar.isHidden = !isDir.boolValue
        previewHolder.isHidden = true
        window.contentView = split
        sidebar.onOpen = { [weak self] url in self?.requestOpen(url) }
        if !isDir.boolValue { load(url) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        layoutPanes()
        window?.displayIfNeeded()
        CATransaction.flush()
        let frame = secondsSinceProcessStart()
        bench(["event": "first_frame", "file_bytes": savedData.count, "since_start_ms": frame * 1000,
               "open_to_frame_ms": (frame - openedAt) * 1000, "textkit": textView?.textLayoutManager == nil ? 1 : 2])
        if fileURL != nil {
            DispatchQueue.main.async { self.attachPreview() }
        } else if benchExit {
            exit(0)
        }
    }

    private func layoutPanes() {
        let width = split.bounds.width
        let side: CGFloat = sidebar.isHidden ? 0 : 240
        if !sidebar.isHidden { split.setPosition(side, ofDividerAt: 0) }
        if !previewHolder.isHidden { split.setPosition(side + (width - side) / 2, ofDividerAt: 1) }
    }

    // MARK: Opening

    /// Opens `url` in this window, asking first when the current file has unsaved changes.
    func requestOpen(_ url: URL) {
        guard url.standardizedFileURL != fileURL?.standardizedFileURL else { return }
        confirmDiscard { [weak self] in
            guard let self else { return }
            self.load(url)
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
        savedData = data
        isDirty = false
        offsetCache = (0, 0)
        window?.title = url.lastPathComponent
        window?.representedURL = url
        installTextView(text: String(decoding: data, as: UTF8.self), large: data.count > Renderer.largeFileBytes)
        trace("textview")
        watch(url)
        if !sidebar.isHidden { sidebar.reveal(url) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
        guard let url = fileURL else { return }
        if preview == nil {
            let pane = PreviewPane()
            pane.webView.frame = previewHolder.bounds
            pane.webView.autoresizingMask = [.width, .height]
            previewHolder.addSubview(pane.webView)
            previewHolder.isHidden = false
            layoutPanes()
            if benchExit { pane.onFirstLoad = { exit(0) } }
            preview = pane
        }
        preview?.show(savedData, baseURL: url.deletingLastPathComponent())
    }

    // MARK: Editing and preview

    func textDidChange(_ notification: Notification) {
        isDirty = true
        offsetCache = (0, 0)
        guard !renderScheduled, preview != nil, !previewHolder.isHidden else { return }
        renderScheduled = true
        // Coalesce keystrokes; small documents re-render almost immediately.
        let delay = (textView?.string.utf16.count ?? 0) > 1_000_000 ? 0.6 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let url = self.fileURL, let text = self.textView?.string else { return }
            self.renderScheduled = false
            self.preview?.show(Data(text.utf8), baseURL: url.deletingLastPathComponent())
        }
    }

    @objc private func sourceScrolled() {
        guard !syncScheduled, preview != nil, !previewHolder.isHidden else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncPreviewToSource()
        }
    }

    private func syncPreviewToSource() {
        guard let view = textView, let scroll = sourceScroll else { return }
        let top = NSPoint(x: view.textContainerInset.width + 1, y: scroll.contentView.bounds.minY + view.textContainerInset.height)
        let index = view.characterIndexForInsertion(at: top)
        let text = view.string as NSString
        guard index <= text.length else { return }
        // Convert the UTF-16 index to a UTF-8 byte offset from the last known pair.
        let (from, base) = offsetCache
        let utf8: Int
        if index >= from {
            utf8 = base + text.substring(with: NSRange(location: from, length: index - from)).utf8.count
        } else {
            utf8 = base - text.substring(with: NSRange(location: index, length: from - index)).utf8.count
        }
        offsetCache = (index, utf8)
        preview?.scroll(toSourceOffset: utf8)
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
        guard let view = textView, let url = fileURL else { return }
        let selection = view.selectedRange()
        let origin = sourceScroll?.contentView.bounds.origin ?? .zero
        savedData = data
        view.string = String(decoding: data, as: UTF8.self)
        isDirty = false
        offsetCache = (0, 0)
        let length = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        sourceScroll?.contentView.scroll(to: origin)
        preview?.show(data, baseURL: url.deletingLastPathComponent())
    }

    // MARK: Menu actions

    @objc func togglePreview(_ sender: Any?) {
        guard preview != nil else { return }
        previewHolder.isHidden.toggle()
        split.adjustSubviews()
        layoutPanes()
        if !previewHolder.isHidden, let url = fileURL, let text = textView?.string {
            preview?.show(Data(text.utf8), baseURL: url.deletingLastPathComponent())
        }
    }

    @objc func toggleFileTree(_ sender: Any?) {
        sidebar.isHidden.toggle()
        split.adjustSubviews()
        layoutPanes()
        if !sidebar.isHidden, let url = fileURL { sidebar.reveal(url) }
    }

    @objc func revealCurrentFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL ?? rootURL])
    }

    @objc func copyCurrentPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((fileURL ?? rootURL).path, forType: .string)
    }
}
