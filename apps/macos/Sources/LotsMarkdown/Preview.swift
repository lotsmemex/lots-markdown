// The rendered pane. The document is untrusted: page JavaScript is off, links open outside
// the WebView. The app itself still drives the page (body updates, scroll sync) through
// evaluateJavaScript in its own content world, which allowsContentJavaScript does not block.

import AppKit
import WebKit

final class PreviewPane: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var baseURL: URL?
    private var loaded = false
    private var pendingScroll: Int?
    private var renderGeneration = 0
    private let world = WKContentWorld.defaultClient
    var onFirstLoad: (() -> Void)?

    static let css: String = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    /// Renders `data` off the main thread and shows it. A file in another folder reloads the
    /// page (new base URL for relative images); otherwise only the body is replaced, which
    /// keeps the scroll position and avoids a flash.
    func show(_ data: Data, baseURL: URL) {
        renderGeneration += 1
        let generation = renderGeneration
        let started = secondsSinceProcessStart()
        DispatchQueue.global(qos: .userInitiated).async {
            let body = Renderer.previewBody(data)
            let rendered = secondsSinceProcessStart()
            DispatchQueue.main.async {
                guard generation == self.renderGeneration else { return }
                bench(["event": "rendered", "render_ms": (rendered - started) * 1000, "file_bytes": data.count])
                self.apply(body, baseURL: baseURL)
            }
        }
    }

    private func apply(_ body: String, baseURL: URL) {
        if loaded && baseURL == self.baseURL {
            webView.callAsyncJavaScript("document.body.innerHTML = html; window.__lm = null;",
                                        arguments: ["html": body], in: nil, in: world)
            return
        }
        self.baseURL = baseURL
        loaded = false
        let page = "<!doctype html><html><head><meta charset=utf-8><style>\(Self.css)</style></head><body>\(body)</body></html>"
        webView.loadHTMLString(page, baseURL: baseURL)
    }

    /// Scrolls so the block containing UTF-8 byte `offset` of the source sits at the top,
    /// interpolated inside the block.
    func scroll(toSourceOffset offset: Int) {
        guard loaded else { pendingScroll = offset; return }
        let js = """
        const els = window.__lm || (window.__lm = Array.from(document.querySelectorAll('[data-src-start]')));
        let lo = 0, hi = els.length - 1, hit = -1;
        while (lo <= hi) { const mid = (lo + hi) >> 1; if (+els[mid].dataset.srcStart <= offset) { hit = mid; lo = mid + 1; } else hi = mid - 1; }
        if (hit < 0) { window.scrollTo(0, 0); return; }
        const el = els[hit], s = +el.dataset.srcStart, e = +el.dataset.srcEnd;
        const r = el.getBoundingClientRect();
        const f = e > s ? Math.min(1, Math.max(0, (offset - s) / (e - s))) : 0;
        window.scrollTo(0, r.top + window.scrollY + f * r.height - 16);
        """
        webView.callAsyncJavaScript(js, arguments: ["offset": offset], in: nil, in: world)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let offset = pendingScroll { pendingScroll = nil; scroll(toSourceOffset: offset) }
        bench(["event": "preview_ready", "since_start_ms": secondsSinceProcessStart() * 1000])
        onFirstLoad?()
        onFirstLoad = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
            return
        }
        // In-page anchors (footnotes, headings) stay in the preview.
        if target.fragment != nil, target.isFileURL, target.path == baseURL?.path {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if ["http", "https", "mailto"].contains(target.scheme ?? "") || target.isFileURL {
            NSWorkspace.shared.open(target)
        }
    }
}
