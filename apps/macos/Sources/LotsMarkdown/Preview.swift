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

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: ThemeStore.didChange, object: nil)
    }

    /// Swaps the theme's style element in place: no reload, scroll position kept.
    @objc private func themeChanged() {
        guard loaded else { return }
        webView.callAsyncJavaScript("document.getElementById('lm-theme').textContent = css;",
                                    arguments: ["css": ThemeStore.shared.css], in: nil, in: world)
    }

    /// Renders `data` off the main thread and shows it. A file in another folder reloads the
    /// page (new base URL for relative images); otherwise only the body is replaced, which
    /// keeps the scroll position and avoids a flash.
    func show(_ data: Data, kind: FileKind, baseURL: URL) {
        renderGeneration += 1
        let generation = renderGeneration
        let started = secondsSinceProcessStart()
        DispatchQueue.global(qos: .userInitiated).async {
            let body = Renderer.previewBody(data, kind: kind)
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
        let page = "<!doctype html><html><head><meta charset=utf-8><style>\(Self.baseCSS)</style><style id=lm-theme>\(ThemeStore.shared.css.replacingOccurrences(of: "</style", with: "<\\/style"))</style></head><body>\(body)</body></html>"
        webView.loadHTMLString(page, baseURL: baseURL)
    }

    /// Layout for plain text and subtitles; themes load after it and can override it.
    private static let baseCSS = """
    .lm-plain{white-space:pre-wrap;overflow-wrap:anywhere;margin:0 0 1em}
    .lm-cue{display:flex;gap:1em;margin:0 0 .7em}
    .lm-cue-time{flex:none;font:.82em/1.9 ui-monospace,SFMono-Regular,Menlo,monospace;opacity:.55}
    .lm-cue-text{white-space:pre-wrap;min-width:0}
    """

    /// The source byte offset at the top of the visible page, interpolated inside the block
    /// there: the inverse of scroll(toSourceOffset:). nil before the page loads.
    func topSourceOffset(_ done: @escaping (Int?) -> Void) {
        guard loaded else { done(nil); return }
        let js = """
        const els = window.__lm || (window.__lm = Array.from(document.querySelectorAll('[data-src-start]')));
        let lo = 0, hi = els.length - 1, hit = -1;
        while (lo <= hi) { const mid = (lo + hi) >> 1; if (els[mid].getBoundingClientRect().top <= 16) { hit = mid; lo = mid + 1; } else hi = mid - 1; }
        if (hit < 0) return 0;
        const el = els[hit], s = +el.dataset.srcStart, e = +el.dataset.srcEnd, r = el.getBoundingClientRect();
        const f = r.height > 0 ? Math.min(1, Math.max(0, (16 - r.top) / r.height)) : 0;
        return Math.round(s + f * (e - s));
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: world) { result in
            done((try? result.get()) as? Int ?? ((try? result.get()) as? NSNumber)?.intValue)
        }
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
        themeChanged() // the theme may have changed while the page loaded
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
