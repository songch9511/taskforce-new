import Foundation

// OA D4b-m-1 (계약 9장): 질문 카드의 UI 문구. 두 갈래다.
// - `AgentQuestionCopy`: DS에 이미 있는 말 (QuestionCard README · Composer README). 승인됐다 — 바꾸지 않는다
// - `AgentQuestionUnapprovedCopy`: 이번에 처음 쓰는 새 말 둘. **승인 전 후보를 한 곳에 모은다** (D4a와 같은 방식): 앱이 쓰는 값(`approved`)에는 새 말이 하나도 없고,
//   후보(`candidates`)는 Debug 견본 앱에서만 보인다 (Release 바이너리에는 이 글자가 들어가지 않는다). 승인되면 `approved`를 후보 값으로 바꾸고(이 파일 한 곳) `candidates`를 지운다.
//   - 새 말이 없을 때의 대체: 이름을 모르는 다른 Mac의 비밀값 카드는 "Answer on …" 줄 없이 메타 "Can't be entered here"만 말하고, 알림은 제목(에이전트 이름)만 있고 본문이 없다

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

/// 승인 전 새 문구
public struct AgentQuestionUnapprovedCopy: Equatable, Sendable {
    /// Mac 이름을 모를 때 다른 기기 비밀값 카드의 줄 (D4bm-41)
    public var anotherMac: String?
    /// 질문 알림의 본문 (D4bm-61): 제목은 에이전트 이름
    public var questionNotificationBody: String?

    public init(anotherMac: String? = nil, questionNotificationBody: String? = nil) {
        self.anotherMac = anotherMac
        self.questionNotificationBody = questionNotificationBody
    }

    /// 지금 앱이 쓰는 새 문구: 없다
    public static let approved = AgentQuestionUnapprovedCopy()

    #if DEBUG
    /// 계약 9장의 후보 (승인 전, 견본 · 시험 전용). **Debug 빌드에만 있다**
    public static let candidates = AgentQuestionUnapprovedCopy(anotherMac: "Answer on another Mac", questionNotificationBody: "Needs your answer")
    #endif

    public var isEmpty: Bool { self == Self.init() }

    /// 다른 기기 비밀값 카드의 "Answer on …" 줄: 이름이 있으면 그 이름, 없으면 승인된 대체 문구 (없으면 nil → 줄을 그리지 않는다)
    public func remoteRow(macName: String?) -> String? {
        if let macName, !macName.isEmpty { return AgentQuestionCopy.answerOn(macName) }
        return anotherMac
    }
}

/// 지금 화면이 쓰는 새 문구 (한 곳). Release에서는 늘 `approved`다
public enum AgentQuestionNewCopy {
    #if DEBUG
    /// 견본 앱(`-TFEdgeSnapshotQuestions`)만 켠다: 승인 전 후보를 화면에 그린다. 시험은 이 값을 건드리지 않고 문구를 직접 넘긴다
    nonisolated(unsafe) public static var isPreviewing = false
    public static var active: AgentQuestionUnapprovedCopy { isPreviewing ? .candidates : .approved }
    #else
    public static var active: AgentQuestionUnapprovedCopy { .approved }
    #endif
}
