// 生成 dmg 挂载窗口的背景图（纯 AppKit 绘制，无第三方依赖，结果可复现）。
//
// 为什么脚本化而不是手画：窗口尺寸、图标落位、箭头几何与文字基线之间是数字关系，
// 改一版尺寸就全歪；写成代码后 `swiftc` 跑一次即可重新出图。
//
//   swiftc -O SelectedApp/Scripts/make-dmg-background.swift -o /tmp/mkdmgbg && /tmp/mkdmgbg
//
// 画布 600×360 pt、@2x 导出（1200×720 px）。图标位置与 make-dmg-layout.sh 里
// 写进 .DS_Store 的坐标必须一致：app 在 (150,160)、Applications 在 (450,160)。
import AppKit

let appRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Scripts/
    .deletingLastPathComponent()   // SelectedApp/
let out = appRoot.appendingPathComponent("Resources/DMG/background.png")

let width: CGFloat = 600
let height: CGFloat = 360
let scale: CGFloat = 2

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 底色：极浅的冷灰渐变，和面板的玻璃质感同族，图标压在什么位置都不打架。
// 三段落色而不是"底色 + 叠一层高光矩形"：两段拼接会在接缝处显出一道横线。
NSGradient(colorsAndLocations: (color(0xFFFFFF), 0),
                                   (color(0xF7F9FD), 0.45),
                                   (color(0xE7EBF3), 1))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// 图标落位不画槽位框：真图标 128pt 会盖住大半，露出的边框反而像没对齐。

// 中间的箭头：从 app 指向 Applications。单条闭合路径 + 圆角描边，
// 免得杆与头部各画一次、接缝处露出白芯。
let midY = height - 160
// 实色而不是半透明：alpha 叠在描边/填充交界处会显出一道浅边。
let accent = color(0x7E9BD4)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 244, y: midY - 5))
arrow.line(to: NSPoint(x: 326, y: midY - 5))
arrow.line(to: NSPoint(x: 326, y: midY - 17))
arrow.line(to: NSPoint(x: 352, y: midY))
arrow.line(to: NSPoint(x: 326, y: midY + 17))
arrow.line(to: NSPoint(x: 326, y: midY + 5))
arrow.line(to: NSPoint(x: 244, y: midY + 5))
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineCapStyle = .round
arrow.lineWidth = 9
accent.setFill()
accent.setStroke()
arrow.fill()
arrow.stroke()

// 文案：中文主行 + 英文副行，居中。
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, tint: NSColor,
          centerY: CGFloat, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: tint,
        .kern: tracking,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let box = string.size()
    string.draw(at: NSPoint(x: (width - box.width) / 2, y: centerY))
}

draw("将 Selected 拖入「应用程序」", size: 14, weight: .medium,
     tint: color(0x4A5160), centerY: 92, tracking: 0.2)
draw("Drag Selected into Applications", size: 11, weight: .regular,
     tint: color(0x8A93A3), centerY: 72, tracking: 0.1)

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: out)
print(out.path)
