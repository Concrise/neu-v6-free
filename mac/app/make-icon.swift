// 画 App 图标：蓝绿渐变圆角方块 + 白色「v6」。用法：swift make-icon.swift <输出的 .iconset 目录>
// cli.js 打包时运行，再用 iconutil 合成 AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS 图标网格：1024 里内容占 824，留出阴影的边
    let box = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: box, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(
        starting: NSColor(srgbRed: 0.13, green: 0.42, blue: 0.95, alpha: 1),
        ending: NSColor(srgbRed: 0.05, green: 0.74, blue: 0.62, alpha: 1))!.draw(in: path, angle: -60)
    let text = NSAttributedString(string: "v6", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.40, weight: .heavy), .foregroundColor: NSColor.white,
        .kern: -s * 0.01,
    ])
    let ts = text.size()
    text.draw(at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2 + s * 0.035))
    let sub = NSAttributedString(string: "免流", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.105, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ])
    let ss = sub.size()
    sub.draw(at: NSPoint(x: (s - ss.width) / 2, y: box.minY + s * 0.075))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
] {
    try draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
