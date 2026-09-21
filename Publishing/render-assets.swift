import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let assets = root.appendingPathComponent("Publishing/assets")
let resources = root.appendingPathComponent("RainbowKeyboardPrefs/Resources")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func render(_ width: Int, _ height: Int, _ body: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func text(_ string: String, _ rect: CGRect, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
          _ ink: NSColor = .white) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    (string as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink, .paragraphStyle: paragraph
    ])
}
func image(_ image: NSImage, _ rect: CGRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

let icon = render(1024, 1024) {
    color(0x050507).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    let palette: [UInt32] = [0x5CE7FF, 0x7BF2BF, 0xF6E87F, 0xFFAC87, 0xFF7FBA, 0xAB9CFF]
    var faces: [(CGRect, Int)] = []
    for row in 0..<2 {
        for column in 0..<3 {
            faces.append((CGRect(x: 182 + column * 226, y: 224 + row * 220, width: 208, height: 200),
                row * 3 + column))
        }
    }
    faces.append((CGRect(x: 294, y: 664, width: 434, height: 126), 0))
    for (rect, index) in faces {
        let outline = NSBezierPath(roundedRect: rect, xRadius: 42, yRadius: 42)
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: 30, yRadius: 30)
        outline.append(inner)
        outline.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(palette[index]).withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = .zero
        shadow.set()
        color(palette[index]).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSGradient(starting: color(palette[index]), ending: color(palette[(index + 1) % palette.count]))!
            .draw(in: rect, angle: 20)
        NSGraphicsContext.restoreGraphicsState()
    }
}
try save(icon, assets.appendingPathComponent("icon.png"))
let iconImage = NSImage(cgImage: icon.cgImage!, size: CGSize(width: 1024, height: 1024))
for (name, size) in [("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87),
                     ("PackageIcon.png", 256)] {
    try save(render(size, size) { image(iconImage, CGRect(x: 0, y: 0, width: size, height: size)) },
             resources.appendingPathComponent(name))
}
try save(render(256, 256) { image(iconImage, CGRect(x: 0, y: 0, width: 256, height: 256)) },
         assets.appendingPathComponent("icon-256.png"))

func keyboardCrop(_ name: String) -> NSImage {
    let url = root.appendingPathComponent("Publishing/reference/\(name).png")
    let source = NSBitmapImageRep(data: try! Data(contentsOf: url))!.cgImage!
    // Use only the keyboard area of the captured simulator image.
    let y = Int(Double(source.height) * 0.605)
    let crop = source.cropping(to: CGRect(x: 0, y: y, width: source.width, height: source.height - y))!
    return NSImage(cgImage: crop, size: CGSize(width: crop.width, height: crop.height))
}
let neon = keyboardCrop("neon")
let custom = keyboardCrop("colors")
let entries: [(String, String, String, NSImage, UInt32)] = [
    ("preview-neon.png", "纯黑键帽，霓虹扩散", "粗彩色边框 · 键缝背光 · 连续输入光波", neon, 0x79EAD2),
    ("preview-colors.png", "配色，由你决定", "键盘底色 · 键帽颜色 · 候选词渐变", custom, 0xF7C97D)
]
for (filename, title, subtitle, keyboard, tint) in entries {
    let preview = render(1080, 1440) {
        color(0x050507).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1080, height: 1440)).fill()
        image(iconImage, CGRect(x: 64, y: 58, width: 88, height: 88))
        text("彩虹键盘光效", CGRect(x: 174, y: 76, width: 780, height: 64), 36, .semibold)
        text(title, CGRect(x: 64, y: 204, width: 968, height: 100), 62, .semibold)
        text(subtitle, CGRect(x: 64, y: 308, width: 968, height: 64), 29, .regular, color(tint))
        let h = 1016 * keyboard.size.height / keyboard.size.width
        image(keyboard, CGRect(x: 32, y: 442, width: 1016, height: h))
        text("原生键盘 · iOS 模拟器实际渲染", CGRect(x: 64, y: 1330, width: 968, height: 42), 25, .regular, color(0xA6ABB3))
        text("画面仅展示效果，布局随系统与输入法变化。", CGRect(x: 64, y: 1375, width: 968, height: 36), 21, .regular, color(0x787F89))
    }
    try save(preview, assets.appendingPathComponent(filename))
    try save(preview, resources.appendingPathComponent(filename))
}
let banner = render(1600, 800) {
    color(0x050507).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1600, height: 800)).fill()
    image(neon, CGRect(x: 730, y: 80, width: 800, height: 800 * neon.size.height / neon.size.width))
    image(iconImage, CGRect(x: 72, y: 100, width: 160, height: 160))
    text("彩虹键盘光效", CGRect(x: 72, y: 306, width: 650, height: 100), 76, .semibold)
    text("让每一次输入，都有光。", CGRect(x: 72, y: 422, width: 650, height: 70), 38, .medium, color(0x79EAD2))
    text("纯黑键帽 / 霓虹扩散 / 自定义配色", CGRect(x: 72, y: 554, width: 660, height: 56), 26, .regular, color(0xD0D4D9))
    text("键盘画面为插件模拟器渲染", CGRect(x: 72, y: 700, width: 650, height: 40), 23, .regular, color(0x858D98))
}
try save(banner, assets.appendingPathComponent("banner.png"))
let sheet = render(1600, 1000) {
    color(0x141518).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1600, height: 1000)).fill()
    text("彩虹键盘光效 · 发布素材", CGRect(x: 66, y: 50, width: 1450, height: 65), 42, .semibold)
    image(iconImage, CGRect(x: 64, y: 180, width: 430, height: 430))
    text("Sileo 图标 · 1024 × 1024", CGRect(x: 64, y: 660, width: 460, height: 50), 26)
    image(iconImage, CGRect(x: 68, y: 762, width: 58, height: 58))
    text("设置图标 · 29 / 58 / 87 px", CGRect(x: 68, y: 850, width: 460, height: 50), 24, .regular, color(0xA6ABB3))
    for (i, entry) in entries.enumerated() {
        let screenshot = NSImage(contentsOf: assets.appendingPathComponent(entry.0))!
        image(screenshot, CGRect(x: 556 + i * 502, y: 180, width: 474, height: 632))
    }
    text("预览图使用插件实际渲染，不以概念图替代。", CGRect(x: 556, y: 850, width: 980, height: 64), 26, .regular, color(0xA6ABB3))
}
try save(sheet, assets.appendingPathComponent("brand-preview.png"))
print("Generated icons, two screenshots, banner and preview sheet.")
