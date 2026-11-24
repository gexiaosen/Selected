import Foundation

// MARK: - 工具脚本共享色彩数学（OKLab / WCAG / Viénot–Brettel —— 单一实现）

enum ColorMath {
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ v: Double) -> Double {
        let x = max(0, min(1, v))
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func components(_ hex: UInt32) -> [Double] {
        [Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255]
    }

    static func hexString(_ hex: UInt32) -> String { String(format: "%06X", hex) }

    /// OKLab（Björn Ottosson）。返回 (L, a, b)。
    static func oklab(_ hex: UInt32) -> (Double, Double, Double) {
        let c = components(hex).map(srgbToLinear)
        let l = pow(0.4122214708 * c[0] + 0.5363325363 * c[1] + 0.0514459929 * c[2], 1.0 / 3.0)
        let m = pow(0.2119034982 * c[0] + 0.6806995451 * c[1] + 0.1073969566 * c[2], 1.0 / 3.0)
        let s = pow(0.0883024619 * c[0] + 0.2817188376 * c[1] + 0.6299787005 * c[2], 1.0 / 3.0)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040792471 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func deltaE(_ x: UInt32, _ y: UInt32) -> Double {
        let (l1, a1, b1) = oklab(x), (l2, a2, b2) = oklab(y)
        return (pow(l1 - l2, 2) + pow(a1 - a2, 2) + pow(b1 - b2, 2)).squareRoot()
    }

    static func chroma(_ hex: UInt32) -> Double {
        let (_, a, b) = oklab(hex)
        return (a * a + b * b).squareRoot()
    }

    static func hueAngle(_ hex: UInt32) -> Double {
        let (_, a, b) = oklab(hex)
        var d = atan2(b, a) * 180 / Double.pi
        if d < 0 { d += 360 }
        return d
    }

    /// Viénot–Brettel 二色觉（deuteranopia）模拟标准矩阵
    private static let deutan: [[Double]] = [[0.361744, 0.816107, -0.177852],
                                             [0.141408, 0.691454, 0.167138],
                                             [-0.027887, -0.063265, 1.091152]]

    static func simulateDeutan(_ hex: UInt32) -> UInt32 {
        let c = components(hex).map(srgbToLinear)
        var out: UInt32 = 0
        for row in deutan {
            let v = max(0, min(1, row[0] * c[0] + row[1] * c[1] + row[2] * c[2]))
            out = out << 8 | UInt32((linearToSrgb(v) * 255).rounded())
        }
        return out
    }

    static func relativeLuminance(_ hex: UInt32) -> Double {
        let c = components(hex).map(srgbToLinear)
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = relativeLuminance(a), y = relativeLuminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// 把 alpha 叠加到实底上（`Color.surface` 的合成语义：浅色叠黑、深色叠白）
    static func overlay(_ alpha: Double, over base: UInt32, lightMode: Bool) -> UInt32 {
        let src: Double = lightMode ? 0 : 255
        var out: UInt32 = 0
        for shift in [16, 8, 0] {
            let b = Double((base >> UInt32(shift)) & 0xff)
            out = out << 8 | UInt32((src * alpha + b * (1 - alpha)).rounded())
        }
        return out
    }
}
