// Lots Markdown for macOS. AppKit only on the launch path.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    var workspaces: [WorkspaceWindowController] = []
    private var openedAtLaunch = false

    func open(_ url: URL) {
        let target = url.standardizedFileURL
        if let existing = workspaces.first(where: { $0.fileURL?.standardizedFileURL == target || ($0.fileURL == nil && $0.rootURL.standardizedFileURL == target) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            NSAlert(error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: target.path])).runModal()
            return
        }
        let workspace = WorkspaceWindowController(opening: target)
        workspaces.append(workspace)
        workspace.present()
        if let window = workspace.window { Updater.shared.decorate(window) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        trace("will finish launching")
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        paths.forEach { open(URL(fileURLWithPath: $0)) }
        if paths.isEmpty && !openedAtLaunch { openDocument(nil) }
        Updater.shared.start()
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        urls.forEach(open)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.applicationWillTerminate(reopen: workspaces.map { $0.fileURL ?? $0.rootURL })
    }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.check(report: true) }

    // Closing the last window keeps the app running, so the next open skips process launch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = workspaces.filter(\.isDirty)
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "有 1 个文件未保存" : "有 \(dirty.count) 个文件未保存"
        alert.addButton(withTitle: "全部保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存，直接退出")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.allSatisfy { $0.save() } ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "选择 Markdown 文件或文件夹"
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    // MARK: Themes menu (rebuilt each time it opens, so new custom themes appear)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "主题" else { return }
        menu.removeAllItems()
        let store = ThemeStore.shared
        let current = store.current
        var customStarted = false
        for theme in store.themes() {
            if theme.id.hasPrefix("custom:") && !customStarted { menu.addItem(.separator()); customStarted = true }
            let item = menu.addItem(withTitle: theme.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.id
            item.state = theme == current ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制当前主题并编辑…", action: #selector(duplicateTheme), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开主题文件夹", action: #selector(openThemeFolder), keyEquivalent: "").target = self
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let theme = ThemeStore.shared.themes().first(where: { $0.id == id }) else { return }
        ThemeStore.shared.select(theme)
    }

    @objc private func duplicateTheme() {
        guard let url = ThemeStore.shared.duplicateCurrent() else { return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openThemeFolder() {
        let folder = ThemeStore.shared.customFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (name, action, key, mods) in items {
                if action == nil { menu.addItem(.separator()); continue }
                let item = menu.addItem(withTitle: name, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = mods
            }
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        submenu("Lots Markdown", [
            ("检查更新…", #selector(checkForUpdates(_:)), "", []),
            ("", nil, "", []),
            ("隐藏 Lots Markdown", #selector(NSApplication.hide(_:)), "h", .command),
            ("", nil, "", []),
            ("退出 Lots Markdown", #selector(NSApplication.terminate(_:)), "q", .command),
        ])
        submenu("文件", [
            ("打开…", #selector(openDocument(_:)), "o", .command),
            ("", nil, "", []),
            ("保存", #selector(WorkspaceWindowController.saveDocument(_:)), "s", .command),
            ("关闭", #selector(NSWindow.performClose(_:)), "w", .command),
            ("", nil, "", []),
            ("在访达中显示", #selector(WorkspaceWindowController.revealCurrentFile(_:)), "r", [.command, .shift]),
            ("拷贝完整路径", #selector(WorkspaceWindowController.copyCurrentPath(_:)), "c", [.command, .option]),
        ])
        submenu("编辑", [
            ("撤销", Selector(("undo:")), "z", .command),
            ("重做", Selector(("redo:")), "z", [.command, .shift]),
            ("", nil, "", []),
            ("剪切", #selector(NSText.cut(_:)), "x", .command),
            ("拷贝", #selector(NSText.copy(_:)), "c", .command),
            ("粘贴", #selector(NSText.paste(_:)), "v", .command),
            ("全选", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        // Find items carry NSTextFinder actions in their tags.
        let find = NSMenu(title: "查找")
        for (name, key, mods, action) in [("查找…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
                                          ("查找并替换…", "f", [.command, .option], .showReplaceInterface),
                                          ("查找下一个", "g", .command, .nextMatch),
                                          ("查找上一个", "g", [.command, .shift], .previousMatch)] {
            let item = find.addItem(withTitle: name, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
        }
        let findHolder = NSMenuItem()
        findHolder.submenu = find
        main.addItem(findHolder)
        submenu("显示", [
            ("进入编辑", #selector(WorkspaceWindowController.toggleMode(_:)), "/", .command),
            ("双屏编辑", #selector(WorkspaceWindowController.toggleSplit(_:)), "\\", .command),
            ("", nil, "", []),
            ("文件目录", #selector(WorkspaceWindowController.toggleFileTree(_:)), "0", .command),
            ("显示全部文件", #selector(WorkspaceWindowController.toggleAllFiles(_:)), ".", [.command, .shift]),
            ("文件内目录", #selector(WorkspaceWindowController.toggleOutline(_:)), "o", [.command, .shift]),
        ])
        let themes = NSMenu(title: "主题")
        themes.delegate = self
        let themesHolder = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        themesHolder.submenu = themes
        main.items.last?.submenu?.addItem(.separator())
        main.items.last?.submenu?.addItem(themesHolder)
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowHolder = NSMenuItem()
        windowHolder.submenu = window
        main.addItem(windowHolder)
        NSApp.windowsMenu = window
        return main
    }
}

trace("main")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
