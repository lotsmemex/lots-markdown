// Document → HTML fragment. Markdown goes through core/'s UniFFI binding (renderHtml); the
// contract (block-level data-src-start/end UTF-8 byte ranges over the input, inert
// document HTML) is in AGENTS.md and core/README.md. Plain text and subtitles are laid out
// here with the same byte-range attributes, so scroll sync and the outline work for them too.

import Foundation

enum FileKind {
    case markdown, subtitle, plain

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt"]
    static let plainExtensions: Set<String> = ["txt", "text", "log", "csv", "tsv", "json", "jsonl", "yaml", "yml",
                                               "toml", "ini", "conf", "cfg", "xml", "rst", "org", "tex"]

    /// nil for files Lots Markdown does not open (images, PDFs, …).
    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { self = .markdown }
        else if Self.subtitleExtensions.contains(ext) { self = .subtitle }
        else if Self.plainExtensions.contains(ext) { self = .plain }
        else { return nil }
    }
}

enum Renderer {
    /// Documents above this size preview only their first `previewPrefixBytes`.
    static let largeFileBytes = 16 * 1024 * 1024
    static let previewPrefixBytes = 2 * 1024 * 1024

    static func html(_ data: Data, kind: FileKind) -> String {
        switch kind {
        case .markdown: return renderHtml(markdown: String(decoding: data, as: UTF8.self))
        case .subtitle: return subtitles(data)
        case .plain: return paragraphs(data)
        }
    }

    /// The preview body for `data`: the whole document, or for large files a prefix cut at a
    /// blank line outside fenced code (so byte offsets stay valid) and a note.
    static func previewBody(_ data: Data, kind: FileKind) -> String {
        guard data.count > largeFileBytes else { return html(data, kind: kind) }
        let cut = prefixEnd(data, limit: previewPrefixBytes)
        let mb = String(format: "%.0f", Double(data.count) / 1_048_576)
        return html(data.prefix(cut), kind: kind) +
            "<p class=\"lm-truncated\">文件有 \(mb) MB，阅读页只显示开头部分。按 ⌘/ 进入编辑，可以查看和修改全文。</p>"
    }

    // MARK: Plain text and subtitles

    /// Byte ranges of blank-line-separated blocks, each without its trailing newline.
    static func blocks(_ data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int? = nil
        var end = 0
        lines(data) { line, blank in
            if blank {
                if let s = start { result.append(s..<end); start = nil }
            } else {
                if start == nil { start = line.lowerBound }
                end = line.upperBound
            }
        }
        if let s = start { result.append(s..<end) }
        return result
    }

    /// Calls `body` with each line's byte range (without "\n" or "\r") and whether it is blank.
    static func lines(_ data: Data, _ body: (Range<Int>, Bool) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            var blank = true
            for i in 0...bytes.count {
                if i == bytes.count || bytes[i] == 0x0A {
                    if i == bytes.count && lineStart == i { break }
                    var end = i
                    if end > lineStart && bytes[end - 1] == 0x0D { end -= 1 }
                    body(lineStart..<end, blank)
                    lineStart = i + 1
                    blank = true
                } else if blank && bytes[i] != 0x20 && bytes[i] != 0x09 && bytes[i] != 0x0D {
                    blank = false
                }
            }
        }
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private static func text(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)], as: UTF8.self)
    }

    private static func attrs(_ range: Range<Int>) -> String {
        "data-src-start=\"\(range.lowerBound)\" data-src-end=\"\(range.upperBound)\""
    }

    static func paragraphs(_ data: Data) -> String {
        blocks(data).map { "<div class=\"lm-plain\" \(attrs($0))>\(escape(text(data, $0)))</div>" }.joined(separator: "\n")
    }

    /// SubRip and WebVTT cues as time + text rows; blocks that are not cues show as text.
    static func subtitles(_ data: Data) -> String {
        blocks(data).map { range in
            let lines = text(data, range).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }), timing <= 1 else {
                if lines.first?.hasPrefix("WEBVTT") == true { return "" }
                return "<div class=\"lm-plain\" \(attrs(range))>\(escape(lines.joined(separator: "\n")))</div>"
            }
            let start = lines[timing].components(separatedBy: "-->")[0].trimmingCharacters(in: .whitespaces)
            // 00:01:02,345 → 00:01:02; WebVTT may omit the hours.
            let shown = start.split(whereSeparator: { $0 == "," || $0 == "." }).first.map(String.init) ?? start
            let body = lines[(timing + 1)...].joined(separator: "\n")
            return "<div class=\"lm-cue\" \(attrs(range))><span class=\"lm-cue-time\">\(escape(shown))</span><div class=\"lm-cue-text\">\(escape(body))</div></div>"
        }.joined(separator: "\n")
    }

    /// Byte index just after the last blank line before `limit` that is outside a fence.
    static func prefixEnd(_ data: Data, limit: Int) -> Int {
        var fence: UInt8? = nil
        var lineStart = 0
        var best = 0
        var previousBlank = false
        let end = min(data.count, limit)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < end {
                guard let nl = (i..<end).first(where: { bytes[$0] == 0x0A }) else { break }
                let line = bytes[lineStart..<nl]
                let trimmed = line.drop(while: { $0 == 0x20 })
                if trimmed.count >= 3, let c = trimmed.first, c == 0x60 || c == 0x7E,
                   trimmed.prefix(3).allSatisfy({ $0 == c }) {
                    if fence == nil { fence = c } else if fence == c { fence = nil }
                }
                let blank = line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
                if blank && fence == nil && !previousBlank { best = nl + 1 }
                previousBlank = blank
                lineStart = nl + 1
                i = nl + 1
            }
        }
        if best > 0 { return best }
        // No usable blank line: cut at `end`, backed off to a UTF-8 character boundary so
        // decoding adds no replacement character and offsets still match the file.
        var cut = end
        while cut > 0 && cut < data.count && data[data.startIndex + cut] & 0xC0 == 0x80 { cut -= 1 }
        return cut
    }
}
