import Foundation
import Testing
@testable import SelectedCore

/// 指标黄金夹具的加载与比对
///
/// ## 夹具从哪来、为什么可信
/// `Fixtures/indicator_golden/<分类>/<指标>.csv` 下载自 Go 库 `cinar/indicator` 的
/// testdata（`scripts/fetch_indicator_golden.sh`，幂等可重跑）。表头 = `输入列…,期望输出列…`。
/// 我们**只拿数值事实**（公开公式的输入→输出），实现全部 clean-room 独立编写
/// （该库 v2 是 AGPLv3/商业双许可，源码一行不翻译）。
///
/// ## 比对口径（两条都写在明处）
///   1. **夹具值四舍五入到 2 位小数**（生成端 `RoundDigits(…, 2)`）→ 容差钉 `0.005 + 1e-9`，
///      更小的差是"舍入方向"、不是算错。
///   2. **预热段在夹具里是 0 占位**（channel 未出数），期望值从**首个非 0 行**起才有效
///      → 比对从该索引开始。若实现算错种子/平滑，首个有效行就会红，拦得住。
///
/// ## 夹具缺失 = 失败（不是 skip）
/// 口径同 `EntityTestSupport.FixtureMissing`：黄金夹具纳入版本管理，
/// 全新 clone 上缺文件必须是红的，"全绿但少跑"不可接受。
enum IndicatorGoldenSupport {

    struct FixtureMissing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "找不到指标黄金夹具 \(path) —— 由 `scripts/fetch_indicator_golden.sh` 下载、"
                + "已纳入版本管理；缺失说明仓库不完整或被误删"
        }
    }

    /// 解析后的夹具：列名 + 逐行数值（缺列读 0，与 Go 端 CSV→struct 行为一致）。
    struct Csv {
        let columns: [String]
        let rows: [[String: Double]]

        func column(_ name: String) -> [Double] {
            rows.map { $0[name] ?? 0 }
        }
    }

    /// 黄金比对用的 K 线（CSV 没有 Open 列时 open 落 0 —— 被测指标只吃 H/L/C/V，
    /// 0 不会被误用：`OHLCBar` 的消费方没有一处读 open）。
    struct Bar: VolumeBar {
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
    }

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/SelectedCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // SelectedApp
        .deletingLastPathComponent()      // 仓库根

    static func load(_ category: String, _ name: String) throws -> Csv {
        let relative = "SelectedApp/Tests/SelectedCoreTests/Fixtures/indicator_golden/\(category)/\(name).csv"
        let url = repoRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureMissing(path: relative)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw FixtureMissing(path: relative)
        }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        guard let headerLine = lines.first else { throw FixtureMissing(path: relative) }
        let columns = headerLine.split(separator: ",").map(String.init)
        var rows: [[String: Double]] = []
        rows.reserveCapacity(lines.count - 1)
        for line in lines.dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
            var row: [String: Double] = [:]
            for (i, col) in columns.enumerated() where i < cells.count {
                row[col] = Double(cells[i])
            }
            rows.append(row)
        }
        return Csv(columns: columns, rows: rows)
    }

    /// 用夹具的输入列构造 bars（列名按各 CSV：High/Low/Close/Volume）。
    static func bars(_ csv: Csv) -> [Bar] {
        csv.rows.map { r in
            Bar(open: r["Open"] ?? 0,
                high: r["High"] ?? 0,
                low: r["Low"] ?? 0,
                close: r["Close"] ?? 0,
                volume: r["Volume"] ?? 0)
        }
    }

    /// 逐点比对（无预热语义的序列，如 `emaSeries`）：从期望列**首个非 0 行**起，
    /// 差 ≤ 0.005+1e-9（夹具舍入到 2 位小数）。
    static func assertMatches(got: [Double], want: [Double], label: String,
                              tol: Double = 0.005 + 1e-9) {
        assertMatches(gotOpt: got.map { Optional($0) }, want: want, label: label, tol: tol)
    }

    /// `[Double?]` 版：有效段内遇 `nil` 直接算失败（"算不出来"与"值不同"都要红）。
    ///
    /// `tol` 默认按"夹具舍入到 2 位小数"钉死；若比对前对期望列做过线性换算
    /// （如 StochRSI 的 0–1 → 0–100），必须传入放大后的容差。
    static func assertMatches(gotOpt: [Double?], want: [Double], label: String,
                              tol: Double = 0.005 + 1e-9) {
        guard let start = want.firstIndex(where: { $0 != 0 }) else {
            Issue.record("\(label)：期望列全为 0，夹具疑似异常")
            return
        }
        var firstBad: String?
        var badCount = 0
        for i in start..<want.count {
            let g = i < gotOpt.count ? gotOpt[i] : nil
            if let g {
                if abs(g - want[i]) > tol {
                    if firstBad == nil { firstBad = "i=\(i) got=\(g) want=\(want[i])" }
                    badCount += 1
                }
            } else {
                if firstBad == nil { firstBad = "i=\(i) got=nil want=\(want[i])" }
                badCount += 1
            }
        }
        #expect(firstBad == nil,
                "\(label)：自首个有效行(i=\(start))起 \(badCount) 位与黄金夹具不符，首个差异 \(firstBad ?? "")")
    }
}
