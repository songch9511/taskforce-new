#if os(macOS)
import Foundation

/// Sessions 패널의 승인된 문구 (DZ 승인 2026-10-22 `oa-rail-sessions-dz`): 새 문구는 Sessions · ⌘4 · Taskforce · Done · No sessions다. 나머지는 이미 있던 말이다
public enum SessionsPanelCopy {
    /// 레일 첫 캡슐의 버튼 이름 · 툴팁 · 접근성 이름 · 패널 제목
    public static let title = "Sessions"
    /// 툴팁의 단축키 (⌘1 Taskforce · ⌘2 Projects · ⌘3 Chats 다음)
    public static let shortcut = "⌘4"
    public static let taskforce = "Taskforce"
    public static let onThisMac = ExternalSessionCopy.sectionTitle
    public static let noSessions = "No sessions"
    /// 끝났고 아직 안 연 세션의 말 (옛 "Done just now"는 링이 몇 시간 남아 거짓이 된다)
    public static let done = AgentSessionRules.done
}

/// 줄들이 Resume here를 어떻게 보이나 (OA 외부 세션 PR2m): 게이트 + 줄마다의 확인 상태
public struct ExternalSessionAttachPresentation: Equatable, Sendable {
    public var gate: ExternalSessionAttachModel.Gate
    public var phases: [String: ExternalSessionAttachModel.Phase]

    public init(gate: ExternalSessionAttachModel.Gate, phases: [String: ExternalSessionAttachModel.Phase]) {
        self.gate = gate
        self.phases = phases
    }

    /// 이어받기가 없다 (게이트 닫힘): 줄은 이전 그대로
    public static let off = ExternalSessionAttachPresentation(gate: .unavailable, phases: [:])
}

/// 한 절 (Taskforce · On this Mac): 보일 줄과 접힌 줄. 링 있는 줄(주황 · 도는 중 · 끝)은 접지 않고 쉬는 줄 · 끝난 줄만 셋 뒤로 접는다 (`Show all` · `Show less`)
public struct SessionsSection<Row: Identifiable & Sendable & Equatable>: Equatable, Sendable {
    /// 지금 보일 줄 (순서대로)
    public var rows: [Row]
    /// 접혀서 안 보이는 줄 수 (펼쳤으면 0)
    public var hiddenCount: Int
    /// 머리 오른쪽에 Show all · Show less 링크가 있나 (접을 수 있는 줄이 `foldLimit`보다 많다)
    public var togglesFold: Bool
    public var expanded: Bool

    public init(rows: [Row], hiddenCount: Int, togglesFold: Bool, expanded: Bool) {
        self.rows = rows
        self.hiddenCount = hiddenCount
        self.togglesFold = togglesFold
        self.expanded = expanded
    }

    public var isEmpty: Bool { rows.isEmpty }
}

/// Taskforce 절의 줄 하나 (이슈의 세션). 에이전트 마크 · 이름 · "상태 · 마지막 활동 · 이슈 번호", 줄 끝에 링. 끝난(closed) 세션은 상태 말 없이 흐리게
public struct SessionsTaskforceRow: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let name: String
    public let agent: AgentMarkKind
    /// 줄 끝의 링. 닫힌 세션은 없다
    public let ring: AgentSessionRing?
    public let isClosed: Bool
    /// 둘째 줄: "{상태} · {시각} · #{번호}" (닫힌 줄은 상태 없이, 번호를 모르면 번호 없이)
    public let metaText: String
    public let accessibilityName: String

    public init(id: UUID, name: String, agent: AgentMarkKind, ring: AgentSessionRing?, isClosed: Bool, metaText: String, accessibilityName: String) {
        self.id = id
        self.name = name
        self.agent = agent
        self.ring = ring
        self.isClosed = isClosed
        self.metaText = metaText
        self.accessibilityName = accessibilityName
    }

    /// 글 · id를 찍지 않는다
    public var description: String { "SessionsTaskforceRow(ring: \(ring.map(\.rawValue) ?? "none"))" }
    public var debugDescription: String { description }
}

/// On this Mac 절의 줄 하나 (이 Mac의 Claude 세션). Taskforce가 상태를 아는 살아 있는 데스크톱 줄에는 링이 있고, 누르면 Claude 세션 보기가 열린다
public struct SessionsMacRow: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Claude 세션 id (이 Mac 안에서만)
    public let id: String
    public let row: ExternalSessionRow
    public let line: ExternalSessionLineContent
    /// 살아 있는 데스크톱 세션의 링. 그 밖의 줄(터미널 · 막힘 · 모름)은 없다
    public let ring: AgentSessionRing?
    /// 줄을 누르면 Claude 세션 보기(`ClaudeAppSessionPanel`)가 열린다: Taskforce가 상태를 아는 살아 있는 데스크톱 줄뿐
    public let opensSession: Bool
    /// 이 줄 밑에 서 있는 Resume here 확인의 상태 (없으면 nil)
    public let attach: ExternalSessionAttachModel.Phase?

    public init(id: String, row: ExternalSessionRow, line: ExternalSessionLineContent, ring: AgentSessionRing?, opensSession: Bool, attach: ExternalSessionAttachModel.Phase? = nil) {
        self.id = id
        self.row = row
        self.line = line
        self.ring = ring
        self.opensSession = opensSession
        self.attach = attach
    }

    /// 제목 · 경로 · id를 찍지 않는다
    public var description: String { "SessionsMacRow(ring: \(ring.map(\.rawValue) ?? "none"), opensSession: \(opensSession))" }
    public var debugDescription: String { description }
}

/// Sessions 패널의 줄을 정하는 순수 규칙 (OA PR-D2, 계약 23장):
/// - **출처별 두 절**: "Taskforce"(이슈의 세션: 돌고 있는 것 · 끝난 것 · 쉬는 것 · 닫힌 것) → "On this Mac"(이 Mac의 Claude 세션). 이어받은 세션은 Taskforce 절에만 나온다 (두 목록에 중복 없음). 폴더 묶음은 없다
/// - 줄 순서: 링 있는 줄(needs-you → running → done …, 새것 먼저) → 쉬는 줄 → 끝난(닫힌) 줄. 링 있는 줄은 **Show all 밑으로 접지 않는다** (레일 용량 넷을 넘친 링을 여기서 본다는 23장 결정). 쉬는 줄 · 끝난 줄은 절마다 셋 뒤로 접는다
/// - 빈 절은 머리째 없다. 두 절이 모두 비면 패널 전체가 "No sessions"
public enum SessionsPanelRules {
    public static let foldLimit = 3

    // MARK: Taskforce 절

    /// - issueNumber: 이슈 id → 번호 (모르면 nil: 번호 없이, 지어내지 않는다)
    public static func taskforce(
        _ items: [AgentSessionItem], issueNumber: (UUID) -> Int?, now: Date, expanded: Bool, timeZone: TimeZone = .current
    ) -> SessionsSection<SessionsTaskforceRow> {
        let ordered = items.sorted { lhs, rhs in
            let (l, r) = (taskforceRank(lhs), taskforceRank(rhs))
            if l != r { return l < r }
            return lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
        }
        let rows = ordered.map { item -> (row: SessionsTaskforceRow, isRing: Bool) in
            let time = ExternalSessionLineText.timeLabel(item.updatedAt, now: now, timeZone: timeZone)
            let number = (item.currentIssueID ?? item.issueIDs.first).flatMap(issueNumber).flatMap { IssueNumberStore.label($0) }
            let parts = (item.isClosed || item.line.isEmpty ? [] : [item.line]) + [time] + (number.map { [$0] } ?? [])
            let meta = parts.joined(separator: " · ")
            let row = SessionsTaskforceRow(
                id: item.id, name: item.name, agent: item.agent, ring: item.ring, isClosed: item.isClosed, metaText: meta,
                accessibilityName: "\(item.name) — \(item.agentName) — \(meta)"
            )
            return (row, hasRing(item.ring))
        }
        return fold(rows, expanded: expanded)
    }

    /// 작을수록 앞: needs-you → running · stopping · unreachable → done → waiting → 쉬는 줄 → 닫힌 줄
    private static func taskforceRank(_ item: AgentSessionItem) -> Int {
        if item.isClosed { return 5 }
        guard let ring = item.ring else { return 4 }
        switch ring {
        case .needsYou: return 0
        case .running, .stopping, .unreachable: return 1
        case .done: return 2
        case .waiting: return 3
        case .idle: return 4
        }
    }

    /// 링 있는 줄: 주황 · 도는 중 · 끝 · 그 밖의 레일 종류. 쉬는 줄(idle) · 링 없는 줄은 접힐 수 있다
    private static func hasRing(_ ring: AgentSessionRing?) -> Bool {
        guard let ring else { return false }
        return ring != .idle
    }

    // MARK: On this Mac 절

    /// - live: 이 Claude 세션 id의 살아 있는 데스크톱 상태 (Taskforce가 아는 것). 모르면 nil: 앞 승인 그대로의 줄
    /// - notice: 방금 "다른 터미널에 열려 있다"고 막힌 쉬는 줄 하나의 (id, 글)
    /// - busy: 방금 누른 Open in Claude가 도는 줄들 ("Opening…")
    public static func onThisMac(
        _ rows: [ExternalSessionRow], live: (String) -> ClaudeAppLiveStatus?, now: Date, expanded: Bool, notice: (id: String, text: String)? = nil,
        busy: Set<String> = [], timeZone: TimeZone = .current, attach: ExternalSessionAttachPresentation = .off
    ) -> SessionsSection<SessionsMacRow> {
        let listed = rows.filter { $0.status != .inTaskforce }.map { row -> (row: ExternalSessionRow, status: ClaudeAppLiveStatus?) in (row, live(row.id)) }
        // 링 있는 줄(주황 → 도는 중 → 끝, 새것 먼저)을 앞에, 나머지는 훑은 순서 그대로
        let ringRows = listed.filter { $0.status.map(hasRingRow) ?? false }.sorted { lhs, rhs in
            let (l, r) = (macRank(lhs.status), macRank(rhs.status))
            if l != r { return l < r }
            return lhs.row.lastActivity != rhs.row.lastActivity ? lhs.row.lastActivity > rhs.row.lastActivity : lhs.row.id < rhs.row.id
        }
        let rest = listed.filter { !($0.status.map(hasRingRow) ?? false) }
        let built = (ringRows + rest).map { entry -> (row: SessionsMacRow, isRing: Bool) in
            let isBusy = busy.contains(entry.row.id)
            var line: ExternalSessionLineContent
            var phase: ExternalSessionAttachModel.Phase?
            if let status = entry.status {
                line = ExternalSessionLineText.make(entry.row, live: status, now: now, timeZone: timeZone, busy: isBusy)
            } else {
                line = ExternalSessionLineText.make(
                    entry.row, now: now, timeZone: timeZone, notice: notice?.id == entry.row.id ? notice?.text : nil, busy: isBusy
                )
                // 이어받기 (OA 외부 세션 PR2m, 계약 8.2 · 8.3): 아무 곳에서도 열려 있지 않은 줄(Idle)에만. Open in Claude가 도는 중인 줄은 건드리지 않는다
                if entry.row.status == .available, !isBusy {
                    switch attach.gate {
                    case .ready where entry.row.folderPath != nil:
                        if let standing = attach.phases[entry.row.id] {
                            // 확인이 서 있는 동안은 줄의 버튼을 숨긴다 (확인 단추와 겹쳐 보이지 않게)
                            line.action = nil
                            line.extraActions = []
                            phase = standing
                        } else {
                            // DZ: 눈에 보이는 버튼은 Resume here 하나, Open in Claude(쉬는 데스크톱 줄)는 VoiceOver 동작으로 남는다
                            if line.action == .openInClaude { line.extraActions = [.openInClaude] }
                            line.action = .resumeHere
                        }
                    case .notReady(let word):
                        // 서버는 열렸는데 이 Mac의 대상이 ready가 아니다: 줄은 그 대상 단어를 말한다 (계약 8.2-8)
                        line.statusWord = word
                        line.statusIsEmphasis = false
                    default: break
                    }
                }
            }
            let mac = SessionsMacRow(id: entry.row.id, row: entry.row, line: line, ring: entry.status?.ring, opensSession: entry.status != nil, attach: phase)
            // 확인이 서 있는 줄은 접히지 않는다 (보이지 않는 확인이 남지 않게)
            return (mac, (entry.status.map(hasRingRow) ?? false) || phase != nil)
        }
        return fold(built, expanded: expanded)
    }

    /// 주황 · 도는 중 · 끝 (쉬는 데스크톱 줄은 링이 있어도 접힐 수 있다)
    private static func hasRingRow(_ status: ClaudeAppLiveStatus) -> Bool {
        status != .idle
    }

    private static func macRank(_ status: ClaudeAppLiveStatus?) -> Int {
        switch status {
        case .needsApproval?, .needsAnswer?: 0
        case .running?: 1
        case .done?: 2
        case .idle?, nil: 3
        }
    }

    // MARK: 접기 · 비었나

    /// 링 있는 줄은 늘 보이고, 나머지는 `foldLimit`개까지 (펼치면 모두). 순서는 그대로
    private static func fold<Row: Identifiable & Sendable & Equatable>(_ rows: [(row: Row, isRing: Bool)], expanded: Bool) -> SessionsSection<Row> {
        let quiet = rows.filter { !$0.isRing }.count
        var shownQuiet = 0
        var shown: [Row] = []
        for entry in rows {
            if entry.isRing || expanded {
                shown.append(entry.row)
            } else if shownQuiet < foldLimit {
                shown.append(entry.row)
                shownQuiet += 1
            }
        }
        return SessionsSection(rows: shown, hiddenCount: expanded ? 0 : max(0, quiet - foldLimit), togglesFold: quiet > foldLimit, expanded: expanded && quiet > foldLimit)
    }

    /// 패널 전체가 "No sessions"인가: 두 절 모두 줄이 없다
    public static func isEmpty(taskforce: SessionsSection<SessionsTaskforceRow>, mac: SessionsSection<SessionsMacRow>) -> Bool {
        taskforce.isEmpty && mac.isEmpty
    }
}

extension ExternalSessionLineText {
    /// 살아 있는 데스크톱 세션의 줄 (Taskforce가 상태를 안다): 상태 말은 `live.word`, 굵은 것은 "Running in Claude"뿐이다 (승인된 모양).
    /// 도는 중 · 승인 · 답을 기다림은 시각만, 끝남 · 쉼은 시각 뒤에 출처("Claude desktop")를 붙인다. Open in Claude는 늘 있다
    public static func make(_ row: ExternalSessionRow, live: ClaudeAppLiveStatus, now: Date, timeZone: TimeZone = .current, busy: Bool = false) -> ExternalSessionLineContent {
        let time = timeLabel(row.lastActivity, now: now, timeZone: timeZone)
        let detail: [String] = switch live {
        case .running, .needsApproval, .needsAnswer: [time]
        case .done, .idle: [time, ExternalSessionCopy.claudeDesktop]
        }
        var content = ExternalSessionLineContent(title: title(row), statusWord: live.word, statusIsEmphasis: live == .running, detail: detail, action: .openInClaude)
        content.isBusy = busy
        return content
    }
}
#endif
