//
//  ZoneEngine.swift — 蓝牙靠近/远离「迟滞 + 滑窗 + 驻留」判定（纯逻辑，不依赖 CoreBluetooth）
//  ─────────────────────────────────────────────────────────────────────────────
//  从 ProximityLock 抽离，使得 RSSI→动作 的判定可以在没有蓝牙、没有真机的情况下
//  被单元测试完整覆盖；时钟可注入，dwell（驻留秒数）也能确定性验证。
//
//  判定规则（双阈值迟滞，避免在边界反复横跳）：
//    · 滑窗取最近 windowMax 个 RSSI 的平均，样本不足 minSamples 不判定（抗瞬时尖刺）
//    · searching/near 状态：均值 ≤ awayRSSI 且连续保持 dwellSeconds → 跨越为 far，输出 .lock
//    · far 状态：均值 ≥ nearRSSI 且连续保持 dwellSeconds → 跨越回 near，输出 .unlock
//    · awayRSSI < x < nearRSSI 的「死区」内不发生任何翻转（迟滞）
//    · 每次跨越只输出一次动作，进入新区域后重复样本不再重复触发
//
//  autoLock / autoUnlock 开关由外层（ProximityLock）决定是否真正执行，本引擎只负责
//  忠实地给出「发生了一次远离/靠近跨越」这一事实，保持纯函数式可测。
//

import Foundation

struct ZoneDecisionEngine {
    enum Action: Equatable { case none, lock, unlock }
    private enum Zone { case searching, near, far }

    // 阈值与驻留（可随配置更新）
    var awayRSSI: Int
    var nearRSSI: Int
    var dwellSeconds: Double

    let windowMax = 8
    let minSamples = 3

    private var zone: Zone = .searching
    private var samples: [Int] = []
    private var candidateFarAt: Date?
    private var candidateNearAt: Date?

    init(awayRSSI: Int, nearRSSI: Int, dwellSeconds: Double) {
        self.awayRSSI = awayRSSI
        self.nearRSSI = nearRSSI
        self.dwellSeconds = dwellSeconds
    }

    /// 滑窗平均（无样本返回 0）
    var smoothed: Int {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / samples.count
    }

    var isFar: Bool { zone == .far }

    /// 重置全部状态（连接重建、配置变更时调用）
    mutating func reset() {
        zone = .searching
        samples.removeAll()
        candidateFarAt = nil
        candidateNearAt = nil
    }

    /// 连接刚建立时，若信号已经足够强，可直接把基线置为 near（不会因此解锁）
    mutating func markConnectedBaseline() {
        zone = .near
        samples.removeAll()
        candidateFarAt = nil
        candidateNearAt = nil
    }

    /// 喂入一个 RSSI 采样；返回此刻应执行的动作
    mutating func ingest(_ rssi: Int, at now: Date = Date()) -> Action {
        samples.append(rssi)
        if samples.count > windowMax { samples.removeFirst() }
        guard samples.count >= minSamples else { return .none }
        let avg = smoothed

        switch zone {
        case .searching, .near:
            // 近/未知 → 远
            if avg <= awayRSSI {
                if candidateFarAt == nil { candidateFarAt = now }
                if let at = candidateFarAt, now.timeIntervalSince(at) >= dwellSeconds {
                    zone = .far
                    clearCandidates()
                    return .lock
                }
            } else {
                candidateFarAt = nil
            }
            // 首次确认处于近旁：只迁移状态，不产生解锁动作（解锁只允许 far→near）
            if avg >= nearRSSI, zone == .searching {
                zone = .near
            }
        case .far:
            // 远 → 近（必须达到更高的 near 阈值，死区内不动作）
            if avg >= nearRSSI {
                if candidateNearAt == nil { candidateNearAt = now }
                if let at = candidateNearAt, now.timeIntervalSince(at) >= dwellSeconds {
                    zone = .near
                    clearCandidates()
                    return .unlock
                }
            } else {
                candidateNearAt = nil
            }
        }
        return .none
    }

    private mutating func clearCandidates() {
        candidateFarAt = nil
        candidateNearAt = nil
    }
}
