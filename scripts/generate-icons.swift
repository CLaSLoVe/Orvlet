// CPU bitmap rendering; the same path supplies the editable SVG and native assets.
// Run from the repository root: swift scripts/generate-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Orvlet/Assets.xcassets")
let brand = root.appendingPathComponent("docs/brand")
let ink = CGColor(red: 48/255, green: 46/255, blue: 63/255, alpha: 1)
let pearl = CGColor(red: 0.965, green: 0.957, blue: 0.941, alpha: 1)

// A resting O: an open oval folds into a single quiet wing. No filled details.
enum Segment {
    case move(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
}
let outline: [Segment] = [
    .move(690, 292),
    .curve(620, 248, 548, 240, 480, 256),
    .curve(346, 286, 264, 408, 284, 542),
    .curve(304, 684, 440, 774, 580, 740),
    .curve(698, 712, 768, 614, 758, 486),
    .curve(694, 539, 614, 553, 544, 520),
    .curve(490, 495, 461, 449, 450, 399),
]
let svgPath = outline.map { segment -> String in
    switch segment {
    case let .move(x, y): return "M\(x) \(y)"
    case let .curve(a, b, c, d, x, y): return "C\(a) \(b) \(c) \(d) \(x) \(y)"
    }
}.joined(separator: " ")

func mark(_ c: CGContext, width: CGFloat, color: CGColor = ink) {
    c.setStrokeColor(color)
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    for segment in outline {
        switch segment {
        case let .move(x, y): c.move(to: CGPoint(x: x, y: y))
        case let .curve(a, b, d, e, x, y):
            c.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: d, y: e))
        }
    }
    c.strokePath()
}

func render(size: Int, status: Bool = false) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: CGFloat(size)/1024, y: -CGFloat(size)/1024)
    if status {
        // 14pt optical footprint on an 18pt canvas, ~1.2pt stroke at both scales.
        c.translateBy(x: 512, y: 512)
        c.scaleBy(x: 1.52, y: 1.52)
        c.translateBy(x: -520, y: -500)
        mark(c, width: 44, color: CGColor(gray: 0, alpha: 1))
    } else {
        c.setFillColor(pearl)
        c.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 200, cornerHeight: 200, transform: nil))
        c.fillPath()
        // Optical sizing preserves the fine stroke without losing the 16px asset.
        mark(c, width: max(30, 1024 / CGFloat(size) * 1.05))
    }
    return c.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}
func manifest(_ images: [[String: String]], at url: URL, template: Bool = false) throws {
    var object: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if template { object["properties"] = ["template-rendering-intent": "template"] }
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url.appendingPathComponent("Contents.json"))
}

var icons = [[String: String]]()
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        try writePNG(render(size: points * scale), to: assets.appendingPathComponent("AppIcon.appiconset/\(filename)"))
        icons.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
try manifest(icons, at: assets.appendingPathComponent("AppIcon.appiconset"))
var status = [[String: String]]()
for scale in [1, 2] {
    let filename = "status@\(scale)x.png"
    try writePNG(render(size: 18 * scale, status: true), to: assets.appendingPathComponent("StatusMark.imageset/\(filename)"))
    status.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
}
try manifest(status, at: assets.appendingPathComponent("StatusMark.imageset"), template: true)
try writePNG(render(size: 512), to: brand.appendingPathComponent("orvlet-icon.png"))
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <title>Orvlet — a calm agent</title>
  <desc>A resting O drawn with one continuous fine line, folding inward like a quiet wing.</desc>
  <path d="\(svgPath)" fill="none" stroke="#302e3f" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""
try svg.write(to: brand.appendingPathComponent("orvlet-mark.svg"), atomically: true, encoding: .utf8)
let statusSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18">
  <title>Orvlet menu bar mark</title>
  <g transform="translate(9 9) scale(0.02671875) translate(-520 -500)">
    <path d="\(svgPath)" fill="none" stroke="currentColor" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>
  </g>
</svg>
"""
try statusSVG.write(to: brand.appendingPathComponent("orvlet-status.svg"), atomically: true, encoding: .utf8)
print("Generated fine-line app icons, menu-bar templates, and editable SVG masters.")

// A reproducible presentation sheet with actual-size menu-bar specimens.
let proof = CGContext(data: nil, width: 1800, height: 1040, bitsPerComponent: 8, bytesPerRow: 1800 * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
proof.translateBy(x: 0, y: 1040)
proof.scaleBy(x: 2, y: -2)
proof.setFillColor(CGColor(red: 0.985, green: 0.981, blue: 0.973, alpha: 1))
proof.fill(CGRect(x: 0, y: 0, width: 900, height: 520))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: proof, flipped: true)
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor = NSColor(cgColor: ink)!) {
    (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: color])
}
func specimen(_ image: CGImage, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, tint: CGColor? = nil) {
    proof.saveGState()
    proof.translateBy(x: x, y: y + size)
    proof.scaleBy(x: 1, y: -1)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    if let tint {
        proof.clip(to: rect, mask: image)
        proof.setFillColor(tint)
        proof.fill(rect)
    } else { proof.draw(image, in: rect) }
    proof.restoreGState()
}
label("ORVLET  /  IDENTITY", 52, 35, size: 10, color: .secondaryLabelColor)
proof.saveGState()
proof.translateBy(x: 30, y: 72)
proof.scaleBy(x: 0.29, y: 0.29)
mark(proof, width: 30)
proof.restoreGState()
label("orvlet", 337, 165, size: 56)
label("a calm agent", 341, 237, size: 19, color: .secondaryLabelColor)
specimen(render(size: 256), 669, 129, 142)
label("APP ICON", 704, 288, size: 9, color: .secondaryLabelColor)
proof.setStrokeColor(CGColor(gray: 0.2, alpha: 0.10))
proof.setLineWidth(0.5)
proof.move(to: CGPoint(x: 52, y: 335))
proof.addLine(to: CGPoint(x: 848, y: 335))
proof.strokePath()
label("MENU BAR  /  18 PT", 52, 362, size: 10, color: .secondaryLabelColor)
let statusImage = render(size: 36, status: true)
for (x, dark) in [(CGFloat(52), false), (CGFloat(463), true)] {
    let color = dark ? CGColor(red: 0.17, green: 0.16, blue: 0.20, alpha: 1) : CGColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1)
    proof.setFillColor(color)
    proof.addPath(CGPath(roundedRect: CGRect(x: x, y: 389, width: 385, height: 48), cornerWidth: 10, cornerHeight: 10, transform: nil))
    proof.fillPath()
    let foreground = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(cgColor: ink)!
    specimen(statusImage, x + 218, 404, 18, tint: foreground.cgColor)
    label("100%", x + 251, 406, size: 11, color: foreground)
    label("09:41", x + 319, 406, size: 11, color: foreground)
}
label("One continuous line. A quieter presence.", 52, 470, size: 12, color: .secondaryLabelColor)
NSGraphicsContext.restoreGraphicsState()
try writePNG(proof.makeImage()!, to: brand.appendingPathComponent("orvlet-identity.png"))
