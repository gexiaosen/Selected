import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// App 图标**矢量生成器** —— 样式照现版逐点量出来重绘，只把"256 位图放大冒充 1024"换成真矢量。
//
// ## 为什么要重绘（2026-10-22，老板判定）
// 源文件 `Resources/AppIcon.png` 只有 **256×256**；`AppIcon.icns` 里那枚
// `icon_512x512@2x.png`（1024）与 256 原图归一化后**平均只差 0.68/255**，
// 三个尺寸的边缘强度 3.05 / 3.25 / 3.19 基本持平 ⇒ 1024 是**拉大的**，没有细节。
// 老板要求：样式不变，重画成矢量提清晰度。
//
// ## 几何全部是量出来的（256 画布为单位，内部按 size/256 缩放）
//   · 白卡 inset 25 / 边长 206 / 圆角半径 54（半径由"顶行平段宽 98"反解：(206−98)/2）
//   · 箭头轮廓：Moore 邻域外轮廓追踪 + Douglas–Peucker(eps=2.5) → 24 个顶点
//     ⚠ 亮度阈值取 **<200**：再放宽（≥240）会连白卡自己的抗锯齿边一起抓进来，
//       轮廓会跳到卡片边缘上直接废掉（实测 240 时 bbox 顶到 y=26）。
//   · 箭头**不是纯黑**：沿"左下 (56,194) → 右上 (200,60)"线性渐变，实测中位灰 #565656 → #0F0F0F。
//     按纯黑画就已经改样式了。
//   · 立体处理（老板在 A/B/C 三版里选的 **C**）：一层朝左下的软投影 + 顶缘高光/下缘压暗。
//     投影偏移实测自"淡边像素重心 − 图形重心" = (−6, +12)。
//     ⚠ 原版看着比同面积的矢量"粗"，原因就在这层软边 —— 纯硬边矢量会显得更细更轻。
//
// ## 锯齿问题（2026-10-22）
// 预览阶段我用 PIL 画多边形，**它不做抗锯齿**，所以老板看到满边锯齿。
// 本文件用 CoreGraphics 绘制，边缘由系统抗锯齿；不要再用位图画图工具出预览图。
//
// ## 用法
//   swift gen_app_icon.swift <输出.png> [边长，默认 1024]
//   全套尺寸 + 重建 icns：见同目录 gen_app_icon.sh

let tileInset:  CGFloat = 25
let tileSize:   CGFloat = 206
let tileRadius: CGFloat = 54

/// 箭头轮廓（256 画布，图像坐标 y 向下）
let arrowPoints: [(CGFloat, CGFloat)] = [
    (185, 61), (192, 61), (199, 68), (199, 129), (187, 132), (181, 127),
    (178, 105), (146, 148), (136, 150), (111, 143), (76, 191), (69, 196),
    (61, 195), (56, 189), (56, 181), (97, 124), (111, 120), (134, 127),
    (160, 92), (138, 96), (130, 89), (131, 79), (141, 73), (184, 62),
]

/// 立体强度（顶缘提亮 / 下缘压暗 的内圈描边）。⚠ 第一版给到 2.6pt + 0.30/0.22，
/// 出图后箭头四周出现一圈可见灰边，像贴纸边 —— 原版没这么重，收到下面的值。
let bevelWidth:  CGFloat = 1.5
let bevelLight   = 0.14
let bevelDark    = 0.10

let gradStart = CGPoint(x: 56, y: 194)
let gradEnd   = CGPoint(x: 200, y: 60)
let colorLow  = (r: 0x56 / 255.0, g: 0x56 / 255.0, b: 0x56 / 255.0)   // 左下，亮一档
let colorHigh = (r: 0x0F / 255.0, g: 0x0F / 255.0, b: 0x0F / 255.0)   // 右上，压深

func cg(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
}

func arrowPath(_ s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for (i, v) in arrowPoints.enumerated() {
        let pt = CGPoint(x: v.0 * s, y: v.1 * s)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func render(size: Int, to path: String) -> Bool {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    let s = CGFloat(size) / 256
    // 翻成 y 向下的图像坐标系，让上面那批实测常量能原样用
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)

    // 1) 白卡
    let card = CGRect(x: tileInset * s, y: tileInset * s, width: tileSize * s, height: tileSize * s)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: tileRadius * s, cornerHeight: tileRadius * s, transform: nil))
    ctx.setFillColor(cg(1, 1, 1))
    ctx.fillPath()

    let arrow = arrowPath(s)

    // 2) 软投影（C 版）：CG 的 setShadow 自带抗锯齿与高斯模糊
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -6 * s, height: 12 * s),
                  blur: 5.0 * s, color: cg(18.0 / 255, 20.0 / 255, 24.0 / 255, 0.26))
    ctx.addPath(arrow)
    ctx.setFillColor(cg(0.5, 0.5, 0.5, 0.01))   // 几乎透明的填充 —— 只为把阴影"逼"出来
    ctx.fillPath()
    ctx.restoreGState()

    // 3) 主体：渐变填充，裁到箭头内
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    let colors = [cg(colorLow.r, colorLow.g, colorLow.b), cg(colorHigh.r, colorHigh.g, colorHigh.b)] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: gradStart.x * s, y: gradStart.y * s),
                               end: CGPoint(x: gradEnd.x * s, y: gradEnd.y * s),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    // 4) 立体：顶缘提亮 + 下缘压暗。做法是"把描边路径平移后在裁剪区内画一遍"——
    //    平移出界的那一半被裁掉，留下的正好是朝那一侧的内圈窄边。
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.saveGState()
    ctx.translateBy(x: -1.6 * s, y: -2.2 * s)
    ctx.addPath(arrow); ctx.setLineWidth(bevelWidth * s)
    ctx.setStrokeColor(cg(1, 1, 1, bevelLight)); ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.translateBy(x: 1.6 * s, y: 2.2 * s)
    ctx.addPath(arrow); ctx.setLineWidth(bevelWidth * s)
    ctx.setStrokeColor(cg(0, 0, 0, bevelDark)); ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: gen_app_icon.swift <输出.png> [边长]\n".data(using: .utf8)!)
    exit(2)
}
let size = args.count >= 3 ? (Int(args[2]) ?? 1024) : 1024
guard render(size: size, to: args[1]) else {
    FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
    exit(1)
}
print("已生成 \(size)×\(size) → \(args[1])")
