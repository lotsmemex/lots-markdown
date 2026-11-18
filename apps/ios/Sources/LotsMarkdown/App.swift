// Lots Markdown for iOS: stage 1 viewer.
// Top left: the file button (opens the Files picker). Top right: 编辑 / 标注 / 渲染.
// Stage 1 shows the source read-only under 编辑 and the rendered page under 渲染;
// 标注 arrives with annotations.

import UIKit
import WebKit
import UniformTypeIdentifiers

func secondsSinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    var now = timeval()
    gettimeofday(&now, nil)
    return Double(now.tv_sec - info.kp_proc.p_starttime.tv_sec) + Double(now.tv_usec - info.kp_proc.p_starttime.tv_usec) / 1e6
}

let benchMode = ProcessInfo.processInfo.environment["LM_BENCH"] == "1"
func bench(_ fields: [String: Any]) {
    guard benchMode, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func renderHTML(_ data: Data) -> String {
    data.withUnsafeBytes { raw -> String in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress, let out = lm_render_html(base, raw.count) else { return "" }
        defer { lm_free(out) }
        return String(cString: out)
    }
}

let previewCSS = """
:root { color-scheme: light dark; }
body { font: 17px/1.75 -apple-system, "PingFang SC", sans-serif; margin: 1em 1.1em 3em; -webkit-text-size-adjust: 100%; }
pre, code { font: 13px/1.5 ui-monospace, Menlo, monospace; }
pre { padding: .8em 1em; overflow: auto; background: color-mix(in srgb, currentColor 6%, transparent); border-radius: 6px; }
table { border-collapse: collapse; display: block; overflow-x: auto; } th, td { border: 1px solid color-mix(in srgb, currentColor 20%, transparent); padding: .3em .6em; }
img { max-width: 100%; } blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid color-mix(in srgb, currentColor 25%, transparent); }
.lm-raw-html { white-space: pre-wrap; font: 13px/1.5 ui-monospace, Menlo, monospace; opacity: .7; }
"""

final class DocumentViewController: UIViewController, UIDocumentPickerDelegate, WKNavigationDelegate {
    private let sourceView = UITextView()
    private var webView: WKWebView?
    private let modes = UISegmentedControl(items: ["编辑", "标注", "渲染"])
    private var data = Data()
    private var fileURL: URL?
    private var opened = 0.0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain,
                                                           target: self, action: #selector(pickFile))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "目录"
        modes.setEnabled(false, forSegmentAt: 1)
        modes.selectedSegmentIndex = 2
        modes.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: modes)

        sourceView.isEditable = false
        sourceView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        sourceView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        sourceView.frame = view.bounds
        sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sourceView)
    }

    func open(_ url: URL) {
        opened = secondsSinceProcessStart()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        data = bytes
        fileURL = url
        title = url.deletingPathExtension().lastPathComponent
        sourceView.text = String(decoding: bytes, as: UTF8.self)
        sourceView.isHidden = false
        webView?.isHidden = true
        view.layoutIfNeeded()
        CATransaction.flush()
        let frame = secondsSinceProcessStart()
        bench(["event": "first_frame", "file_bytes": bytes.count, "since_start_ms": frame * 1000, "open_to_frame_ms": (frame - opened) * 1000])
        // Rendered view by default; source stays on screen until the page is ready.
        DispatchQueue.main.async { self.showRendered() }
    }

    @objc private func modeChanged() {
        if modes.selectedSegmentIndex == 2 { showRendered() } else { webView?.isHidden = true; sourceView.isHidden = false }
    }

    private func showRendered() {
        let web = webView ?? makeWebView()
        let source = data
        let started = secondsSinceProcessStart()
        DispatchQueue.global(qos: .userInitiated).async {
            let body = renderHTML(source)
            let rendered = secondsSinceProcessStart()
            let page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><style>\(previewCSS)</style><body>\(body)</body>"
            DispatchQueue.main.async {
                bench(["event": "rendered", "render_ms": (rendered - started) * 1000])
                web.loadHTMLString(page, baseURL: self.fileURL?.deletingLastPathComponent())
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.isHidden = true
        view.addSubview(web)
        webView = web
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard modes.selectedSegmentIndex == 2 else { return }
        webView.isHidden = false
        sourceView.isHidden = true
        bench(["event": "preview_ready", "since_start_ms": secondsSinceProcessStart() * 1000])
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
            return
        }
        if target.fragment != nil, target.isFileURL { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if ["http", "https", "mailto"].contains(target.scheme ?? "") { UIApplication.shared.open(target) }
    }

    @objc private func pickFile() {
        let types = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .plainText].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        urls.first.map(open)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let document = DocumentViewController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: document)
        window.makeKeyAndVisible()
        self.window = window
        if let url = options.urlContexts.first?.url {
            document.open(url)
        } else if let path = ProcessInfo.processInfo.arguments.dropFirst().first(where: { $0.hasSuffix(".md") }) {
            document.open(URL(fileURLWithPath: path))
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.first.map { document.open($0.url) }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
