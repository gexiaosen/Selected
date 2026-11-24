import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 视觉快照像素对比（不依赖 Python / ImageMagick）。
///
/// 用法:
///   image_diff <baseline.png> <actual.png> [ignoreTop] [ignoreLeft] [thresholdPercent] [diffOut.png]
///
/// 跳过顶部/左侧区域（时间戳、侧栏状态等动态内容），其余像素按 RGB 差值和判定。
/// 差异比例超过 thresholdPercent 时 exit 1；可输出红色高亮 diff 图。

private struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private func loadBitmap(_ path: String) -> Bitmap? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Bitmap(width: width, height: height, pixels: pixels)
}

private func writeBitmap(_ bitmap: Bitmap, to path: String) {
    guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData),
          let image = CGImage(width: bitmap.width, height: bitmap.height,
                              bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bitmap.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else { return }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: image_diff baseline.png actual.png [ignoreTop] [ignoreLeft] [threshold%] [diffOut.png]\n".utf8))
    exit(2)
}

let baselinePath = args[1]
let actualPath = args[2]
let ignoreTop = max(0, args.count > 3 ? Int(args[3]) ?? 0 : 0)
let ignoreLeft = max(0, args.count > 4 ? Int(args[4]) ?? 0 : 0)
let threshold = max(0, args.count > 5 ? Double(args[5]) ?? 0.2 : 0.2)
let diffPath = args.count > 6 ? args[6] : ""

guard var baseline = loadBitmap(baselinePath), let actual = loadBitmap(actualPath) else {
    FileHandle.standardError.write(Data("cannot read image(s)\n".utf8))
    exit(1)
}
guard baseline.width == actual.width, baseline.height == actual.height else {
    FileHandle.standardError.write(Data("size mismatch \(baseline.width)x\(baseline.height) vs \(actual.width)x\(actual.height)\n".utf8))
    exit(1)
}
guard ignoreTop < baseline.height, ignoreLeft < baseline.width else {
    FileHandle.standardError.write(Data("ignore region covers whole image\n".utf8))
    exit(2)
}

var diffPixels = 0
var considered = 0
for y in ignoreTop..<baseline.height {
    for x in ignoreLeft..<baseline.width {
        let i = (y * baseline.width + x) * 4
        considered += 1
        let dr = abs(Int(baseline.pixels[i]) - Int(actual.pixels[i]))
        let dg = abs(Int(baseline.pixels[i + 1]) - Int(actual.pixels[i + 1]))
        let db = abs(Int(baseline.pixels[i + 2]) - Int(actual.pixels[i + 2]))
        if dr + dg + db > 12 {
            diffPixels += 1
            // 差异画成不透明红，叠加在 actual 上，便于直接打开看位置
            baseline.pixels[i] = 255
            baseline.pixels[i + 1] = 0
            baseline.pixels[i + 2] = 0
            baseline.pixels[i + 3] = 255
        }
    }
}

let ratio = considered > 0 ? Double(diffPixels) / Double(considered) * 100 : 0
print(String(format: "diff %d/%d px (%.3f%%), threshold %.2f%%",
             diffPixels, considered, ratio, threshold))
if !diffPath.isEmpty {
    writeBitmap(baseline, to: diffPath)
}
exit(ratio > threshold ? 1 : 0)
