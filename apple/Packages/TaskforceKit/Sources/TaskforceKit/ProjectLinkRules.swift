import Foundation

// ProjectLink (디자인: 접힌 줄 `folder` + "Project · <기준>", 열면 "Why this project"와 Project 행)에 보일 값을 만드는 순수 규칙.
// 기준(basis)은 서버에 있는 origin 그대로다: user → "Set by you", auto → "Auto-linked", inferred → 확인되지 않은 후보, 멤버십 없음 → "No clear link".
// origin을 표시 문자열 · `actions.project` · 이름 일치 · 견본으로 짐작하지 않는다. 이유 Card는 서버 데이터(origin)에 있는 만큼만 말한다.

public enum ProjectLinkBasis: Sendable, Hashable {
    /// origin user: 사용자가 정했다
    case user
    /// origin auto: 코드 규칙이 이었다
    case auto
    /// origin inferred (또는 모르는 origin): 확인되지 않은 후보
    case candidate
    /// 확인된 멤버십이 없다
    case none

    public var label: String {
        switch self {
        case .user: "Set by you"
        case .auto: "Auto-linked"
        case .candidate: "Not confirmed"
        case .none: "No clear link"
        }
    }
}

/// ProjectLink 한 줄이 보이는 값
public struct ProjectLinkContent: Equatable, Sendable, Identifiable {
    public struct Choice: Equatable, Sendable, Hashable, Identifiable {
        /// nil = 이 범위에서 빼기 (멤버십이 이것 하나면 Ungrouped가 된다)
        public let contextID: UUID?
        public let name: String
        public var id: UUID? { contextID }

        public init(contextID: UUID?, name: String) {
            self.contextID = contextID
            self.name = name
        }
    }

    /// 이 줄의 범위 (멤버십 없음 줄은 nil)
    public let contextID: UUID?
    /// 접힌 줄의 제목 (멤버십 없음은 "Ungrouped")
    public let name: String
    public let basis: ProjectLinkBasis
    public let reason: String
    /// 팝업 선택지. 비었으면 팝업을 그리지 않고 `note`가 자리를 채운다
    public let choices: [Choice]
    public let canUndo: Bool
    /// 마지막으로 바꾸지 못한 이유 (한 줄)
    public let message: String?
    /// 팝업 대신 보이는 한 줄 (보관된 범위 · 범위 없음 · 바꿀 수 없음)
    public let note: String?
    public let isArchived: Bool
    /// 이 할 일의 요청이 진행 중: 컨트롤을 막는다
    public let isBusy: Bool

    public init(
        contextID: UUID?, name: String, basis: ProjectLinkBasis, reason: String, choices: [Choice] = [], canUndo: Bool = false,
        message: String? = nil, note: String? = nil, isArchived: Bool = false, isBusy: Bool = false
    ) {
        self.contextID = contextID
        self.name = name
        self.basis = basis
        self.reason = reason
        self.choices = choices
        self.canUndo = canUndo
        self.message = message
        self.note = note
        self.isArchived = isArchived
        self.isBusy = isBusy
    }

    public var id: String {
        switch (basis, contextID) {
        case (.none, _): "none"
        case (_, let contextID?): "project:\(contextID.uuidString)"
        default: "unknown"
        }
    }

    /// 접힌 줄의 상태 줄: "Project · Set by you" (보관된 범위는 "Project · Set by you · Archived")
    public var meta: String { "Project · " + basis.label + (isArchived ? WorkProject.archivedSuffix : "") }
}

/// 새 문구 (디자인 SSOT에 없음: 한 곳에서 고르고 기록한다, `s3b-mac-notes.md`)
public enum WorkProjectCopy {
    // 이유 Card (서버 데이터 = origin에 있는 만큼만)
    public static let reasonUser = "You linked this work to this project."
    public static let reasonAuto = "This link was made automatically. A project you choose yourself replaces it."
    public static let reasonCandidate = "Taskforce suggested this project. It isn't linked until you confirm it."
    public static let reasonNone = "This work isn't linked to a project."
    // Project 행 대신 보이는 한 줄
    public static let archivedNote = "Archived · can't be changed"
    public static let noProjects = "No projects yet"
    public static let writesUnavailable = "Can't be changed yet"
    // 후보 동작
    public static let confirm = "Confirm"
    public static let dismiss = "Dismiss"
    // 선택지
    public static let ungrouped = WorkListGroup.ungroupedTitle
    public static func removeFrom(_ name: String) -> String { "Remove from \(name)" }
    // 쓰기 안내 (한 줄)
    /// 409: 기존 문구 그대로 ("This changed somewhere else. It's been refreshed.")
    public static let conflict = APIError.server(status: 409, code: .conflict, message: "").userMessage
    public static let unconfirmed = "Couldn't confirm that change. Showing what's saved."
    public static let contextGone = "That project is archived or no longer exists."
    public static let workGone = "This work isn't available anymore."
    // 목록 위 Notice
    public static let couldNotLoad = "Couldn't load projects"
}

public enum ProjectLinkRules {
    /// Undo 버튼이 놓일 줄: 방금 확인된 범위(넣기 · 바꾸기 · 후보 확인)가 있으면 그 줄, 빼기만 했으면 남은 첫 줄(없으면 "No clear link" 줄)
    public enum UndoAnchor: Equatable, Sendable {
        case project(UUID)
        case unlinked
    }

    /// 한 할 일의 ProjectLink 줄들: 확인된 멤버십마다 한 줄(하나로 합치지 않는다), 하나도 없으면 "No clear link" 한 줄, 그 뒤에 후보마다 한 줄.
    /// 멤버십을 아직 읽지 못했으면 nil (아무 주장도 하지 않는다)
    /// - active: 고를 수 있는 범위 (status active만, 이름 순)
    /// - message/undo: 이 할 일의 마지막 쓰기 안내 · 방금 쓴 것의 Undo가 놓일 줄
    public static func links(
        memberships: WorkMemberships, active: [WorkProject], writesUnavailable: Bool, isBusy: Bool, undo: UndoAnchor?, message: String?,
        messageAnchor: UndoAnchor? = nil
    ) -> [ProjectLinkContent]? {
        guard case .known(let links, let candidates) = memberships else { return nil }
        let confirmedIDs = Set(links.map(\.id))
        var result: [ProjectLinkContent] = []

        func choices(removal: ProjectLinkContent.Choice?, current: WorkProject?) -> [ProjectLinkContent.Choice] {
            var rows: [ProjectLinkContent.Choice] = []
            if let removal { rows.append(removal) }
            if let current { rows.append(.init(contextID: current.id, name: current.name)) }
            for project in active where project.id != current?.id && !confirmedIDs.contains(project.id) {
                rows.append(.init(contextID: project.id, name: project.name))
            }
            return rows
        }

        if links.isEmpty {
            let rows = choices(removal: .init(contextID: nil, name: WorkProjectCopy.ungrouped), current: nil)
            result.append(ProjectLinkContent(
                contextID: nil, name: WorkProjectCopy.ungrouped, basis: .none, reason: WorkProjectCopy.reasonNone,
                choices: writesUnavailable || active.isEmpty ? [] : rows,
                note: writesUnavailable ? WorkProjectCopy.writesUnavailable : (active.isEmpty ? WorkProjectCopy.noProjects : nil), isBusy: isBusy
            ))
        }
        for link in links {
            let removal = ProjectLinkContent.Choice(
                contextID: nil, name: links.count == 1 ? WorkProjectCopy.ungrouped : WorkProjectCopy.removeFrom(link.project.name)
            )
            let readOnly = link.project.isArchived || writesUnavailable
            result.append(ProjectLinkContent(
                contextID: link.project.id, name: link.project.name, basis: link.origin == .auto ? .auto : .user,
                reason: link.origin == .auto ? WorkProjectCopy.reasonAuto : WorkProjectCopy.reasonUser,
                choices: readOnly ? [] : choices(removal: removal, current: link.project),
                note: link.project.isArchived ? WorkProjectCopy.archivedNote : (writesUnavailable ? WorkProjectCopy.writesUnavailable : nil),
                isArchived: link.project.isArchived, isBusy: isBusy
            ))
        }
        for candidate in candidates {
            result.append(ProjectLinkContent(
                contextID: candidate.project.id, name: candidate.project.name, basis: .candidate, reason: WorkProjectCopy.reasonCandidate,
                note: writesUnavailable ? WorkProjectCopy.writesUnavailable : nil, isBusy: isBusy
            ))
        }

        // Undo는 방금 확인된 범위의 줄에, 안내는 사용자가 동작한 줄에 놓는다 (없으면 첫 줄)
        func index(of anchor: UndoAnchor?, allowsCandidate: Bool) -> Int {
            guard case .project(let id)? = anchor else { return 0 }
            return result.firstIndex { $0.contextID == id && (allowsCandidate || $0.basis != .candidate) } ?? 0
        }
        if undo != nil || message != nil {
            let undoIndex = index(of: undo, allowsCandidate: false)
            let messageIndex = message == nil ? undoIndex : index(of: messageAnchor ?? undo, allowsCandidate: true)
            for position in Set([undoIndex, messageIndex]) where result.indices.contains(position) {
                let row = result[position]
                result[position] = ProjectLinkContent(
                    contextID: row.contextID, name: row.name, basis: row.basis, reason: row.reason, choices: row.choices,
                    canUndo: undo != nil && position == undoIndex, message: position == messageIndex ? message : nil, note: row.note,
                    isArchived: row.isArchived, isBusy: row.isBusy
                )
            }
        }
        return result
    }
}

extension ChatProject {
    /// 대화 헤더의 ProjectLink도 같은 줄 모양으로 그린다 (대화의 범위는 사용자가 명시적으로 고른 것뿐: Set by you · No clear link)
    public var content: ProjectLinkContent {
        ProjectLinkContent(
            contextID: contextID, name: name, basis: basis == .user ? .user : .none, reason: reason,
            choices: choices.map { ProjectLinkContent.Choice(contextID: $0.contextID, name: $0.name) }, canUndo: canUndo, message: message
        )
    }
}
