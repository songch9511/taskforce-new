import Foundation

// OA D4b-m-1 (계약 9장): 질문 카드의 UI 문구. 두 갈래다.
// - `AgentQuestionCopy`: DS에 이미 있는 말 (QuestionCard README · Composer README). 승인됐다 — 바꾸지 않는다
// - `AgentQuestionUnapprovedCopy`: 이번에 처음 쓴 새 말 둘. 사용자가 PR #157에서 승인했다(2026-10-18): "Answer on another Mac" · 알림 본문 "Needs your answer".
//   승인 전에는 후보를 Debug 견본에만 두었으나(D4a와 같은 방식) 이제 앱이 쓰는 값(`approved`)이 이 둘이고 Release에도 컴파일된다. 후보 상수와 견본의 미리보기 스위치는 없앴다.
//   질문 카드 · 알림 자체는 여전히 `EdgeSurfaces.agentQuestions` 게이트 뒤라 Release에서는 닿지 않는다.
//   - 값이 비어 있는 `AgentQuestionUnapprovedCopy()`의 대체(시험이 본다): 이름을 모르는 다른 Mac의 비밀값 카드는 "Answer on …" 줄 없이 메타 "Can't be entered here"만 말하고, 알림은 본문이 없다

/// DS에 있는 말 (승인됨)
public enum AgentQuestionCopy {
    public static let answerSent = "Answer sent"
    public static let undo = "Undo"
    public static let send = "Send"
    public static let staysOnThisMac = "Stays on this Mac"
    public static let cantBeEnteredHere = "Can't be entered here"
    public static let otherField = "Other"
    /// 비밀값 칸의 접근성 이름 (DS: "Answer. It stays on this Mac.")
    public static let secretFieldLabel = "Answer. It stays on this Mac."
    /// 승인 질문의 미리보기를 읽는 이름
    public static let previewLabel = "Request"

    /// 다른 기기에서 본 비밀값 카드: "Answer on Mina's MacBook Pro" (DS)
    public static func answerOn(_ macName: String) -> String { "Answer on \(macName)" }
}

/// 이번에 새로 쓴 문구 (승인됨)
public struct AgentQuestionUnapprovedCopy: Equatable, Sendable {
    /// Mac 이름을 모를 때 다른 기기 비밀값 카드의 줄 (D4bm-41)
    public var anotherMac: String?
    /// 질문 알림의 본문 (D4bm-61): 제목은 에이전트 이름
    public var questionNotificationBody: String?

    public init(anotherMac: String? = nil, questionNotificationBody: String? = nil) {
        self.anotherMac = anotherMac
        self.questionNotificationBody = questionNotificationBody
    }

    /// 지금 앱이 쓰는 새 문구 (사용자 승인 2026-10-18, PR #157)
    public static let approved = AgentQuestionUnapprovedCopy(anotherMac: "Answer on another Mac", questionNotificationBody: "Needs your answer")

    public var isEmpty: Bool { self == Self.init() }

    /// 다른 기기 비밀값 카드의 "Answer on …" 줄: 이름이 있으면 그 이름, 없으면 대체 문구 "Answer on another Mac" (비어 있는 값이면 nil → 줄을 그리지 않는다)
    public func remoteRow(macName: String?) -> String? {
        if let macName, !macName.isEmpty { return AgentQuestionCopy.answerOn(macName) }
        return anotherMac
    }
}

/// 지금 화면이 쓰는 새 문구 (한 곳)
public enum AgentQuestionNewCopy {
    public static var active: AgentQuestionUnapprovedCopy { .approved }
}
