import Foundation
import SQLite3
@testable import SelectedCore

private let SQLITE_TRANSIENT_T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 写库基础设施验证（SELECTED_DATA_DIR 指向临时库，绝不碰生产库）
///
/// 阶段：write / read / rollback / concurrent
@main
struct WriterTest {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures.append(label) }
        print("   \(cond ? "✅" : "❌") \(label)")
    }

    static func main() {
        let stage = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
        switch stage {
        case "bootstrap": stageBootstrap()
        case "write": stageWrite()
        case "read": stageRead()
        case "rollback": stageRollback()
        case "concurrent": stageConcurrent()
        default: stageWrite()
        }
        print("—— \(stage)：检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    /// 建临时库（**走生产启动路径**）+ 建本测试专用的 `_writer_test` 表。
    ///
    /// 临时库由驱动自己走生产启动路径建：
    ///   `DBBootstrap.ensureReady()` 与真实 App 启动同构。
    static func stageBootstrap() {
        if let e = DBBootstrap.ensureReady() {
            print("❌ DBBootstrap.ensureReady 失败：\(e)")
            failures.append("ensureReady 失败")
            return
        }
        do {
            try SQLiteWriter.shared.write { tx in
                try tx.execute("CREATE TABLE IF NOT EXISTS _writer_test("
                               + "id INTEGER PRIMARY KEY, txt TEXT, num REAL, intg INTEGER,"
                               + "flag INTEGER, nullable TEXT)")
            }
        } catch {
            print("❌ 建 _writer_test 失败：\(error)")
            failures.append("建 _writer_test 失败")
            return
        }
        print("   schema 就绪（DBBootstrap.ensureReady）")
    }

    /// 类型往返：Int / Double / String / Bool / nil 都要原样存取
    static func stageWrite() {
        do {
            try SQLiteWriter.shared.write { tx in
                try tx.execute("DELETE FROM _writer_test")
                try tx.execute(
                    "INSERT INTO _writer_test(id, txt, num, intg, flag, nullable) VALUES(?,?,?,?,?,?)",
                    [1, "中文文本 A", 3.14159, 42, true, nil])
                try tx.execute(
                    "INSERT INTO _writer_test(id, txt, num, intg, flag, nullable) VALUES(?,?,?,?,?,?)",
                    [2, "second", -0.5, -7, false, "not-null"])
                // 负数/边界
                try tx.execute(
                    "INSERT INTO _writer_test(id, txt, num, intg, flag, nullable) VALUES(?,?,?,?,?,?)",
                    [3, "", 0.0, 0, false, ""])
            }
            print("   ✅ 写入 3 行（单事务）")
            checks += 1
        } catch {
            print("   ❌ 写入失败：\(error)")
            failures.append("write")
        }
    }

    /// 读回校验 + 只读层可见性（证明 WAL 下写后读连接能立即看到）
    static func stageRead() {
        do {
            let rows = try SQLiteWriter.shared.write { tx in
                try tx.query("SELECT * FROM _writer_test ORDER BY id")
            }
            check(rows.count == 3, "写连接读回 3 行")
            if let r = rows.first {
                check((r["txt"] as? String) == "中文文本 A", "String 往返（含中文）")
                check((r["num"] as? Double).map { abs($0 - 3.14159) < 1e-9 } ?? false, "Double 往返")
                check((r["intg"] as? Int) == 42, "Int 往返")
                check((r["flag"] as? Int) == 1, "Bool→Int 往返")
                check(r["nullable"] is NSNull, "nil → NULL")
            }
            if rows.count > 1 {
                check((rows[1]["num"] as? Double).map { abs($0 + 0.5) < 1e-9 } ?? false, "负 Double 往返")
                check((rows[1]["intg"] as? Int) == -7, "负 Int 往返")
            }
        } catch {
            check(false, "读回失败：\(error)")
        }

        // 独立只读连接：等价于 UI 只读层（另一个连接读同一 WAL 库）。
        // 验证的是 WAL 的既定语义 —— 写连接提交后，其他连接**立即**能看到，
        // 不需要任何缓存失效动作。
        let viaRO = readViaIndependentConnection()
        check(viaRO == 3, "独立只读连接立即看到写连接提交的数据（WAL 可见性）")
    }

    /// 另开一个只读连接数一行（模拟 UI 的读路径）
    static func readViaIndependentConnection() -> Int? {
        guard let path = SQLiteWriter.shared.dbPath() else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM _writer_test", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 事务回滚：闭包抛错必须整体回滚，不留半截数据
    static func stageRollback() {
        do {
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute("INSERT INTO _writer_test(id, txt) VALUES(?,?)", [99, "should-rollback"])
                throw SQLiteWriteError(message: "故意失败")
            }
            check(false, "应当抛出错误")
        } catch {
            check(true, "事务内抛错 → 向上传播")
        }
        do {
            let n = try SQLiteWriter.shared.write { tx in
                try tx.query("SELECT COUNT(*) AS n FROM _writer_test WHERE id=99", [])
            }
            check((n.first?["n"] as? Int) == 0, "回滚后无残留数据（id=99 不存在）")
        } catch {
            check(false, "回滚校验查询失败：\(error)")
        }
        // 回滚后连接仍可用（后续写必须成功）
        do {
            // `_ =`：闭包单语句时 `write` 的返回值会被推断为 Int（execute 的结果），
            // 不接收会有 NoUsage 警告 —— 这里只关心事务是否抛错
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute("INSERT INTO _writer_test(id, txt) VALUES(?,?)", [100, "after-rollback"])
            }
            check(true, "回滚后连接仍可用")
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute("DELETE FROM _writer_test WHERE id=100")
            }
        } catch {
            check(false, "回滚后写入失败：\(error)")
        }
    }

    /// 并发写：多线程同时写，验证串行队列既不崩、也不丢数据
    static func stageConcurrent() {
        let group = DispatchGroup()
        let n = 60
        for i in 0..<n {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try SQLiteWriter.shared.write { tx in
                        try tx.execute("INSERT INTO _writer_test(id, txt) VALUES(?,?)",
                                       [1000 + i, "concurrent-\(i)"])
                    }
                } catch {
                    print("   ❌ 并发写失败 i=\(i)：\(error)")
                }
            }
        }
        group.wait()
        do {
            // 统计与清理都必须限定在 **id<2000**：另一进程同时在写 id=2000+，
            // 用 `id>=1000` 会把它的行算进来（偶发"60 条"校验失败），
            // 清理时还会把另一进程的行删掉（后续"40 条完整"跟着偶发失败）。
            let rows = try SQLiteWriter.shared.write { tx in
                try tx.query("SELECT COUNT(*) AS n FROM _writer_test "
                             + "WHERE id>=1000 AND id<2000", [])
            }
            let got = (rows.first?["n"] as? Int) ?? -1
            check(got == n, "并发写 \(n) 条全部落库（无丢失/无崩溃；实得 \(got)）")
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute("DELETE FROM _writer_test WHERE id>=1000 AND id<2000")
            }
        } catch {
            check(false, "并发校验失败：\(error)")
        }
    }
}
