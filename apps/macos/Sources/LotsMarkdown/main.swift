// Lots Markdown for macOS: v0 viewer prototype.
// AppKit only on the launch path. The source text shows first; the preview
// (WKWebView) is created after the first frame so it never delays opening.

import AppKit
import WebKit

// MARK: - Timing

/// Seconds since this process started (kernel start time), for launch measurements.
func secondsSinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    let start = info.kp_proc.p_starttime
    var now = timeval()
    gettimeofday(&now, nil)
    return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1e6
}

let env = ProcessInfo.processInfo.environment
let benchMode = env["LM_BENCH"] == "1"
let useTextKit1 = env["LM_TEXTKIT"] == "1"

func mark(_ label: String) { if env["LM_TRACE"] == "1" { FileHandle.standardError.write(Data(String(format: "%7.1f ms  %@\n", secondsSinceProcessStart() * 1000, label).utf8)) } }

func bench(_ fields: [String: Any]) {
    guard benchMode, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    FileHandle.standardError.write(data + Data("\n".utf8))
}

// MARK: - Rendering (temporary stub until core/ ships its FFI)

func renderHTML(_ data: Data) -> String {
    data.withUnsafeBytes { raw -> String in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress, let out = lm_render_html(base, raw.count) else { return "" }
        defer { lm_free(out) }
        return String(cString: out)
    }
}

let previewCSS = """
:root { color-scheme: light dark; }
body { font: 16px/1.75 -apple-system, "PingFang SC", sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1.5em; }
pre, code { font: 13px/1.5 ui-monospace, Menlo, monospace; }
pre { padding: .8em 1em; overflow: auto; background: color-mix(in srgb, currentColor 6%, transparent); border-radius: 6px; }
table { border-collapse: collapse; } th, td { border: 1px solid color-mix(in srgb, currentColor 20%, transparent); padding: .3em .6em; }
img { max-width: 100%; } blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid color-mix(in srgb, currentColor 25%, transparent); }
"""

// MARK: - Document window

final class DocumentWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    let url: URL
    let data: Data
    let opened: Double
    private let split = NSSplitView()
    private var preview: WKWebView?

    init(url: URL) throws {
        opened = secondsSinceProcessStart()
        self.url = url
        mark("open")
        data = try Data(contentsOf: url, options: .alwaysMapped)
        mark("read")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        mark("window")
        window.title = url.lastPathComponent
        window.representedURL = url
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        let source = makeSourceView()
        mark("textview")
        split.addArrangedSubview(source)
        window.contentView = split
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeSourceView() -> NSScrollView {
        let scroll: NSScrollView
        let text: NSTextView
        if useTextKit1 {
            text = NSTextView(usingTextLayoutManager: false)
            text.layoutManager?.allowsNonContiguousLayout = true
            scroll = NSScrollView()
            scroll.documentView = text
            text.autoresizingMask = [.width]
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
        } else {
            scroll = NSTextView.scrollableTextView()
            text = scroll.documentView as! NSTextView
        }
        scroll.hasVerticalScroller = true
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.string = String(decoding: data, as: UTF8.self)
        return scroll
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        mark("ordered front")
        window?.displayIfNeeded()
        mark("displayed")
        CATransaction.flush()
        let firstFrame = secondsSinceProcessStart()
        bench(["event": "first_frame", "file_bytes": data.count, "since_start_ms": firstFrame * 1000,
               "open_to_frame_ms": (firstFrame - opened) * 1000, "textkit": useTextKit1 ? 1 : 2])
        // The preview never blocks the first frame.
        DispatchQueue.main.async { self.attachPreview() }
    }

    private func attachPreview() {
        let config = WKWebViewConfiguration()
        // The document is untrusted: no scripts in the preview, and links leave the WebView.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        preview = web
        split.addArrangedSubview(web)
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        let started = secondsSinceProcessStart()
        let source = data
        DispatchQueue.global(qos: .userInitiated).async {
            let body = renderHTML(source)
            let rendered = secondsSinceProcessStart()
            let page = "<!doctype html><meta charset=utf-8><style>\(previewCSS)</style><body>\(body)</body>"
            DispatchQueue.main.async {
                bench(["event": "rendered", "render_ms": (rendered - started) * 1000, "html_bytes": page.utf8.count])
                web.loadHTMLString(page, baseURL: self.url.deletingLastPathComponent())
            }
        }
    }

    @objc func togglePreview(_ sender: Any?) {
        guard let web = preview else { return }
        web.isHidden.toggle()
        split.adjustSubviews()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
            return
        }
        if target.fragment != nil, target.isFileURL, target.path == url.deletingLastPathComponent().path {
            decisionHandler(.allow) // footnote and heading anchors
            return
        }
        decisionHandler(.cancel)
        if ["http", "https", "mailto"].contains(target.scheme ?? "") || target.isFileURL {
            NSWorkspace.shared.open(target)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bench(["event": "preview_ready", "since_start_ms": secondsSinceProcessStart() * 1000])
        if env["LM_BENCH_EXIT"] == "1" { exit(0) }
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.windows.removeAll { $0 === self }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var windows: [DocumentWindowController] = []

    func open(_ url: URL) {
        do {
            let controller = try DocumentWindowController(url: url)
            windows.append(controller)
            controller.present()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        mark("will finish launching")
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出 Lots Markdown", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        fileItem.submenu = NSMenu(title: "文件")
        fileItem.submenu?.addItem(withTitle: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileItem.submenu?.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: "显示")
        viewItem.submenu?.addItem(withTitle: "显示/隐藏预览", action: #selector(DocumentWindowController.togglePreview(_:)), keyEquivalent: "\\")
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"), ("查找…", "performFindPanelAction:", "f")] {
            let item = editItem.submenu!.addItem(withTitle: title, action: Selector(title == "查找…" ? "performTextFinderAction:" : action), keyEquivalent: key)
            if title == "查找…" { item.tag = NSTextFinder.Action.showFindInterface.rawValue }
        }
        [appItem, fileItem, editItem, viewItem].forEach(menu.addItem)
        NSApp.mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        paths.forEach { open(URL(fileURLWithPath: $0)) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    // Closing the last window keeps the app running, so the next open skips process launch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

mark("main")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
