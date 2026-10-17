import Foundation

// OA D4b-m-1 (계약 4.3 D4bm-21 실패 표): 답이 서버에 닿지 못했을 때 카드가 돌아오며 한 줄로 말하는 이유와, 서버 값에 따라 카드가 할 일.
// 말은 DS(QuestionCard "failed")와 기존 문장(`APIClient.userMessage`)뿐이다: 새 문구 없음. 서버의 한국어 거절 문구는 화면에 쓰지 않는다.

/// 카드가 돌아오며 말하는 이유 ("Couldn't send" 뒤 한 줄)
public enum AgentQuestionFailure: Sendable, Equatable {
    case offline
    case generic

    /// DS: "You're offline. Try again."
    public static let offlineReason = "You're offline. Try again."
    /// 기존 문장 (`APIClient.swift`의 일반 오류): "Something went wrong. Try again in a moment."
    public static let genericReason = "Something went wrong. Try again in a moment."
    /// 굵은 앞 말 (DS `.tf-fn-strong`, 빨강 아님)
    public static let lead = "Couldn't send"

    public var reason: String {
        switch self {
        case .offline: Self.offlineReason
        case .generic: Self.genericReason
        }
    }
}

/// 답 요청이 끝났을 때 카드가 할 일 (표 한 줄)
public enum AgentQuestionAnswerResult: Sendable, Equatable {
    /// 200 `answered` · `duplicate`
    case sent
    /// 409 `busy_retry`: 서버가 "같은 요청을 다시 보내도 된다"고 정했다 — 한 번만 다시 보낸다
    case retryOnce
    /// 409 `question_stale` · 404 `not_found` (기능 꺼짐 404 포함): 카드를 지우고 다시 읽는다
    case clearAndReread
    /// 그 밖: 카드가 돌아오고 사용자가 다시 고른다
    case failed(AgentQuestionFailure)

    /// 서버 오류 → 할 일. 네트워크 오류(`transport`)는 오프라인이고, 코드 없는 거절 · 5xx · 429 · 400 · `secret_requires_local`(일어나면 안 되는 앱 버그)은 일반 이유다
    public static func of(_ error: Error) -> AgentQuestionAnswerResult {
        guard let api = error as? APIError else {
            if let url = error as? URLError { return .failed(url.code == .notConnectedToInternet || url.code == .networkConnectionLost ? .offline : .generic) }
            return .failed(.generic)
        }
        switch api {
        case .transport:
            return .failed(.offline)
        case .server(_, let code, _):
            switch code {
            case .busyRetry: return .retryOnce
            case .questionStale, .notFound: return .clearAndReread
            default: return .failed(.generic)
            }
        case .notSignedIn, .unexpectedStatus, .decoding:
            return .failed(.generic)
        }
    }
}
