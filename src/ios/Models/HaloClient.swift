//
//  HaloClient.swift — iPhone 端局域网客户端
//  ─────────────────────────────────────────────────────────────────
//  用 NWBrowser 自动发现 Bonjour 上的 Mac（_halo._tcp），也支持手动输 IP。
//  用 NWConnection 手写极简 HTTP/1.1（与 Mac 端 RemoteServer 严格对称），
//  每个请求带 6 位配对码，Connection: close。
//

import Foundation
import Network
import Combine

// MARK: - 发现到的 Mac

struct DiscoveredMac: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    static func == (a: DiscoveredMac, b: DiscoveredMac) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 连接目标

enum HaloTarget {
    case bonjour(NWEndpoint)
    case manual(host: String, port: UInt16)
    var endpoint: NWEndpoint {
        switch self {
        case .bonjour(let e): return e
        case .manual(let h, let p):
            let host = NWEndpoint.Host(h)
            let port = NWEndpoint.Port(rawValue: p) ?? NWEndpoint.Port(rawValue: Halo.defaultPort)!
            return .hostPort(host: host, port: port)
        }
    }
}

// MARK: - 客户端

@MainActor
final class HaloClient: ObservableObject {
    @Published var discovered: [DiscoveredMac] = []
    @Published var connected: Bool = false
    @Published var targetName: String = ""
    @Published var pairCode: String = UserDefaults.standard.string(forKey: "halo.pairCode") ?? ""
    @Published var manualHost: String = UserDefaults.standard.string(forKey: "halo.host") ?? ""
    @Published var manualPort: String = UserDefaults.standard.string(forKey: "halo.port") ?? "\(Halo.defaultPort)"

    var target: HaloTarget?
    private var browser: NWBrowser?
    private var inflight: [ObjectIdentifier: NWConnection] = [:]

    // MARK: 发现

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Halo.bonjourType, domain: Halo.bonjourDomain), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [DiscoveredMac] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return DiscoveredMac(id: name, name: name, endpoint: r.endpoint)
            }
            Task { @MainActor in
                self?.discovered = list.sorted { $0.name < $1.name }
            }
        }
        b.stateUpdateHandler = { _ in }
        browser = b
        b.start(queue: .main)
    }

    func stopBrowsing() { browser?.cancel(); browser = nil }

    // MARK: 连接 / 校验配对码

    func connect(_ target: HaloTarget, name: String) async throws -> PingResponse {
        self.target = target
        let ping = try await getPing()   // 配对码错误会抛 401
        self.connected = true
        self.targetName = name
        UserDefaults.standard.set(pairCode, forKey: "halo.pairCode")
        if case .manual(let h, let p) = target {
            UserDefaults.standard.set(h, forKey: "halo.host")
            UserDefaults.standard.set("\(p)", forKey: "halo.port")
        }
        return ping
    }

    func disconnect() {
        target = nil; connected = false; targetName = ""
        inflight.values.forEach { $0.cancel() }; inflight.removeAll()
    }

    // MARK: 高层 API

    func getPing() async throws -> PingResponse {
        try await requestJSON(PingResponse.self, method: "GET", path: HaloRoute.ping)
    }
    func getStatus() async throws -> StatusResponse {
        try await requestJSON(StatusResponse.self, method: "GET", path: HaloRoute.status)
    }
    func lock() async throws {
        _ = try await requestRaw(method: "POST", path: HaloRoute.lock, body: try? JSONEncoder().encode(LockRequest(confirm: true)))
    }
    func apply(desktop: String?, lock: String?) async throws {
        _ = try await requestRaw(method: "POST", path: HaloRoute.apply,
                                 body: HaloJSON.encode(ApplyRequest(desktopID: desktop, lockID: lock)))
    }
    func setSlot(_ slot: SlotKind, id: String) async throws {
        _ = try await requestRaw(method: "POST", path: HaloRoute.setSlot,
                                 body: HaloJSON.encode(SetSlotRequest(slot: slot, id: id)))
    }
    func upload(name: String, ext: String, data: Data, assign: SlotKind?) async throws -> UploadResponse {
        let req = UploadRequest(name: name, ext: ext,
                                dataBase64: data.base64EncodedString(), assignTo: assign)
        let raw = try await requestRaw(method: "POST", path: HaloRoute.upload, body: HaloJSON.encode(req))
        if let u = HaloJSON.decode(UploadResponse.self, from: raw) { return u }
        return UploadResponse(ok: false, wallpaper: nil, error: "响应解析失败")
    }
    func getProximity() async throws -> ProximityConfig {
        try await requestJSON(ProximityConfig.self, method: "GET", path: HaloRoute.proximityGet)
    }
    func setProximity(_ c: ProximityConfig) async throws {
        _ = try await requestRaw(method: "POST", path: HaloRoute.proximitySet, body: HaloJSON.encode(c))
    }
    func thumbData(id: String) async throws -> Data {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await requestRaw(method: "GET", path: HaloRoute.thumb + enc, body: nil)
    }

    // MARK: 底层 HTTP

    private func requestJSON<T: Decodable>(_ t: T.Type, method: String, path: String) async throws -> T {
        let raw = try await requestRaw(method: method, path: path, body: nil)
        guard let obj = HaloJSON.decode(T.self, from: raw) else {
            throw HaloNetError.badResponse(String(data: raw, encoding: .utf8) ?? "")
        }
        return obj
    }

    private func requestRaw(method: String, path: String, body: Data?) async throws -> Data {
        guard let target else { throw HaloNetError.notConnected }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: target.endpoint, using: params)
        let oid = ObjectIdentifier(conn)
        inflight[oid] = conn
        defer { inflight.removeValue(forKey: oid) }

        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: halo.local\r\n"
        head += "\(Halo.pairHeader): \(pairCode)\r\n"
        head += "Accept: application/json\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var payloadData = head.data(using: .utf8)!
        if let body { payloadData.append(body) }
        let payload = payloadData

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let box = RecvBox()
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                    Self.receiveAll(conn, box: box) {
                        if !box.settled {
                            box.settled = true
                            Self.parseResponse(box.data, cont: cont)
                        }
                    }
                case .failed(let e):
                    if !box.settled { box.settled = true; cont.resume(throwing: HaloNetError.transport(e.localizedDescription)) }
                case .cancelled:
                    if !box.settled {
                        box.settled = true
                        if !box.data.isEmpty { Self.parseResponse(box.data, cont: cont) }
                        else { cont.resume(throwing: HaloNetError.cancelled) }
                    }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    /// 连接级收包缓冲（在同一 NW 队列内访问，避免 inout 逃逸）
    private final class RecvBox: @unchecked Sendable {
        var data = Data()
        var settled = false
    }

    nonisolated private static func receiveAll(_ conn: NWConnection, box: RecvBox, onDone: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
            if let data, !data.isEmpty { box.data.append(data) }
            if err != nil {
                if !box.data.isEmpty { onDone() }
                return
            }
            if isComplete { onDone(); return }
            receiveAll(conn, box: box, onDone: onDone)
        }
    }

    nonisolated private static func parseResponse(_ data: Data, cont: CheckedContinuation<Data, Error>) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            cont.resume(throwing: HaloNetError.badResponse("无响应头")); return
        }
        let headText = String(data: data.subdata(in: 0..<sep.lowerBound), encoding: .utf8) ?? ""
        let firstLine = headText.components(separatedBy: "\r\n").first ?? ""
        let code = Int(firstLine.components(separatedBy: " ")[safe: 1] ?? "") ?? 0
        var body = data.subdata(in: sep.upperBound..<data.count)
        // 按 Content-Length 精确截取
        var length: Int?
        for line in headText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
            }
        }
        if let l = length, body.count >= l { body = body.prefix(l) }
        if code == 200 { cont.resume(returning: body) }
        else if code == 401 { cont.resume(throwing: HaloNetError.unauthorized) }
        else {
            let msg = (HaloJSON.decode(SimpleResult.self, from: body)?.error) ?? "HTTP \(code)"
            cont.resume(throwing: HaloNetError.server(code, msg))
        }
    }
}

enum HaloNetError: LocalizedError {
    case notConnected, unauthorized, cancelled, badResponse(String), transport(String), server(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接到 Mac"
        case .unauthorized: return "配对码错误"
        case .cancelled: return "连接被中断"
        case .badResponse(let s): return "响应异常：\(s)"
        case .transport(let s): return "网络错误：\(s)"
        case .server(let c, let m): return "Mac 返回错误(\(c))：\(m)"
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
