import Testing
@testable import SelectedCore

/// 拖放加自选的代码提取。
/// 防的回归：把 `1234567` 截成 `123456`、把日期/版本号当代码、或"拖了没反应还不吭声"。
struct WatchDropTests {

    @Test("常见形态：纯代码 / 代码+名称 / 带市场前缀",
          arguments: [
            "600000",
            "600000 浦发银行",
            "SZ600000",
            "sh600000",
            " 600000\n",
            "代码：600000，名称：浦发银行",
            "600000",
          ])
    func extractsSixDigit(text: String) {
        #expect(WatchDrop.extractCode(from: text) == "600000")
    }

    @Test("6 位优先：同一段里既有 6 位又有 5 位时取 6 位",
          arguments: [
            "00700 与 600000",
            "600000 / 00700",
          ])
    func prefersSixDigits(text: String) {
        #expect(WatchDrop.extractCode(from: text) == "600000")
    }

    @Test("只有 5 位时取 5 位（港股）",
          arguments: ["00700", "00700 腾讯控股", "HK00700"])
    func extractsFiveDigit(text: String) {
        #expect(WatchDrop.extractCode(from: text) == "00700")
    }

    @Test("不许截断长数字 / 不许把非代码当代码",
          arguments: [
            "1234567",        // 7 位：不许截成 123456
            "20261007",       // 8 位（日期式）
            "2026-10-07",     // 日期：分段都不到 5 位
            "0.4.46",         // 版本号
            "abc",
            "",
          ])
    func rejectsNonCodes(text: String) {
        #expect(WatchDrop.extractCode(from: text) == nil)
    }

    @Test("小数形态：已知宽松（由行情校验兜底拒绝）",
          arguments: ["60000.0", "价格 12.34567 元"])
    func knownLenient(text: String) {
        // `60000.0` / `12.34567` 里的 `60000` / `34567` 会被取出 —— 这是**有意的取舍**
        //   （"前后非数字"判据简单可解释），最终由 `addWatchByCode` 的行情校验兜底拒绝。
        //   本测钉住当前行为，防"悄悄变严/变松"。
        #expect(WatchDrop.extractCode(from: text) != nil)
    }
}