#if os(macOS)
import Darwin
import Foundation

/// 훅 쪽 Unix 소켓 연결 (OA D3a 계약 2.6): 한 줄을 쓰고 `\n`까지 한 줄을 읽는다. 연결 · 쓰기 · 읽기는 모두 한 기한(`deadline`) 안에서 `poll`로 기다린다
public enum UnixSocket {
    /// `sun_path`는 104바이트(NUL 포함). 103바이트를 넘는 경로는 bind · connect하지 못한다
    public static let maxPathBytes = 103

    public static func exchange(path: String, request: Data, deadline: Date, maxResponseBytes: Int = HookWire.maxLineBytes) throws -> Data {
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty, pathBytes.count <= maxPathBytes, !pathBytes.contains(0) else { throw WireError.pathTooLong }
        guard remaining(deadline) > 0 else { throw WireError.timedOut }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.connectFailed }
        defer { close(fd) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw WireError.connectFailed }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes + [0])
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw WireError.connectFailed }
            try wait(fd, for: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw WireError.connectFailed }
        }

        var sent = 0
        let bytes = [UInt8](request)
        while sent < bytes.count {
            let count = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + sent, $0.count - sent) }
            if count > 0 {
                sent += count
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                try wait(fd, for: Int16(POLLOUT), deadline: deadline)
            } else {
                throw WireError.closed
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let newline = response.firstIndex(of: 0x0A) {
                return response.prefix(through: newline)
            }
            try wait(fd, for: Int16(POLLIN), deadline: deadline)
            let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
                guard response.count <= maxResponseBytes else { throw WireError.tooLarge }
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                continue
            } else {
                // 줄 끝 없이 닫혔다: 받은 것이 한 줄이면 그대로, 아니면 실패
                guard !response.isEmpty else { throw WireError.closed }
                return response
            }
        }
    }

    static func remaining(_ deadline: Date) -> TimeInterval { deadline.timeIntervalSinceNow }

    /// 기한까지 `events`를 기다린다. 기한이 지나면 `timedOut`
    static func wait(_ fd: Int32, for events: Int16, deadline: Date) throws {
        while true {
            let left = remaining(deadline)
            guard left > 0 else { throw WireError.timedOut }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&item, 1, Int32(max(1, min(Double(Int32.max), (left * 1000).rounded(.up)))))
            if ready > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw WireError.closed }
                return
            }
            if ready < 0, errno != EINTR { throw WireError.closed }
        }
    }
}
#endif
