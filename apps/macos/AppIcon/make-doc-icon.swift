// Draws the document icon (a page with a folded corner, the app icon on it and the file
// type underneath) at 1024×1024. Usage: swift make-doc-icon.swift <app-icon.png> <label> <out.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 4, let appIcon = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-doc-icon.swift <app-icon.png> <label> <out.png>\n".utf8))
    exit(2)
}
let label = args[2]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Page: Apple's document template proportions (about 0.78 × 0.98 of the canvas).
let page = NSRect(x: 112, y: 10, width: 800, height: 1004)
let fold: CGFloat = 230
let outline = NSBezierPath()
outline.move(to: NSPoint(x: page.minX + 40, y: page.minY))
outline.line(to: NSPoint(x: page.maxX - 40, y: page.minY))
outline.curve(to: NSPoint(x: page.maxX, y: page.minY + 40), controlPoint1: NSPoint(x: page.maxX - 18, y: page.minY), controlPoint2: NSPoint(x: page.maxX, y: page.minY + 18))
outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
outline.line(to: NSPoint(x: page.minX + 40, y: page.maxY))
outline.curve(to: NSPoint(x: page.minX, y: page.maxY - 40), controlPoint1: NSPoint(x: page.minX + 18, y: page.maxY), controlPoint2: NSPoint(x: page.minX, y: page.maxY - 18))
outline.line(to: NSPoint(x: page.minX, y: page.minY + 40))
outline.curve(to: NSPoint(x: page.minX + 40, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + 18), controlPoint2: NSPoint(x: page.minX + 18, y: page.minY))
outline.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 8
shadow.shadowOffset = NSSize(width: 0, height: -3)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 0, alpha: 0.12).setStroke()
outline.lineWidth = 3
outline.stroke()

// Folded corner.
let corner = NSBezierPath()
corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 30))
corner.curve(to: NSPoint(x: page.maxX - fold + 30, y: page.maxY - fold), controlPoint1: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 12), controlPoint2: NSPoint(x: page.maxX - fold + 12, y: page.maxY - fold))
corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
corner.close()
NSColor(white: 0.9, alpha: 1).setFill()
corner.fill()
NSColor(white: 0, alpha: 0.12).setStroke()
corner.lineWidth = 3
corner.stroke()

// App icon in the middle of the page.
let iconSide: CGFloat = 470
appIcon.draw(in: NSRect(x: page.midX - iconSide / 2, y: 380, width: iconSide, height: iconSide))

// File type label.
let style = NSMutableParagraphStyle()
style.alignment = .center
let text = NSAttributedString(string: label, attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .bold),
    .foregroundColor: NSColor(white: 0.42, alpha: 1),
    .paragraphStyle: style,
])
text.draw(in: NSRect(x: page.minX, y: 120, width: page.width, height: 190))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
