#if os(macOS)
import Foundation

/// 작은 URLProtocol 대역 (BridgeClient 시험용). 시험마다 다른 호스트를 써서 병렬 시험이 서로 섞이지 않는다.
final class StubURLProtocol: URLProtocol {
    struct Captured: Sendable {
        let request: URLRequest
        let body: Data
    }

    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data("{}".utf8)
        /// true면 응답하지 않고 취소를 기다린다 (긴 대기 · 취소 시험)
        var hold = false
        var transportError: URLError.Code?
        /// 있으면 이 주소로 가라는 3xx로 답한다 (리다이렉트 거절 시험)
        var redirectTo: URL?
        /// 0보다 크면 `body` 대신 이 크기의 조각을 이 간격으로 이만큼 보낸다 (스트리밍 도중 끊는지 시험). 끊기면 더 보내지 않는다
        var chunks = 0
        var chunkSize = 0
        var chunkInterval: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (Captured) -> Reply] = [:]
    nonisolated(unsafe) private static var captures: [String: [Captured]] = [:]
    nonisolated(unsafe) private static var chunksDelivered: [String: Int] = [:]

    static func install(host: String, _ handler: @escaping @Sendable (Captured) -> Reply) {
        lock.lock()
        handlers[host] = handler
        captures[host] = []
        chunksDelivered[host] = 0
        lock.unlock()
    }

    /// 조각으로 보낸 응답에서 클라이언트가 끊기 전까지 실제로 보낸 조각 수
    static func delivered(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return chunksDelivered[host] ?? 0
    }

    static func captured(host: String) -> [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captures[host] ?? []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var held = false
    private let stopLock = NSLock()
    private var stopped = false

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let body = Self.readBody(request)
        let captured = Captured(request: request, body: body)
        Self.lock.lock()
        Self.captures[host, default: []].append(captured)
        let handler = Self.handlers[host]
        Self.lock.unlock()
        let reply = handler?(captured) ?? Reply(status: 500)
        if reply.hold {
            held = true
            return
        }
        if let code = reply.transportError {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirectTo {
            // 세션이 리다이렉트를 따를지 델리게이트에 묻는다. 따르면 새 요청이 나가고(이 프로토콜은 멈춘다), 거절하면 3xx 응답이 그대로 간다
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // 따르지 않기로 했다면 3xx 응답이 그대로 전달돼야 한다 (따랐다면 세션이 이 프로토콜을 멈추므로 아래 호출은 무시된다)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if reply.chunks > 0 {
            nonisolated(unsafe) let me = self
            DispatchQueue.global().async {
                let piece = Data(repeating: UInt8(ascii: "x"), count: reply.chunkSize)
                for _ in 0..<reply.chunks {
                    if me.isStopped { return }
                    me.client?.urlProtocol(me, didLoad: piece)
                    Self.lock.lock()
                    Self.chunksDelivered[host, default: 0] += 1
                    Self.lock.unlock()
                    Thread.sleep(forTimeInterval: reply.chunkInterval)
                }
                if !me.isStopped { me.client?.urlProtocolDidFinishLoading(me) }
            }
            return
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private var isStopped: Bool { stopLock.withLock { stopped } }

    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
