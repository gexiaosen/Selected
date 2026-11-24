import XCTest
import SQLite3
@testable import SelectedCore

/// `ReadOnlyConnection.queryRows` 的**默认行解码**语义。
///
/// ## 为什么单独钉一条（2026-10-16 审查 B8 · 泛型 Store 第一片）
/// 这 10 行解码原先在 8 个 Store 里各抄一份。抄出来的分叉**评审看不出来**：
/// `IndicatorParamStore` 那份把 INTEGER 解成 `Double`，其余 7 份解成 `Int`
/// （它那列是 REAL 亲和，那个分支实际到不了 —— 但读代码的人无法据此判断）。
/// 收成一处之后，风险从"8 份各自漂"变成"1 份漂了 8 家一起错" ⇒ 必须有一条语义钉在原地。
///
/// ⚠ 重点在**跳过 NULL**：调用侧普遍写 `row["x"] as? Int ?? 0`。
///   如果把 NULL 改成塞 `NSNull`，`as? Int` 失败、`?? 0` 生效 ⇒
///   "这列没值"与"这列真的是 0"就分不开了 —— 而这在界面上不可见。
final class QueryRowsDecodeTests: XCTestCase {

    /// 临时库里造一张覆盖全部列类型的表：一行全有值、一行全 NULL
    private func makeFixtureDB() throws -> (dir: String, label: String) {
        let dir = NSTemporaryDirectory() + "SelectedDecodeTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(SQLITE_OK, sqlite3_open(dir + "/selected.sqlite3", &handle))
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE t(id INTEGER, f REAL, s TEXT, b BLOB);
        INSERT INTO t VALUES (7, 1.5, 'abc', X'DEAD');
        INSERT INTO t VALUES (NULL, NULL, NULL, NULL);
        """
        var err: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(SQLITE_OK, sqlite3_exec(handle, sql, nil, nil, &err),
                       "夹具建表失败：\(err.map { String(cString: $0) } ?? "未知")")
        return (dir, "DecodeFixture-\(UUID().uuidString)")
    }

    func testColumnTypesFollowTheOneDefaultDecoder() throws {
        let (dir, label) = try makeFixtureDB()
        let conn = ReadOnlyConnection(label: label, pathProvider: { dir })
        let rows = conn.queryRows("SELECT id, f, s, b FROM t ORDER BY rowid", [])
        defer { conn.close() }

        XCTAssertEqual(rows.count, 2)
        let full = rows[0]
        // INTEGER → **Int**（不是 Double —— 那份分叉就差在这里）
        XCTAssertEqual(full["id"] as? Int, 7)
        XCTAssertNil(full["id"] as? Double, "INTEGER 必须解成 Int；解成 Double 会让 `as? Int` 全线失效")
        XCTAssertEqual(full["f"] as? Double, 1.5)
        XCTAssertEqual(full["s"] as? String, "abc")

        // BLOB：默认解码**不猜**（落进 default → 整列跳过）。需要 BLOB 的调用方要自带 decode。
        XCTAssertNil(full["b"], "BLOB 不在默认解码的四类里 ⇒ 必须缺席，而不是给一个看起来合法的错值")

        // 全 NULL 行：四列**整列缺席**（不是 NSNull、不是空串、不是 0）
        let nulls = rows[1]
        for key in ["id", "f", "s", "b"] {
            XCTAssertNil(nulls[key], "\(key) 为 NULL 时必须整列缺席（塞 NSNull 会让 `as? Int ?? 0` 把缺值读成 0）")
        }
    }

    /// 列名来自 `sqlite3_column_name` ⇒ `AS` 别名必须生效
    /// （各处查询大量用 `SELECT COUNT(*) AS n`，认不出别名会读成 nil → "0 条"）。
    func testAliasedColumnsUseTheAlias() throws {
        let (dir, label) = try makeFixtureDB()
        let conn = ReadOnlyConnection(label: label, pathProvider: { dir })
        defer { conn.close() }
        let rows = conn.queryRows("SELECT COUNT(*) AS n FROM t", [])
        XCTAssertEqual(rows.first?["n"] as? Int, 2, "聚合列的别名没被当成键名")
    }

    /// `hasRows` 与 `queryRows` 同口径（它原先自带一个空解码器，收敛后共用同一份）。
    func testHasRowsAgreesWithQueryRows() throws {
        let (dir, label) = try makeFixtureDB()
        let conn = ReadOnlyConnection(label: label, pathProvider: { dir })
        defer { conn.close() }
        XCTAssertTrue(conn.hasRows("SELECT id FROM t WHERE id = 7"))
        XCTAssertFalse(conn.hasRows("SELECT id FROM t WHERE id = 999"))
        // 表不存在 → prepare 失败：必须 `false` 而不是崩（与"真的没有行"同形，靠日志分辨）
        XCTAssertFalse(conn.hasRows("SELECT x FROM no_such_table"))
    }
}
