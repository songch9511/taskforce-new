import Foundation
import Network

/// 목록을 어떤 상태로 보이나 (Figma M15 · M19 · M20, iPhone P10)
public enum RefreshState: Sendable, Hashable {
    /// 처음 불러오는 중 (보일 목록이 아직 서버에서 오지 않음. 저장본이 있으면 그것을 보이며 기다린다)
    case loading
    /// 온라인, 마지막 `/now`가 성공함
    case live
    /// 오프라인, 저장본(또는 이번 실행에서 받은 목록)을 보임: "Offline since 8:01."
    case offlineSaved(since: Date, savedAt: Date)
    /// 오프라인, 보일 목록이 없음 (M20 "Nothing saved on this Mac yet")
    case offlineEmpty(since: Date)
    /// 온라인인데 `/now`가 실패함: "Couldn't refresh at 10:46. Showing 10:31." 보일 목록이 없으면 `savedAt`은 nil
    case refreshFailed(at: Date, savedAt: Date?)

    /// 오프라인 두 상태
    public var isOffline: Bool {
        switch self {
        case .offlineSaved, .offlineEmpty: true
        default: false
        }
    }
}

/// 연결 · 불러오기 사건으로 `RefreshState`를 정한다 (화면 없는 순수 규칙).
/// "보이는 목록의 시각"(`shownAt`)은 이번 실행에서 받은 마지막 `/now` 시각, 없으면 저장본의 저장 시각이다.
public struct RefreshTracker: Sendable, Hashable {
    /// 경로를 아직 모르면 온라인으로 본다 (불러오기를 막지 않게)
    public private(set) var isOnline = true
    public private(set) var offlineSince: Date?
    /// 보이는 목록의 시각
    public private(set) var shownAt: Date?
    /// 보이는 목록이 이번 실행에서 서버로부터 받은 것인가 (저장본이면 false)
    public private(set) var isLive = false
    /// 마지막 성공 뒤의 실패 시각
    public private(set) var failedAt: Date?
    public private(set) var isLoading = false

    public init() {}

    public var state: RefreshState {
        if !isOnline {
            let since = offlineSince ?? shownAt ?? .distantPast
            return shownAt.map { .offlineSaved(since: since, savedAt: $0) } ?? .offlineEmpty(since: since)
        }
        if let failedAt { return .refreshFailed(at: failedAt, savedAt: shownAt) }
        return isLive ? .live : .loading
    }

    /// 연결 경로가 바뀌었다. 오프라인에서 온라인으로 돌아오면 true: 목록을 다시 불러온다 (M20 "연결이 돌아오면 자동으로").
    @discardableResult
    public mutating func pathChanged(online: Bool, at date: Date) -> Bool {
        guard online != isOnline else { return false }
        isOnline = online
        offlineSince = online ? nil : date
        // 돌아오면 곧 다시 불러오므로 지난 실패는 보이지 않는다
        if online { failedAt = nil }
        return online
    }

    /// 앱이 시작할 때 이 계정의 저장본을 읽었다
    public mutating func restoredSaved(savedAt: Date) {
        guard !isLive else { return }
        shownAt = savedAt
    }

    public mutating func loadStarted() {
        isLoading = true
    }

    public mutating func loadSucceeded(at date: Date) {
        isLoading = false
        isLive = true
        shownAt = date
        failedAt = nil
    }

    /// 불러오기 실패. 오프라인이면 오프라인 상태가 그대로 설명하므로 실패로 적지 않는다.
    public mutating func loadFailed(at date: Date) {
        isLoading = false
        if isOnline { failedAt = date }
    }

    /// 계정 전환 · 로그아웃: 연결 상태만 남기고 비운다
    public mutating func reset() {
        shownAt = nil
        isLive = false
        failedAt = nil
        isLoading = false
    }
}

/// 연결 경로 (NWPathMonitor). 시작하면 지금 상태를 한 번 보내고, 바뀔 때마다 보낸다. 스트림을 끝내면 감시를 멈춘다.
public enum Connectivity {
    public static func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.taskforcelabs.taskforce.connectivity"))
        }
    }
}
