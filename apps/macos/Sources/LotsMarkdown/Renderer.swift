// Markdown → HTML fragment. Calls the temporary apps/render-stub until core/ ships its
// UniFFI binding; the contract (block-level data-src-start/end UTF-8 byte ranges, inert
// document HTML) is in AGENTS.md.

import Foundation

enum Renderer {
    /// Documents above this size preview only their first `previewPrefixBytes`.
    static let largeFileBytes = 16 * 1024 * 1024
    static let previewPrefixBytes = 2 * 1024 * 1024

    static func html(_ data: Data) -> String {
        data.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                  let out = lm_render_html(base, raw.count) else { return "" }
            defer { lm_free(out) }
            return String(cString: out)
        }
    }

    /// The preview body for `data`: the whole document, or for large files a prefix cut at a
    /// blank line outside fenced code (so byte offsets stay valid) and a note.
    static func previewBody(_ data: Data) -> String {
        guard data.count > largeFileBytes else { return html(data) }
        let cut = prefixEnd(data, limit: previewPrefixBytes)
        let mb = String(format: "%.0f", Double(data.count) / 1_048_576)
        return html(data.prefix(cut)) +
            "<p class=\"lm-truncated\">文件有 \(mb) MB，预览只显示开头部分。源码区可以查看和编辑全文。</p>"
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
        return best > 0 ? best : end
    }
}
