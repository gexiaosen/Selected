#!/bin/bash
# 全量回归测试套件执行清单（由 engine/tests/run_all.sh source，不单独直接运行）

# Core 单元测试（`swift test`）：纯函数级单元测试（数值口径 / 取值语义 / 参数校验契约 / 分层约束）。
# 与 `Tools/*.sh` 的分工：Tools = 需要真实 SQLite 库的行为自检（纯 Swift 驱动）。
# 新增纯 Core 逻辑的测试请写进 `SelectedApp/Tests/SelectedCoreTests/`，不要再往 Tools/ 加脚本。
if command -v swift >/dev/null 2>&1 && [ -d "$ROOT/SelectedApp/Tests/SelectedCoreTests" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
# ⚠ 必须用仓库**外**的 scratch path 跑 `swift test`：本仓目录受 macOS FileProvider 管理，
    # 新建目录带扩展属性，而 swift test 要给 .xctest bundle 做 ad-hoc 签名 → codesign 拒绝
    # （"resource fork, Finder information, or similar detritus not allowed"）。
    # 该错时有时无、与代码无关 —— 留在仓库内回归会变成随机红。$TMPDIR 完全避开。
    SCRATCH="${TMPDIR:-/tmp}/selected-swift-test-build"
    _run_swift_test() { ( cd "$ROOT/SelectedApp" && swift test --disable-sandbox --scratch-path "$SCRATCH" 2>&1 ); }
    out=$(_run_swift_test)
    code=$?
    # 兜底：万一还是撞上扩展属性（scratch path 被换到同步盘等），清一次 xattr 重试
    if printf '%s' "$out" | grep -c "detritus not allowed" >/dev/null; then
        xattr -cr "$SCRATCH" 2>/dev/null
        out=$(_run_swift_test)
        code=$?
    fi
    # ⚠ 两个 runner × 多测试目标（SelectedCoreTests + SelectedAppTests）各报各的：
    #   XCTest 对每个 `.xctest` bundle 输出 `Test Suite '<Target>.xctest' passed/failed` + 下一行 `Executed N tests`，
    #   Swift Testing 对每个目标输出 `Test run with N tests in M suites`。
    #   用 tail -1 会把前一个/非零目标吞掉（例如仅打印后置空目标 `0 tests`），故必须跨目标累加。
    _xctest=$(printf '%s\n' "$out" | awk '
        /Test Suite \x27[^\x27]*\.xctest\x27 (passed|failed)/ { wait_exec=1; next }
        wait_exec && /Executed [0-9]+ tests?/ {
            for (i=1; i<=NF; i++) {
                if ($i=="Executed") tests += $(i+1)
                if ($i=="with") fails += $(i+1)
            }
            targets++
            wait_exec=0
        }
        END {
            if (targets > 0) printf "Executed %d tests, with %d failures (%d targets)", tests, fails, targets
        }')
    if [ -z "$_xctest" ]; then
        _xctest=$(printf '%s\n' "$out" | grep -E 'Executed [0-9]+ tests' | tail -1 | sed 's/^[[:space:]]*//')
    fi
    _swift_testing=$(printf '%s\n' "$out" | awk '
        /Test run with [0-9]+ tests? in [0-9]+ suites?/ {
            for (i=1; i<=NF; i++) {
                if ($i=="with") tests += $(i+1)
                if ($i=="in") suites += $(i+1)
            }
            seen=1
        }
        END {
            if (seen && tests > 0) printf "Test run with %d tests in %d suites", tests, suites
        }')
    summary="${_xctest:-通过}"
    [ -n "$_swift_testing" ] && summary="${summary}  ｜  ${_swift_testing}"
    if [ "$code" -eq 0 ]; then
        echo "✅ core_unit      ${summary:-通过}"
    else
        echo "❌ core_unit      失败"
        printf '%s\n' "$out" | grep -E 'error:|: error:' | head -10 | sed 's/^/     /'
        FAILED+=("core_unit")
    fi
fi

# 写库基础设施验证（类型往返/事务回滚/并发写）
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/writer_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/writer_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ sqlite_writer   $summary"
    else
        echo "❌ sqlite_writer   失败"
        printf '%s\n' "$out" | grep -E '^   ❌' | head -10 | sed 's/^/     /'
        FAILED+=("sqlite_writer")
    fi
fi

# 历史回放真实库自检（隔离规则 / reviews.scan_mode 的 DEFAULT 语义 / 断点续传 / secid 口径；
# 库在 $TMP 现造，全程离线）
# 必须在真库上：这些断言要真连接与可切换的数据目录，而 XCTest 里换数据目录会写错库
# （PhaseStore / SQLiteWriter 的句柄是进程级缓存的）。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/history_replay_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/history_replay_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '全部通过|检查 [0-9]+ 项|❌' | tail -1 \
        | sed 's/^✅ history_replay *//')
    if [ "$code" -eq 0 ]; then
        echo "✅ history_replay $summary"
    else
        echo "❌ history_replay 失败"
        printf '%s\n' "$out" | grep -E '^   |❌' | head -10 | sed 's/^/     /'
        FAILED+=("history_replay")
    fi
fi

# 分类标签真实库自检（指数成份 / 基本面：建表 / 整表替换 / 反查 / 下界护栏 / 清空；全程离线）
# 必须在真库上：核心不变量「抓回来的数量不够就不写库」要读回旧数据证明"一条没动"。
# ⚠ 抓取闭包由驱动注入，本项不打网络。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/classify_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/classify_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '全部通过|检查 [0-9]+ 项|❌' | tail -1 \
        | sed 's/^✅ classify *//')
    if [ "$code" -eq 0 ]; then
        echo "✅ classify $summary"
    else
        echo "❌ classify 失败"
        printf '%s\n' "$out" | grep -E '^   |❌' | head -10 | sed 's/^/     /'
        FAILED+=("classify")
    fi
fi

# 涨停统计真实库自检（建表 / 整日重插 / 查询 / 清空；全程离线）
# 必须在真库上：「整日重插不是追加」要读回旧数据证明旧的被清掉、没留幽灵涨停股。
# ⚠ 抓取（网络）不在本项里 —— 解析由 `swift test` 用真实响应片段覆盖。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/limit_up_pool_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/limit_up_pool_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '全部通过|检查 [0-9]+ 项|❌' | tail -1 \
        | sed 's/^✅ limit_up_pool *//')
    if [ "$code" -eq 0 ]; then
        echo "✅ limit_up_pool $summary"
    else
        echo "❌ limit_up_pool 失败"
        printf '%s\n' "$out" | grep -E '^   |❌' | head -10 | sed 's/^/     /'
        FAILED+=("limit_up_pool")
    fi
fi

# 自选提醒真实库自检（建表 / 保存读回 / 触发与去重 / 状态继承 vs 重新武装 / 降级迁移 / 脏行容错）
# 必须在真库上：继承/重新武装要"写→读回→再写→再读回"，降级迁移要 DROP TABLE 再跑迁移。
# ⚠ 行情用真实响应原文经生产解析器构造，不打网络。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/alert_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/alert_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '全部通过|检查 [0-9]+ 项|❌' | tail -1 \
        | sed 's/^✅ alert *//')
    if [ "$code" -eq 0 ]; then
        echo "✅ alert $summary"
    else
        echo "❌ alert 失败"
        printf '%s\n' "$out" | grep -E '^   |❌' | head -10 | sed 's/^/     /'
        FAILED+=("alert")
    fi
fi

# 列表池缓存自检（F15 + 港股池：schema 建表 / 整表替换往返 / 7 天 TTL 命中与过期回退 /
# 主源不可用降级 / 老库缺表抛错；2 池 × 7 场景，全部离线）
# 断言在 PoolListTest.swift 内（失败非零退出），本块只做编译 + 场景调度。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/pool_list_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/pool_list_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ pool_list       $summary"
    else
        echo "❌ pool_list       失败"
        printf '%s\n' "$out" | grep -E '^   ❌' | head -10 | sed 's/^/     /'
        FAILED+=("pool_list")
    fi
fi

# 市场标识自检（徽章 科/创/上/深/北/基/港 + 交易所前缀 + 多市场行情解析：
# 港股字段布局差异、北交所/港股批量行必须被认到；实录原文离线断言）
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/market_tag_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/market_tag_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ market_tag      $summary"
    else
        echo "❌ market_tag      失败"
        printf '%s\n' "$out" | grep -E '^   ❌' | head -10 | sed 's/^/     /'
        FAILED+=("market_tag")
    fi
fi

# 图表缩放/铺满数学自检（ChartZoomMath：铺满不变量 / 尾部留白 / 自适应间距；纯函数离线钉死）
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/chart_zoom_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/chart_zoom_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ chart_zoom      $summary"
    else
        echo "❌ chart_zoom      失败"
        printf '%s\n' "$out" | grep -E '^   ❌' | head -10 | sed 's/^/     /'
        FAILED+=("chart_zoom")
    fi
fi

# 主题/色板自检（Tokens.swift：明暗自适应 / 浅色口径冻结 / 对比度 / 表面层级 / 语义入口）
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/theme_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/theme_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ theme          $summary"
    else
        echo "❌ theme          失败"
        printf '%s\n' "$out" | grep -E '^   ❌' | head -10 | sed 's/^/     /'
        FAILED+=("theme")
    fi
fi

# 审计修复回归自检：修复横跨 UI / Store / Scheduler / DataSources / DB 五层，
# 「现有测试仍通过」只证明没改坏，证明不了新行为生效 —— 本自检只验 Swift 侧行为契约。
# ⚠ schema 迁移自检：「全新库」路径测不到迁移（schema_sql 全是 CREATE TABLE IF NOT EXISTS），
#   ⇒ 造一个「有数据、缺列、版本号 = N-1」的老库才有意义（全程离线、库现造）。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/migration_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
    out=$(bash "$ROOT/SelectedApp/Tools/migration_test.sh" 2>&1)
    code=$?
    if [ $code -eq 0 ]; then
        echo "$out" | grep -E '^✅ migration' || echo "✅ migration"
    else
        echo "$out"
        echo "❌ migration    schema 迁移自检失败（exit ${code}）"
        FAILED+=("migration")
    fi
fi

if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/audit_fixes_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/audit_fixes_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ audit_fixes    $summary"
    else
        echo "❌ audit_fixes    失败"
        printf '%s\n' "$out" | grep -E '^   ❌|^❌' | head -10 | sed 's/^/     /'
        FAILED+=("audit_fixes")
    fi
fi

# 分组归属自检（「复制到分组」：copy / moveWithin / 迁移幂等 / 删组）
# ⚠ 单独套件：watch_group_members 是 Swift-only 表，
#   核心不变量是"一只股票可以同时在多个分组"。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/watch_group_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/watch_group_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ watch_group    $summary"
    else
        echo "❌ watch_group    失败"
        printf '%s\n' "$out" | grep -E '^   ❌|^❌' | head -10 | sed 's/^/     /'
        FAILED+=("watch_group")
    fi
fi

# 自选/持仓表头排序自检（升 → 降 → 取消 · nil 沉底 · 同值稳定 · 与显示同算式）
# ⚠ 单独套件：这三条全是"截图看不出来、一改就错"的类型，而自选表在快照库里
#   **根本没有行** ⇒ 出图链路验不到它，只能纯函数断言。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/watch_sort_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
out=$(bash "$ROOT/SelectedApp/Tools/watch_sort_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ watch_sort     $summary"
    else
        echo "❌ watch_sort     失败"
        printf '%s\n' "$out" | grep -E '^   ❌|^❌' | head -10 | sed 's/^/     /'
        FAILED+=("watch_sort")
    fi
fi

# 数据源诊断读取侧自检
# ⚠ 单独套件：诊断的 bug 全是"看着能用、其实没生效"且没有一个会变红 ——
#   ① 按事件筛选必须查库，不能只在已加载窗口里过滤；
#   ② 游标分页换筛选是替换不是追加，方向写反会每页重复第一页；
#   ③ 分类条数必须与实际库一致。
#   本套件用能被区分的构造钉住它们（见 DiagCheck.swift）。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/diag_test.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
    out=$(bash "$ROOT/SelectedApp/Tools/diag_test.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ diag_check     $summary"
    else
        echo "❌ diag_check     失败"
        printf '%s\n' "$out" | grep -E '^   ❌|^❌' | head -10 | sed 's/^/     /'
        FAILED+=("diag_check")
    fi
fi

# 图标名有效性自检
# ⚠ 单独套件：Image(systemName:) / Label(_:systemImage:) 遇到不存在的符号名什么都不画
#   （不报错、不占位、编译过、测试全绿），只能拿 AppKit 的 NSImage(systemSymbolName:) 验。
#   ⇒ 抽取规则与局限（只抓字面量、动态拼接测不到）见 `Tools/symbol_check.sh` 头部。
if command -v swiftc >/dev/null 2>&1 && [ -f "$ROOT/SelectedApp/Tools/symbol_check.sh" ]; then
    RAN+=("1")   # 套件登记（末尾校验「实际跑了几个」）
    out=$(bash "$ROOT/SelectedApp/Tools/symbol_check.sh" 2>&1)
    code=$?
    summary=$(printf '%s\n' "$out" | grep -E '^✅|^❌' | tail -1)
    if [ "$code" -eq 0 ]; then
        echo "✅ symbol_names   $summary"
    else
        echo "❌ symbol_names   失败"
        printf '%s\n' "$out" | grep -E '^     ·|^❌' | head -10 | sed 's/^/     /'
        FAILED+=("symbol_names")
    fi
fi

