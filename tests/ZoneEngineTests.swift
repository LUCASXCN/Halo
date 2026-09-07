//
//  ZoneEngineTests.swift — 蓝牙靠近/远离判定的确定性单元测试（无需蓝牙、无需真机）
//  编译时本文件需命名为 main.swift（多文件顶层代码要求）。
//

import Foundation

var failures = 0
var passed = 0
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond { passed += 1; print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name)  \(detail)") }
}

func makeEngine() -> ZoneDecisionEngine {
    ZoneDecisionEngine(awayRSSI: -70, nearRSSI: -55, dwellSeconds: 2.5)
}

// 喂入一串 (rssi, 秒)，收集所有非 none 动作，返回更新后的引擎（struct 值类型必须接回）
func run(_ e0: ZoneDecisionEngine, _ seq: [(Int, Double)]) -> (ZoneDecisionEngine, [ZoneDecisionEngine.Action]) {
    var e = e0
    var acts: [ZoneDecisionEngine.Action] = []
    for (r, s) in seq {
        let a = e.ingest(r, at: Date(timeIntervalSince1970: s))
        if a != .none { acts.append(a) }
    }
    return (e, acts)
}
func farEnter() -> ZoneDecisionEngine {
    run(makeEngine(), [(-80, 0), (-80, 0.5), (-80, 1.0), (-80, 3.6)]).0
}

print("T1 样本不足 minSamples=3 时不判定")
do {
    let (_, a) = run(makeEngine(), [(-80, 0), (-80, 0.5)])
    check(a == [], "仅2个强远离样本不触发", "\(a)")
}

print("T2 近/未知 → 远：持续低于 away 且满 dwell 才锁，且只锁一次")
do {
    let (e1, a1) = run(makeEngine(), [(-80, 0), (-80, 0.5), (-80, 1.0), (-80, 2.0)])
    check(a1 == [], "dwell 不足不锁屏", "\(a1)")
    let (e2, a2) = run(e1, [(-80, 3.6), (-80, 4.0), (-80, 5.0)])
    check(a2 == [.lock], "满 2.5s 触发一次锁屏", "\(a2)")
    check(e2.isFar, "进入 far 区", "")
}

print("T3 远 → 近：死区不解锁，强近场满 dwell 才解，且只解一次")
do {
    let ef = farEnter()
    check(ef.isFar, "前置：已进入 far", "")
    var seq: [(Int, Double)] = []
    for k in 0..<12 { seq.append((-60, 4.0 + Double(k) * 0.5)) } // 死区 (-70,-55)
    let (e1, aDead) = run(ef, seq)
    check(aDead == [], "死区 -60 不触发解锁（迟滞）", "\(aDead)")
    check(e1.isFar, "仍停留在 far", "")
    var near: [(Int, Double)] = []
    for k in 0..<14 { near.append((-45, 11.0 + Double(k) * 0.5)) }
    let (e2, aNear) = run(e1, near)
    check(aNear == [.unlock], "强近场持续后解锁一次", "\(aNear)")
    check(!e2.isFar, "回到 near 区", "")
}

print("T4 near 区遇死区信号不锁屏（迟滞，抗边界抖动）")
do {
    let (eb, _) = run(makeEngine(), [(-45, 0), (-45, 0.5), (-45, 1.0)]) // 建立 near
    var seq: [(Int, Double)] = []
    for k in 0..<16 { seq.append((-62, 2.0 + Double(k) * 0.5)) }
    let (_, a) = run(eb, seq)
    check(a == [], "near 下死区抖动绝不锁屏", "\(a)")
}

print("T5 滑窗平均抗瞬时尖刺")
do {
    let (eb, _) = run(makeEngine(), [(-50, 0), (-50, 0.5), (-50, 1.0)])
    var seq: [(Int, Double)] = []
    var s = 2.0
    for _ in 0..<6 { seq.append((-50, s)); s += 0.5 }
    seq.append((-95, s)); s += 0.5
    for k in 0..<8 { seq.append((-50, s + Double(k) * 0.5)) }
    let (eng, a) = run(eb, seq)
    check(a == [], "单个 -95 尖刺被滑窗平滑，不误锁", "avg=\(eng.smoothed) \(a)")
}

print("T6 首次强信号只迁移到 near，绝不产生解锁动作")
do {
    let (_, a) = run(makeEngine(), [(-45, 0), (-45, 0.5), (-45, 1.0)])
    check(a == [], "searching→near 不解锁", "\(a)")
}

print("T7 边界值：等于 away 算远离（<=）")
do {
    let (_, a) = run(makeEngine(), [(-70, 0), (-70, 0.5), (-70, 1.0), (-70, 3.6)])
    check(a == [.lock], "avg=-70 恰好触发远离", "\(a)")
}

print("T8 far 后 reset 立即从 searching 干净起步")
do {
    var e = farEnter()
    e.reset()
    let (_, a) = run(e, [(-45, 10), (-45, 10.5), (-45, 11)])
    check(a == [], "reset 后强信号不误解锁", "\(a)")
}

print("T9 ProximityConfig.normalize 容错")
do {
    var c = ProximityConfig(); c.awayRSSI = -200; c.nearRSSI = 10; c.dwellSeconds = 999
    c.normalize()
    check(c.awayRSSI == -100 && c.nearRSSI == -30 && c.dwellSeconds == 30, "越界被夹回", "\(c.awayRSSI),\(c.nearRSSI),\(c.dwellSeconds)")
    var c2 = ProximityConfig(); c2.awayRSSI = -50; c2.nearRSSI = -80 // 颠倒
    c2.normalize()
    check(c2.awayRSSI == -70 && c2.nearRSSI == -55, "near/away 颠倒回退默认", "\(c2.awayRSSI),\(c2.nearRSSI)")
}

print("")
print("════════════════════════════════════")
print("通过 \(passed)，失败 \(failures)")
if failures > 0 { exit(1) } else { print("全部状态机用例通过 ✅") }
