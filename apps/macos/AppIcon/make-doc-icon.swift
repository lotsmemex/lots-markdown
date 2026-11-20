// Draws a document icon at one pixel size: a white page with a folded corner and a bold
// M↓ mark, drawn as vector shapes so it stays legible at 16 px. From 64 px up a coloured
// band names the file type. Usage: make-doc-icon <label> <px> <out.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: make-doc-icon <label> <px> <out.png>\n".utf8))
    exit(2)
}
let label = args[1]
let s = CGFloat(px) / 1024 // all coordinates below are on a 1024 canvas
let small = px < 64
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: s, y: s)

// Page. Small sizes use the whole canvas width so the mark gets every pixel.
let page = small ? NSRect(x: 96, y: 16, width: 832, height: 992) : NSRect(x: 128, y: 16, width: 768, height: 992)
let fold: CGFloat = small ? 250 : 220
let r: CGFloat = 48
let outline = NSBezierPath()
outline.move(to: NSPoint(x: page.minX + r, y: page.minY))
outline.line(to: NSPoint(x: page.maxX - r, y: page.minY))
outline.appendArc(from: NSPoint(x: page.maxX, y: page.minY), to: NSPoint(x: page.maxX, y: page.minY + r), radius: r)
outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
outline.line(to: NSPoint(x: page.minX + r, y: page.maxY))
outline.appendArc(from: NSPoint(x: page.minX, y: page.maxY), to: NSPoint(x: page.minX, y: page.maxY - r), radius: r)
outline.line(to: NSPoint(x: page.minX, y: page.minY + r))
outline.appendArc(from: NSPoint(x: page.minX, y: page.minY), to: NSPoint(x: page.minX + r, y: page.minY), radius: r)
outline.close()

NSGraphicsContext.saveGraphicsState()
if !small {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.set()
}
NSColor.white.setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 0, alpha: small ? 0.45 : 0.22).setStroke()
outline.lineWidth = small ? 1024 / CGFloat(px) : 6 // 1 px at small sizes
outline.stroke()

let corner = NSBezierPath()
corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
corner.close()
NSColor(white: 0.82, alpha: 1).setFill()
corner.fill()
corner.lineWidth = outline.lineWidth
corner.lineJoinStyle = .round
corner.stroke()

// Type band along the bottom of the page.
let ink = NSColor(white: 0.12, alpha: 1)
let bandColor: NSColor = switch label {
case "MD": ink
case "SRT": NSColor(srgbRed: 0.16, green: 0.42, blue: 0.80, alpha: 1)
default: NSColor(white: 0.45, alpha: 1)
}
var markBox = small ? NSRect(x: page.minX + 50, y: 230, width: page.width - 100, height: 470)
                    : NSRect(x: page.minX + 90, y: 400, width: page.width - 180, height: 360)
if !small {
    let band = NSRect(x: page.minX, y: page.minY + 70, width: page.width, height: 220)
    bandColor.setFill()
    band.fill()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: 160, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
    ])
    let h = text.size().height
    text.draw(in: NSRect(x: band.minX, y: band.midY - h / 2, width: band.width, height: h))
} else if label != "MD" {
    // Small icons have no room for text: a coloured strip still tells the types apart.
    bandColor.setFill()
    NSRect(x: page.minX, y: page.minY + 40, width: page.width, height: 120).fill()
    markBox.origin.y += 40
}

// M↓: the Markdown mark. Width ratio M : gap : arrow ≈ 1.25 : 0.12 : 0.9 of the height.
let h = markBox.height
let stroke = h * (small ? 0.3 : 0.27)
// Small sizes narrow the glyphs so the mark can be taller.
let mW = h * (small ? 1.0 : 1.2), aW = h * (small ? 0.68 : 0.92), gap = h * (small ? 0.1 : 0.14)
let total = mW + gap + aW
let scale = min(1, markBox.width / total)
let x0 = markBox.midX - total * scale / 2, y0 = markBox.midY - h * scale / 2
ctx.saveGState()
ctx.translateBy(x: x0, y: y0)
ctx.scaleBy(x: scale, y: scale)
ink.setFill()
let m = NSBezierPath()
m.move(to: NSPoint(x: 0, y: 0))
m.line(to: NSPoint(x: 0, y: h))
m.line(to: NSPoint(x: stroke, y: h))
m.line(to: NSPoint(x: mW / 2, y: h * 0.48))
m.line(to: NSPoint(x: mW - stroke, y: h))
m.line(to: NSPoint(x: mW, y: h))
m.line(to: NSPoint(x: mW, y: 0))
m.line(to: NSPoint(x: mW - stroke, y: 0))
m.line(to: NSPoint(x: mW - stroke, y: h * 0.58))
m.line(to: NSPoint(x: mW / 2, y: h * 0.1))
m.line(to: NSPoint(x: stroke, y: h * 0.58))
m.line(to: NSPoint(x: stroke, y: 0))
m.close()
m.fill()
let ax = mW + gap
let shaft = aW * 0.34, head = h * 0.46
let a = NSBezierPath()
a.move(to: NSPoint(x: ax + (aW - shaft) / 2, y: h))
a.line(to: NSPoint(x: ax + (aW + shaft) / 2, y: h))
a.line(to: NSPoint(x: ax + (aW + shaft) / 2, y: head))
a.line(to: NSPoint(x: ax + aW, y: head))
a.line(to: NSPoint(x: ax + aW / 2, y: 0))
a.line(to: NSPoint(x: ax, y: head))
a.line(to: NSPoint(x: ax + (aW - shaft) / 2, y: head))
a.close()
a.fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
