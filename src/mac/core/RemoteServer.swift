//
//  RemoteServer.swift — 局域网遥控服务（Network.framework 极简 HTTP/1.1 + Bonjour）
//  ─────────────────────────────────────────────────────────────────────────────
//  iPhone 通过同一 Wi-Fi 访问：状态、立即锁屏、换桌面/登录页壁纸、上传图片、
//  读取/设置蓝牙邻近参数。所有请求需携带 6 位配对码（请求头或 ?code=）。
//

import Foundation
import Network
import Combine

/// 业务能力由协调器实现，网络层只负责 HTTP 编解码
protocol HaloServerDatasource: AnyObject {
    func makePing() -> PingResponse
    func makeStatus() -> StatusResponse
    func remoteLock()
    func remoteApply(desktopID: String?, lockID: String?) -> String?
    func remoteSetSlot(slot: SlotKind, id: String) -> String?
    /// 返回 (图片信息, 错误)；错误为 nil 即成功
    func remoteUpload(name: String, ext: String, data: Data, assign: SlotKind?) -> (WallpaperInfo?, String?)
    func remoteThumb(id: String) -> Data?
    func remoteImage(id: String) -> Data?
    func remoteGetProximity() -> ProximityConfig
    func remoteSetProximity(_ c: ProximityConfig) -> String?
}

final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    weak var datasource: HaloServerDatasource?

    @Published var running = false
    @Published var boundPort: UInt16 = 0
    private var listener: NWListener?
    private var queue = DispatchQueue(label: "com.lucas.halo.http", qos: .userInitiated)
    private var conns: [ObjectIdentifier: HttpConn] = [:]

    func start(preferredPort: UInt16 = Halo.defaultPort) {
        queue.async { if self.listener == nil { self.listen(preferred: preferredPort) } }
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.conns.values.forEach { $0.cancel() }; self.conns.removeAll()
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func listen(preferred: UInt16) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let l: NWListener
        do {
            if preferred != 0, let port = NWEndpoint.Port(rawValue: preferred) {
                l = try NWListener(using: params, on: port)
            } else {
                l = try NWListener(using: params)   // 端口 0 → 系统分配
            }
            l.service = NWListener.Service(name: HaloCore.macName, type: Halo.bonjourType,
                                          domain: Halo.bonjourDomain)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] (st: NWListener.State) in
                switch st {
                case .ready:
                    if let p = l.port {
                        DispatchQueue.main.async { self?.running = true; self?.boundPort = p.rawValue }
                        NSLog("[Halo] remote listening on \(p.rawValue), bonjour \(Halo.bonjourType)")
                    }
                case .failed(let e):
                    NSLog("[Halo] listener failed \(e)")
                    DispatchQueue.main.async { self?.running = false }
                    // 首选端口被占 → 随机端口重试一次
                    if preferred == Halo.defaultPort { self?.listen(preferred: 0) }
                case .cancelled:
                    DispatchQueue.main.async { self?.running = false }
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            NSLog("[Halo] listener create fail \(error)")
            if preferred != 0 { listen(preferred: 0) }
        }
    }

    private func accept(_ conn: NWConnection) {
        let c = HttpConn(connection: conn) { [weak self] req in
            self?.route(req) ?? Self.resp(.internalError, json: SimpleResult(ok: false, error: "server gone"))
        } onClose: { [weak self] id in
            self?.queue.async { self?.conns.removeValue(forKey: id) }
        }
        conns[c.id] = c
        c.start(on: queue)
    }

    // MARK: 路由（全部派发到主队列串行执行，避免并发改壁纸）

    private func route(_ req: HttpRequest) -> HttpResponse {
        guard let ds = datasource else { return Self.resp(.internalError, json: SimpleResult(ok: false, error: "no datasource")) }
        // 配对码校验（header 或 query）
        guard authorized(req) else {
            return Self.resp(.unauthorized, json: SimpleResult(ok: false, error: "配对码错误"))
        }
        let path = req.pathOnly
        switch (req.method, path) {
        case ("GET", HaloRoute.ping):
            return Self.resp(.ok, json: ds.makePing())
        case ("GET", HaloRoute.status):
            return Self.resp(.ok, json: ds.makeStatus())
        case ("GET", let p) where p.hasPrefix(HaloRoute.thumb):
            let id = String(p.dropFirst(HaloRoute.thumb.count))
            if let d = ds.remoteThumb(id: id) { return Self.binary(d, mime: "image/jpeg") }
            return Self.resp(.notFound, json: SimpleResult(ok: false, error: "no thumb"))
        case ("GET", let p) where p.hasPrefix(HaloRoute.image):
            let id = String(p.dropFirst(HaloRoute.image.count))
            if let d = ds.remoteImage(id: id) { return Self.binary(d, mime: "application/octet-stream") }
            return Self.resp(.notFound, json: SimpleResult(ok: false, error: "no image"))
        case ("POST", HaloRoute.lock):
            ds.remoteLock(); return Self.resp(.ok, json: SimpleResult(ok: true))
        case ("POST", HaloRoute.apply):
            guard let b = HaloJSON.decode(ApplyRequest.self, from: req.body) else {
                return Self.resp(.badRequest, json: SimpleResult(ok: false, error: "bad body")) }
            if let e = ds.remoteApply(desktopID: b.desktopID, lockID: b.lockID) {
                return Self.resp(.ok, json: SimpleResult(ok: false, error: e)) }
            return Self.resp(.ok, json: SimpleResult(ok: true))
        case ("POST", HaloRoute.setSlot):
            guard let b = HaloJSON.decode(SetSlotRequest.self, from: req.body) else {
                return Self.resp(.badRequest, json: SimpleResult(ok: false, error: "bad body")) }
            if let e = ds.remoteSetSlot(slot: b.slot, id: b.id) {
                return Self.resp(.ok, json: SimpleResult(ok: false, error: e)) }
            return Self.resp(.ok, json: SimpleResult(ok: true))
        case ("POST", HaloRoute.upload):
            guard let b = HaloJSON.decode(UploadRequest.self, from: req.body),
                  let raw = Data(base64Encoded: b.dataBase64) else {
                return Self.resp(.badRequest, json: SimpleResult(ok: false, error: "bad upload")) }
            let (info, upErr) = ds.remoteUpload(name: b.name, ext: b.ext, data: raw, assign: b.assignTo)
            return Self.resp(.ok, json: UploadResponse(ok: info != nil, wallpaper: info, error: upErr))
        case ("GET", HaloRoute.proximityGet):
            return Self.resp(.ok, json: ds.remoteGetProximity())
        case ("POST", HaloRoute.proximitySet):
            guard let c = HaloJSON.decode(ProximityConfig.self, from: req.body) else {
                return Self.resp(.badRequest, json: SimpleResult(ok: false, error: "bad body")) }
            if let e = ds.remoteSetProximity(c) {
                return Self.resp(.ok, json: SimpleResult(ok: false, error: e)) }
            return Self.resp(.ok, json: SimpleResult(ok: true))
        default:
            return Self.resp(.notFound, json: SimpleResult(ok: false, error: "unknown route"))
        }
    }

    private func authorized(_ req: HttpRequest) -> Bool {
        let presented = req.headers[Halo.pairHeader.lowercased()] ?? req.query["code"] ?? ""
        return presented == HaloStore.shared.pairCode
    }

    // MARK: 响应封装

    fileprivate static func resp<T: Encodable>(_ status: HttpStatus, json: T) -> HttpResponse {
        let body = (try? JSONEncoder().encode(json)) ?? Data()
        var head = ["Content-Type": "application/json; charset=utf-8",
                    "Content-Length": String(body.count),
                    "Connection": "close"]
        if status == .unauthorized { head["WWW-Authenticate"] = "HaloPair" }
        return HttpResponse(status: status, headers: head, body: body)
    }
    fileprivate static func binary(_ data: Data, mime: String) -> HttpResponse {
        HttpResponse(status: .ok, headers: ["Content-Type": mime,
                                            "Content-Length": String(data.count),
                                            "Connection": "close"], body: data)
    }
}

// MARK: - HTTP 状态与报文

enum HttpStatus: Int {
    case ok = 200, badRequest = 400, unauthorized = 401, notFound = 404, internalError = 500
    var text: String {
        switch self {
        case .ok: return "OK"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .notFound: return "Not Found"
        case .internalError: return "Internal Server Error"
        }
    }
}

struct HttpRequest {
    var method = "", target = ""
    var headers: [String: String] = [:]
    var body = Data()
    var pathOnly: String { target.components(separatedBy: "?").first ?? target }
    var query: [String: String] {
        guard let q = target.components(separatedBy: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }
}

struct HttpResponse {
    let status: HttpStatus
    let headers: [String: String]
    let body: Data
    func serialize() -> Data {
        var s = "HTTP/1.1 \(status.rawValue) \(status.text)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        var d = s.data(using: .utf8) ?? Data()
        d.append(body)
        return d
    }
}

// MARK: - 单连接解析状态机

private final class HttpConn {
    var id: ObjectIdentifier!
    private let conn: NWConnection
    private let handler: (HttpRequest) -> HttpResponse
    private let onClose: (ObjectIdentifier) -> Void
    private var buffer = Data()
    private var parsedHead = false
    private var contentLength = 0
    private var request: HttpRequest?

    init(connection: NWConnection,
         handler: @escaping (HttpRequest) -> HttpResponse,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.conn = connection; self.handler = handler; self.onClose = onClose
        self.id = ObjectIdentifier(connection)
    }

    func start(on queue: DispatchQueue) {
        conn.start(queue: queue)
        receive()
    }
    func cancel() { conn.cancel() }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if !self.parsedHead { self.tryParseHead() }
            if self.parsedHead {
                if self.buffer.count >= self.contentLength { self.respond() }
                else if err == nil && !isComplete { self.receive() }
            } else if err == nil && !isComplete {
                self.receive()
            } else { self.finish() }
            if isComplete || err != nil { self.finish() }
        }
    }

    private func tryParseHead() {
        guard let sepRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headData = buffer.subdata(in: 0..<sepRange.lowerBound)
        guard let text = String(data: headData, encoding: .utf8) else { finish(); return }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { finish(); return }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { finish(); return }
        var req = HttpRequest(); req.method = parts[0]; req.target = parts[1]
        lines.removeFirst()
        for line in lines {
            guard let ci = line.firstIndex(of: ":") else { continue }
            let k = String(line[line.startIndex..<ci]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }
        contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
        request = req
        parsedHead = true
        buffer.removeSubrange(0..<sepRange.upperBound)
    }

    private func respond() {
        guard var req = request else { finish(); return }
        req.body = buffer.prefix(contentLength)
        // 业务在主线程串行执行；网络回调线程同步等待结果（操作很快）
        let result = DispatchQueue.main.sync { handler(req) }
        conn.send(content: result.serialize(), completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        conn.cancel(); onClose(id)
    }
}
