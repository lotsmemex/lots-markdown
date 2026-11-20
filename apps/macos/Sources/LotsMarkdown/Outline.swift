// The in-file table of contents: headings parsed from the Markdown source, shown docked on
// the right, or as a draggable button that opens a draggable floating card.

import AppKit

struct Heading: Equatable {
    let level: Int
    let title: String
    /// UTF-8 byte offset of the heading's first line in the source.
    let offset: Int
}

enum Headings {
    /// ATX and setext headings outside fenced code and a leading front-matter block.
    static func parse(_ data: Data) -> [Heading] {
        var result: [Heading] = []
        var fence: (char: UInt8, count: Int)? = nil
        var previous: (range: Range<Int>, paragraph: Bool)? = nil
        var frontMatter = false
        var lineIndex = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            Renderer.lines(data) { line, blank in
                defer { lineIndex += 1 }
                var i = line.lowerBound
                var indent = 0
                while i < line.upperBound && b[i] == 0x20 && indent < 4 { i += 1; indent += 1 }
                let rest = i..<line.upperBound
                if lineIndex == 0 && rest.count == 3 && b[i] == 0x2D && b[i + 1] == 0x2D && b[i + 2] == 0x2D {
                    frontMatter = true; previous = nil; return
                }
                if frontMatter {
                    if rest.count >= 3 && (b[i] == 0x2D || b[i] == 0x2E) && b[rest].allSatisfy({ $0 == b[i] }) { frontMatter = false }
                    return
                }
                // Fences: ``` or ~~~, closed by the same character at least as many times.
                if indent < 4, rest.count >= 3, b[i] == 0x60 || b[i] == 0x7E {
                    var n = 0
                    while i + n < line.upperBound && b[i + n] == b[i] { n += 1 }
                    if n >= 3 {
                        if let open = fence {
                            if open.char == b[i] && n >= open.count && b[(i + n)..<line.upperBound].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { fence = nil }
                        } else {
                            fence = (b[i], n)
                        }
                        previous = nil
                        return
                    }
                }
                if fence != nil { return }
                if blank || indent >= 4 { previous = blank ? nil : previous; return }
                // ATX: 1–6 '#' then a space, tab or end of line.
                if b[i] == 0x23 {
                    var n = 0
                    while i + n < line.upperBound && b[i + n] == 0x23 { n += 1 }
                    if n <= 6 && (i + n == line.upperBound || b[i + n] == 0x20 || b[i + n] == 0x09) {
                        var title = String(decoding: b[(i + n)..<line.upperBound], as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces)
                        // Closing sequence: trailing '#'s preceded by a space.
                        if let r = title.range(of: "(^|\\s)#+$", options: .regularExpression) { title.removeSubrange(r) }
                        title = plain(title)
                        if !title.isEmpty { result.append(Heading(level: n, title: title, offset: line.lowerBound)) }
                        previous = nil
                        return
                    }
                }
                // Setext: a line of '=' or '-' under a paragraph line.
                if let prev = previous, prev.paragraph, b[i] == 0x3D || b[i] == 0x2D,
                   b[rest].allSatisfy({ $0 == b[i] || $0 == 0x20 || $0 == 0x09 }) {
                    let title = plain(String(decoding: b[prev.range], as: UTF8.self).trimmingCharacters(in: .whitespaces))
                    if !title.isEmpty { result.append(Heading(level: b[i] == 0x3D ? 1 : 2, title: title, offset: prev.range.lowerBound)) }
                    previous = nil
                    return
                }
                // A paragraph line can carry a setext underline; list items, quotes and tables cannot.
                let c = b[i]
                let startsBlock = c == 0x3E || c == 0x7C || ((c == 0x2D || c == 0x2A || c == 0x2B) && i + 1 < line.upperBound && b[i + 1] == 0x20)
                previous = (line, !startsBlock)
            }
        }
        return result
    }

    /// Drops common inline syntax: emphasis markers, code ticks, link targets.
    static func plain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`~]|==", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// The heading list. Clicking a row calls `onSelect`.
final class OutlineList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private(set) var headings: [Heading] = []
    private var minLevel = 1
    var onSelect: ((Heading) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        column.width = 190
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .small
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        table.autoresizingMask = [.width]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        documentView = table
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ headings: [Heading]) {
        guard headings != self.headings else { return }
        self.headings = headings
        minLevel = headings.map(\.level).min() ?? 1
        table.reloadData()
    }

    func highlight(_ heading: Heading?) {
        guard let heading, let row = headings.firstIndex(of: heading) else { table.deselectAll(nil); return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        onSelect?(headings[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("heading")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            let lead = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4)
            lead.identifier = "lead"
            NSLayoutConstraint.activate([lead, text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                         text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }()
        let heading = headings[row]
        let depth = heading.level - minLevel
        cell.textField?.stringValue = heading.title
        cell.textField?.toolTip = heading.title
        cell.textField?.font = .systemFont(ofSize: 12, weight: depth == 0 ? .medium : .regular)
        cell.textField?.textColor = depth == 0 ? .labelColor : .secondaryLabelColor
        cell.constraints.first { $0.identifier == "lead" }?.constant = 4 + CGFloat(depth) * 12
        return cell
    }
}

/// A rounded panel the user drags anywhere inside its superview. A click that does not
/// move it calls `onClick`; dragging starts anywhere except on a control.
final class FloatingPanel: NSView {
    let box = NSBox()
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.boxType = .custom
        box.cornerRadius = 9
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = .zero
        box.frame = bounds
        box.autoresizingMask = [.width, .height]
        addSubview(box)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow, frame.origin)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let parent = superview else { return }
        let dx = event.locationInWindow.x - start.mouse.x, dy = event.locationInWindow.y - start.mouse.y
        if abs(dx) + abs(dy) > 3 { moved = true; NSCursor.closedHand.set() }
        setFrameOrigin(Self.clamp(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy), size: frame.size, in: parent.bounds))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if moved { onMoved?() } else { onClick?() }
    }

    static func clamp(_ origin: NSPoint, size: NSSize, in bounds: NSRect) -> NSPoint {
        NSPoint(x: min(max(bounds.minX + 4, origin.x), bounds.maxX - size.width - 4),
                y: min(max(bounds.minY + 4, origin.y), bounds.maxY - size.height - 4))
    }
}
