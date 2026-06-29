// make-icon.swift — render an emoji into a macOS .iconset of PNGs.
// Usage: swift make-icon.swift 💥 AppIcon.iconset
import Cocoa

let emoji  = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "💥"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ size: Int, _ name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(size) * 0.82),
        .paragraphStyle: style,
    ]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let ts = str.size()
    str.draw(in: NSRect(x: (CGFloat(size)-ts.width)/2, y: (CGFloat(size)-ts.height)/2,
                        width: ts.width, height: ts.height))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),   (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),   (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),(256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),(512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),(1024,"icon_512x512@2x.png"),
]
for (s, n) in sizes { render(s, n) }
print("wrote \(outDir)")
