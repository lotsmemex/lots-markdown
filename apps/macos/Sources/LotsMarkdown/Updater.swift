// In-app updates. The app reads update.json from the latest GitHub release (every three
// minutes while active, and whenever it becomes active). When its build number is newer,
// every window shows the yellow "有新版本 · 点击更新" bubble. A click downloads the zip and
// checks its Ed25519 signature against the public key in Info.plist (LMUpdatePublicKey)
// before unpacking, then its bundle id, build and code signature, and quits; a small script
// waits for the app to exit, swaps the bundle in place and relaunches it. Without a public
// key the updater stays off. LM_UPDATE_URL overrides the feed (a file:// URL works) for
// testing; it does not skip the signature check.

import AppKit
import CryptoKit

struct UpdateInfo: Decodable, Equatable {
    let version: String
    let build: Int
    let url: URL
    let sha256: String
    /// Standard Base64 Ed25519 signature over the zip's bytes.
    let signature: String
    let notes: String?
}

final class Updater {
    static let shared = Updater()

    enum State: Equatable { case idle, available(UpdateInfo), downloading, failed(String), ready }

    let feed = URL(string: env["LM_UPDATE_URL"] ?? "https://github.com/lotsmemex/lots-markdown/releases/latest/download/update.json")!
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    private(set) var state = State.idle { didSet { bubbles.values.forEach { $0.value?.update(state) } } }
    private var bubbles: [ObjectIdentifier: WeakBubble] = [:]
    private var checking = false
    /// Seconds between automatic checks; doubles after each failure, up to an hour.
    private var interval: TimeInterval = 180
    private var lastCheck = Date.distantPast
    private let publicKey: Curve25519.Signing.PublicKey? = (Bundle.main.object(forInfoDictionaryKey: "LMUpdatePublicKey") as? String)
        .flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    /// The verified new app bundle, swapped in when the app quits.
    private var staged: URL?

    func start() {
        guard publicKey != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, Date().timeIntervalSince(self.lastCheck) >= self.interval else { return }
            self.check()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastCheck) >= min(self.interval, 180) else { return }
            self.check()
        }
    }

    /// Fetches the feed. `report` shows the result even when there is nothing new (menu item).
    func check(report: Bool = false) {
        guard publicKey != nil else {
            if report { NSAlert(error: UpdateError(errorDescription: "这个版本没有内置更新公钥，不能自动更新。")).runModal() }
            return
        }
        guard !checking, state == .idle || isAvailable || report else { return }
        checking = true
        lastCheck = Date()
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let info = data.flatMap { try? JSONDecoder().decode(UpdateInfo.self, from: $0) }
            DispatchQueue.main.async {
                self.checking = false
                self.interval = info == nil ? min(self.interval * 2, 3600) : 180
                if let info, info.build > self.currentBuild {
                    if case .available = self.state { self.state = .available(info) }
                    else if self.state == .idle { self.state = .available(info) }
                    if report { self.install() }
                } else if report {
                    let alert = NSAlert()
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    alert.messageText = info == nil ? "检查更新失败" : "已经是最新版本"
                    alert.informativeText = info == nil ? (error?.localizedDescription ?? "更新信息无法读取。")
                        : "Lots Markdown \(version)（build \(self.currentBuild)）"
                    alert.runModal()
                }
            }
        }.resume()
    }

    private var isAvailable: Bool { if case .available = state { return true }; return false }

    /// Shows the bubble in `window` (once per window).
    func decorate(_ window: NSWindow) {
        guard let content = window.contentView, bubbles[ObjectIdentifier(window)]?.value == nil else { return }
        let bubble = UpdateBubble()
        bubble.onClick = { [weak self] in self?.bubbleClicked() }
        bubble.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bubble, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            bubble.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bubble.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        bubbles = bubbles.filter { $0.value.value != nil }
        bubbles[ObjectIdentifier(window)] = WeakBubble(value: bubble)
        bubble.update(state)
    }

    private func bubbleClicked() {
        switch state {
        case .available, .failed: install()
        case .ready: NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: Installing

    private func install() {
        let info: UpdateInfo
        switch state {
        case .available(let i): info = i
        case .failed: check(report: false); return // re-reads the feed; the bubble returns as "available"
        default: return
        }
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            state = .failed("请先把 Lots Markdown 拖进「应用程序」文件夹，再从那里打开")
            return
        }
        guard let key = publicKey else { return }
        state = .downloading
        URLSession.shared.downloadTask(with: info.url) { file, _, error in
            let result: Result<URL, Error>
            if let file {
                result = Result { try Self.verify(zip: file, info: info, key: key, newerThan: self.currentBuild) }
            } else {
                result = .failure(error ?? CocoaError(.fileReadUnknown))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let app):
                    self.staged = app
                    self.state = .ready
                    NSApp.terminate(nil) // asks about unsaved files; a cancel leaves the bubble at "重启以完成更新"
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }.resume()
    }

    struct UpdateError: LocalizedError { let errorDescription: String? }

    /// Unpacks the downloaded zip and returns the app inside once every check passes.
    private static func verify(zip: URL, info: UpdateInfo, key: Curve25519.Signing.PublicKey, newerThan current: Int) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard let signature = Data(base64Encoded: info.signature), key.isValidSignature(signature, for: data) else {
            throw UpdateError(errorDescription: "更新包的发布签名无效")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256.lowercased() else { throw UpdateError(errorDescription: "下载的文件校验不通过") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LotsMarkdownUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], "解压失败")
        let apps = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first, let bundle = Bundle(url: app) else { throw UpdateError(errorDescription: "更新包里没有应用") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError(errorDescription: "更新包不是 Lots Markdown") }
        guard let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""), build > current, build == info.build else {
            throw UpdateError(errorDescription: "更新包的版本号不对")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], "更新包的签名无效")
        return app
    }

    private static func run(_ tool: String, _ args: [String], _ failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(errorDescription: failure) }
    }

    /// Called from applicationWillTerminate: hands the swap to a script that outlives us,
    /// which relaunches the app on `reopen` (the files and folders that were open).
    func applicationWillTerminate(reopen: [URL]) {
        // Relaunch in the background when the user was working in another app.
        let open = NSApp.isActive ? "open" : "open -g"
        guard let staged else { return }
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done
        T="$1"; N="$2"; OLD="$T.old-$$"
        mv "$T" "$OLD" && if mv "$N" "$T"; then rm -rf "$OLD"; else mv "$OLD" "$T"; fi
        xattr -dr com.apple.quarantine "$T" 2>/dev/null
        shift 2
        if [ $# -gt 0 ]; then \(open) -a "$T" "$@"; else \(open) "$T"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "lm-update", target, staged.path] + reopen.map(\.path)
        try? process.run()
    }
}

private struct WeakBubble { weak var value: UpdateBubble? }

/// The yellow pill shared with 3du, Lots MemeX and Tian: centred near the top, a 7 px dot,
/// "有新版本 · **点击更新**". Hidden unless an update is available.
final class UpdateBubble: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    private static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> NSColor {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: a)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static let background = dynamic(light: hsl(48, 96, 62), dark: hsl(46, 88, 56))
    private static let ink = dynamic(light: hsl(35, 60, 16), dark: hsl(35, 60, 12))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowColor = Self.hsl(40, 60, 30, 0.28)
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = Self.hsl(20, 85, 45).cgColor
        for view in [dot, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = Self.background.cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole pill is one button: clicks on the text land here too.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    func update(_ state: Updater.State) {
        let (lead, action): (String, String?) = switch state {
        case .idle: ("", nil)
        case .available: ("有新版本 · ", "点击更新")
        case .downloading: ("正在下载新版本…", nil)
        case .failed: ("更新失败 · ", "点击重试")
        case .ready: ("新版本已就绪 · ", "重启完成更新")
        }
        if case .failed(let reason) = state { toolTip = reason } else if case .available(let info) = state {
            toolTip = "Lots Markdown \(info.version)" + (info.notes.map { "：\($0)" } ?? "")
        } else { toolTip = nil }
        let font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let text = NSMutableAttributedString(string: lead, attributes: [.font: font, .foregroundColor: Self.ink])
        if let action {
            text.append(NSAttributedString(string: action, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .bold), .foregroundColor: Self.ink,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .baselineOffset: 0,
            ]))
        }
        label.attributedStringValue = text
        trace("update bubble: \(text.string)")
        setAccessibilityLabel(text.string)
        let show = state != .idle
        if show && isHidden { rise() }
        isHidden = !show
        window?.invalidateCursorRects(for: self)
    }

    /// Fades in while moving up a few points over 0.25 s.
    private func rise() {
        guard let layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -6
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "rise")
    }
}
