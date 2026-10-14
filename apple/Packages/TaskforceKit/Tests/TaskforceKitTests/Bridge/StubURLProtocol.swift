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
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (Captured) -> Reply] = [:]
    nonisolated(unsafe) private static var captures: [String: [Captured]] = [:]

    static func install(host: String, _ handler: @escaping @Sendable (Captured) -> Reply) {
        lock.lock()
        handlers[host] = handler
        captures[host] = []
        lock.unlock()
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
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
