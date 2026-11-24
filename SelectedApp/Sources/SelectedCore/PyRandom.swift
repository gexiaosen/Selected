import Foundation

/// Python `random.Random` 的等价实现（MT19937 + CPython 取数口径）。
///
/// **为什么必须逐位复刻**：调优（`PhaseTune.tune`）是随机搜索，`seed` 决定候选参数序列 ——
/// 随机流不一致，"同一 seed 同一结果"的可复现承诺就是假的（调优报告是要被用户拿去存新版本的）。
/// 与 `PyMath.round` / `PyMath.sum` 同类的口径问题。
///
/// 对齐 CPython 3.12 `Modules/_randommodule.c` + `Lib/random.py`：
///   · seed(int)      → `random_seed`：绝对值拆成 32 位小端字 → `init_by_array`
///   · genrand_uint32 → 梅森旋转 + tempering（含指数 0 时的 twist）
///   · random()       → 53 位双字拼接（a>>5、b>>6）
///   · getrandbits(k) → k≤32 取单字高位；更大时按 32 位小端字拼接
///   · _randbelow     → 拒绝采样（按 n 的位长取随机位）
///   · sample         → 池化交换法（n≤setsize）/ 集合法（否则），与 CPython 同分支
///
/// ⚠ 有意限制：`getrandbits` 只支持 k ≤ 64（返回 UInt64）。本文件的使用方
/// （`randint`/`sample`/`choice`，n ≤ 77）位长都 ≤ 7，远在范围内。
final public class PyRandom {
    private static let n = 624
    private static let m = 397
    private static let upperMask: UInt32 = 0x8000_0000
    private static let lowerMask: UInt32 = 0x7fff_ffff
    private static let mag01: [UInt32] = [0x0, 0x9908_b0df]

    private var state = [UInt32](repeating: 0, count: PyRandom.n)
    private var index = PyRandom.n

    /// 等价 `random.Random(seed)`（seed 为 int）；seed == 0 时 key=[0]。
    public init(seed: Int) {
        var key: [UInt32] = []
        var n = UInt64(seed.magnitude)
        repeat {
            key.append(UInt32(truncatingIfNeeded: n & 0xffff_ffff))
            n >>= 32
        } while n != 0
        initByArray(key)
    }

    /// ≡ `init_genrand(19650218)`
    private func initGenrand(_ s: UInt32) {
        state[0] = s
        for i in 1..<Self.n {
            state[i] = 1812433253 &* (state[i - 1] ^ (state[i - 1] >> 30)) &+ UInt32(i)
        }
        index = Self.n
    }

    /// ≡ `init_by_array`
    private func initByArray(_ key: [UInt32]) {
        initGenrand(19650218)
        var i = 1
        var j = 0
        var k = max(Self.n, key.count)
        while k > 0 {
            state[i] = (state[i] ^ ((state[i - 1] ^ (state[i - 1] >> 30)) &* 1664525))
                &+ key[j] &+ UInt32(j)
            i += 1; j += 1
            if i >= Self.n { state[0] = state[Self.n - 1]; i = 1 }
            if j >= key.count { j = 0 }
            k -= 1
        }
        k = Self.n - 1
        while k > 0 {
            state[i] = (state[i] ^ ((state[i - 1] ^ (state[i - 1] >> 30)) &* 1566083941))
                &- UInt32(i)
            i += 1
            if i >= Self.n { state[0] = state[Self.n - 1]; i = 1 }
            k -= 1
        }
        state[0] = 0x8000_0000
    }

    /// ≡ `genrand_uint32`（含 index 耗尽时的整块 twist）
    private func genrandUInt32() -> UInt32 {
        if index >= Self.n {
            for kk in 0..<(Self.n - Self.m) {
                let y = (state[kk] & Self.upperMask) | (state[kk + 1] & Self.lowerMask)
                state[kk] = state[kk + Self.m] ^ (y >> 1) ^ Self.mag01[Int(y & 1)]
            }
            for kk in (Self.n - Self.m)..<(Self.n - 1) {
                let y = (state[kk] & Self.upperMask) | (state[kk + 1] & Self.lowerMask)
                state[kk] = state[kk + (Self.m - Self.n)] ^ (y >> 1) ^ Self.mag01[Int(y & 1)]
            }
            let y = (state[Self.n - 1] & Self.upperMask) | (state[0] & Self.lowerMask)
            state[Self.n - 1] = state[Self.m - 1] ^ (y >> 1) ^ Self.mag01[Int(y & 1)]
            index = 0
        }
        var y = state[index]
        index += 1
        y ^= (y >> 11)
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= (y >> 18)
        return y
    }

    /// ≡ `random()`：`(a * 67108864.0 + b) / 9007199254740992.0`
    public func random() -> Double {
        let a = Double(genrandUInt32() >> 5)
        let b = Double(genrandUInt32() >> 6)
        return (a * 67_108_864.0 + b) / 9_007_199_254_740_992.0
    }

    /// ≡ `getrandbits(k)`
    public func getrandbits(_ k: Int) -> UInt64 {
        if k <= 0 { return 0 }
        if k <= 32 { return UInt64(genrandUInt32() >> (32 - k)) }
        var out: UInt64 = 0
        var remaining = k
        var shift = 0
        while remaining > 0 && shift < 64 {
            var r = genrandUInt32()
            if remaining < 32 { r >>= (32 - remaining) }
            out |= UInt64(r) << shift
            remaining -= 32
            shift += 32
        }
        return out
    }

    /// ≡ `_randbelow_with_getrandbits`（调用方保证 n > 0）
    public func randbelow(_ n: Int) -> Int {
        if n <= 0 { return 0 }
        let k = n.bitWidth - n.leadingZeroBitCount     // ≡ Python `n.bit_length()`
        var r = Int(getrandbits(k))
        while r >= n { r = Int(getrandbits(k)) }
        return r
    }

    /// ≡ `randint(a, b)`
    public func randint(_ a: Int, _ b: Int) -> Int { a + randbelow(b - a + 1) }

    /// ≡ `choice(seq)`
    ///
    /// ⚠ 空序列必须显式拦住：`randbelow(0)` 返回 0 → `seq[0]` 在 Swift 里是
    /// **越界 fatalError**（崩 App，且报错信息与"随机数"毫无关联，极难定位），
    /// 故用 precondition 给出可读的失败原因（≡ random.choice 对空序列抛 IndexError）。
    public func choice<T>(_ seq: [T]) -> T {
        precondition(!seq.isEmpty, "PyRandom.choice：空序列（≡ random.choice 对空序列抛 IndexError）")
        return seq[randbelow(seq.count)]
    }

    /// ≡ `uniform(a, b)` = `a + (b - a) * random()`
    public func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }

    /// ≡ `sample(population, k)`：CPython 的两条分支（池化交换 / 集合拒绝）逐行走。
    /// 分支判定同样照抄：`setsize = 21`，`k > 5` 时 `setsize += 4 ** _ceil(_log(k*3, 4))`。
    ///
    /// ⚠ `0 <= k <= n` 必须前置校验，否则有**两种**坏结局：
    ///   · 池化交换分支：`pool[n - i - 1]` 在 `k > n` 时下标变负 → fatalError 崩溃；
    ///   · 集合法分支：`while selected.contains(j)` 永远凑不齐 `k` 个不同下标 → **死循环**。
    /// 越界时返回 `[]`（语义等价于"这次没抽到"）。
    public func sample<T>(_ population: [T], _ k: Int) -> [T] {
        let n = population.count
        guard k >= 0, k <= n else { return [] }
        var result = [T]()
        result.reserveCapacity(k)
        var setsize = 21
        if k > 5 {
            let e = Int((log(Double(k * 3)) / log(4.0)).rounded(.up))
            var mult = 1
            for _ in 0..<max(0, e) { mult *= 4 }
            setsize += mult
        }
        if n <= setsize {
            var pool = population
            for i in 0..<k {
                let j = randbelow(n - i)
                result.append(pool[j])
                pool[j] = pool[n - i - 1]
            }
        } else {
            var selected = Set<Int>()
            for _ in 0..<k {
                var j = randbelow(n)
                while selected.contains(j) { j = randbelow(n) }
                selected.insert(j)
                result.append(population[j])
            }
        }
        return result
    }
}