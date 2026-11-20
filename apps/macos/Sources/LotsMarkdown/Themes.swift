// Preview themes: one CSS file each. Built-in themes ship in the app bundle (Themes/);
// custom themes live in ~/Library/Application Support/Lots Markdown/Themes and reload as
// soon as the file changes, so editing a theme shows up in every open preview.

import AppKit

struct Theme: Equatable {
    let id: String        // "builtin:default" or "custom:<file name>"
    let name: String
    let url: URL
}

final class ThemeStore {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("LotsThemeDidChange")
    private static let defaultsKey = "theme"

    let customFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lots Markdown/Themes", isDirectory: true)
    private(set) var css = ""
    private var watcher: DispatchSourceFileSystemObject?

    var current: Theme {
        let all = themes()
        let id = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "builtin:default"
        return all.first { $0.id == id } ?? all.first { $0.id == "builtin:default" } ?? all[0]
    }

    private init() {
        css = read(current)
        watch(current)
    }

    func themes() -> [Theme] {
        func list(_ folder: URL?, prefix: String) -> [Theme] {
            guard let folder,
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension == "css" }
                .map { Theme(id: prefix + $0.lastPathComponent, name: Self.displayName($0), url: $0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var builtin = list(Bundle.main.resourceURL?.appendingPathComponent("Themes"), prefix: "builtin:")
        if let i = builtin.firstIndex(where: { $0.id == "builtin:default.css" }) { builtin.insert(builtin.remove(at: i), at: 0) }
        return builtin.map { Theme(id: $0.id.replacingOccurrences(of: ".css", with: ""), name: $0.name, url: $0.url) }
            + list(customFolder, prefix: "custom:")
    }

    /// The `/* name: … */` comment on the first line, else the file name.
    static func displayName(_ url: URL) -> String {
        if let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 200),
           let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
           let range = line.range(of: #"/\*\s*name:\s*(.+?)\s*\*/"#, options: .regularExpression) {
            return String(line[range]).replacingOccurrences(of: #"^/\*\s*name:\s*|\s*\*/$"#, with: "", options: .regularExpression)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    func select(_ theme: Theme) {
        UserDefaults.standard.set(theme.id, forKey: Self.defaultsKey)
        css = read(theme)
        watch(theme)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Copies the current theme into the custom folder under a new name and selects it.
    func duplicateCurrent() -> URL? {
        let source = current
        try? FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        var n = 1
        var target: URL
        repeat {
            target = customFolder.appendingPathComponent("我的主题\(n == 1 ? "" : " \(n)").css")
            n += 1
        } while FileManager.default.fileExists(atPath: target.path)
        let name = target.deletingPathExtension().lastPathComponent
        let body = read(source).replacingOccurrences(of: #"^/\*\s*name:.*?\*/\n?"#, with: "", options: .regularExpression)
        do {
            try "/* name: \(name) */\n/* 复制自“\(source.name)”。保存后预览立即更新。 */\n\(body)".write(to: target, atomically: true, encoding: .utf8)
        } catch { return nil }
        if let theme = themes().first(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) { select(theme) }
        return target
    }

    private func read(_ theme: Theme) -> String {
        (try? String(contentsOf: theme.url, encoding: .utf8)) ?? ""
    }

    private func watch(_ theme: Theme) {
        watcher?.cancel()
        watcher = nil
        guard theme.id.hasPrefix("custom:") else { return }
        let fd = Darwin.open(theme.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self, self.current == theme else { return }
                let css = self.read(theme)
                if css != self.css {
                    self.css = css
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
                self.watch(theme) // editors that save atomically replace the file
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }
}
