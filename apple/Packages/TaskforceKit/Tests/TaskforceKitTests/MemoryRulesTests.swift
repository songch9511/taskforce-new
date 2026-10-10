import Foundation
import Testing
@testable import TaskforceKit

/// Remembered의 순수 규칙: kind · 범위 이름 · 한 줄 메타 · 동작이 있나 · 출처 표시(사실대로)
struct MemoryRulesTests {
    let project = ChatContractFixtures.contextID
    var contexts: [UUID: WorkContext] { [project: WorkContext(id: project, name: "Shape launch")] }

    @Test func kindAndInferredWordsFollowTheDesign() {
        let explicit = Memories.item(1, origin: .explicit, scope: .context, context: project)
        let inferred = Memories.item(2, origin: .inferred, scope: .context, context: project)
        #expect(MemoryText.kindLine(explicit) == "Explicit")
        #expect(MemoryText.kindLine(inferred) == "Inferred · Unconfirmed")
        #expect(MemoryText.meta(explicit, contexts: contexts, withTime: false) == "Explicit · Shape launch")
        #expect(MemoryText.meta(inferred, contexts: contexts, withTime: false) == "Inferred · Unconfirmed · Shape launch")
        let now = Date.test(3600)
        #expect(MemoryText.meta(explicit, contexts: contexts, withTime: true, now: now, timeZone: TimeZone(identifier: "UTC")!) == "Explicit · Shape launch · Today 09:00")
        #expect(MemoryText.isTentative(inferred) && !MemoryText.isTentative(explicit))
        // 정정으로 대체된 추정은 "Unconfirmed"를 주장하지 않는다 (지금 기억이 아니다)
        #expect(MemoryText.kindLine(Memories.item(3, origin: .inferred, superseded: true)) == "Inferred")
    }

    @Test func scopeNamesAreTruthfulWhenTheProjectIsUnknown() {
        #expect(MemoryText.scope(Memories.item(1), contexts: contexts) == "All work")
        #expect(MemoryText.scope(Memories.item(2, scope: .context, context: project), contexts: contexts) == "Shape launch")
        #expect(MemoryText.scope(Memories.item(3, scope: .context, context: UUID()), contexts: contexts) == "Project")
        #expect(MemoryText.scope(Memories.item(4, scope: .action), contexts: contexts) == "A task")
        #expect(MemoryText.scope(Memories.item(5, scope: .counterpart), contexts: contexts) == "A person")
        #expect(MemoryText.scope(Memories.item(6, scope: .agent), contexts: contexts) == "An agent")
    }

    @Test func purgedStatementsSayTheTextIsGone() {
        let purged = Memories.item(1, origin: .observed, purged: true)
        #expect(purged.statement.isEmpty)
        #expect(MemoryText.statement(purged) == "Original text deleted")
        #expect(MemoryText.isTentative(purged))
        #expect(!MemoryText.canConfirm(purged), "확인할 글이 없다")
        #expect(MemoryText.statement(Memories.item(2, "Keeps FAQs short")) == "Keeps FAQs short")
    }

    @Test func onlyUnconfirmedInferencesCanBeConfirmedAndOnlyExplicitCanMove() {
        #expect(MemoryText.canConfirm(Memories.item(1, origin: .inferred)))
        #expect(!MemoryText.canConfirm(Memories.item(2, origin: .explicit)) && !MemoryText.canConfirm(Memories.item(3, origin: .observed)))
        #expect(!MemoryText.canConfirm(Memories.item(4, origin: .inferred, revoked: true)))
        #expect(MemoryText.canChangeScope(Memories.item(5, origin: .explicit)))
        #expect(MemoryText.canChangeScope(Memories.item(6, origin: .explicit, scope: .context, context: project)))
        for other in [Memories.item(7, origin: .observed), Memories.item(8, origin: .inferred), Memories.item(9, origin: .explicit, scope: .action),
                      Memories.item(10, origin: .explicit, scope: .agent), Memories.item(11, origin: .explicit, revoked: true)] {
            #expect(!MemoryText.canChangeScope(other), "\(other.origin) \(other.scopeKind)")
        }
    }

    @Test func scopeChoicesListActiveProjectsAndKeepAnArchivedCurrentOne() {
        let archived = UUID()
        let all: [UUID: WorkContext] = [
            project: WorkContext(id: project, name: "Shape launch"),
            ChatContractFixtures.otherContextID: WorkContext(id: ChatContractFixtures.otherContextID, name: "Acme website"),
            archived: WorkContext(id: archived, name: "Old project", status: .archived),
        ]
        let global = MemoryText.scopeChoices(for: Memories.item(1), contexts: all)
        #expect(global.map(\.name) == ["All work", "Acme website", "Shape launch"], "보관된 프로젝트는 고르는 목록에 없다")
        let inArchived = MemoryText.scopeChoices(for: Memories.item(2, scope: .context, context: archived), contexts: all)
        #expect(inArchived.last?.name == "Old project" && inArchived.last?.target == .context(archived))
        #expect(MemoryText.currentTarget(Memories.item(3, scope: .context, context: project)) == .context(project))
        #expect(MemoryText.currentTarget(Memories.item(4)) == .global)
        #expect(MemoryText.currentTarget(Memories.item(5, scope: .action)) == nil)
    }

    @Test func editedStatementIsTrimmedAndBounded() {
        #expect(MemoryText.editedStatement("  배포는 목요일 \n") == "배포는 목요일")
        #expect(MemoryText.editedStatement(" ") == nil)
        #expect(MemoryText.editedStatement(String(repeating: "a", count: 1000)) != nil)
        #expect(MemoryText.editedStatement(String(repeating: "a", count: 1001)) == nil)
    }

    // MARK: 출처

    func source(
        kind: SourceKind = .message, url: String? = "https://app.slack.com/client/T1/C1", title: String? = "#launch", accessLost: Bool = false,
        purgedAt: String? = nil, reason: String? = nil
    ) -> MemorySource {
        func string(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let json = """
        {"id":"\(ChatContractFixtures.sourceID.uuidString.lowercased())","kind":"\(kind.rawValue)","title":\(string(title)),"occurred_at":"2026-10-10T01:00:00Z",
         "external_url":\(string(url)),"created_at":"2026-10-10T01:00:00Z","processing_status":"done","meeting":null,
         "access_lost_at":\(string(accessLost ? "2026-10-10T03:00:00Z" : nil)),"raw_text_purged_at":\(string(purgedAt)),"raw_text_purge_reason":\(string(reason))}
        """
        return try! TaskforceJSON.decoder().decode(MemorySource.self, from: Data(json.utf8))
    }

    @Test func sourceWithQuoteShowsServiceTitleAndTime() {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Could we do Thursday instead?")
        let item = Memories.item(1, origin: .inferred, sourceRef: ref)
        guard case .quote(let quote) = MemorySourceRules.display(item: item, lookup: .loaded(message: nil, source: source())) else {
            Issue.record("인용이 아님")
            return
        }
        #expect(quote.service == .slack && quote.text == "Could we do Thursday instead?" && quote.place == "#launch" && quote.time != nil)
    }

    @Test func sourceStatesAreStatedAsFacts() {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday")
        // 읽는 중 · 읽지 못함은 인용을 지어내지 않는다
        #expect(MemorySourceRules.display(item: Memories.item(1, sourceRef: ref), lookup: .loading) == .loading)
        #expect(MemorySourceRules.display(item: Memories.item(1, sourceRef: ref), lookup: .failed) == .failed)
        // 사용자가 직접 쓴 값(출처 없음)은 출처 칸이 없다. 그 밖은 출처가 없다고 말한다
        #expect(MemorySourceRules.display(item: Memories.item(2, origin: .explicit), lookup: .loaded(message: nil, source: nil)) == .hidden)
        #expect(MemorySourceRules.display(item: Memories.item(3, origin: .observed), lookup: .loaded(message: nil, source: nil)) == .unavailable("The source is no longer available"))
        // 원문 글이 지워졌다: 인용이 남아 있어도 다시 보이지 않는다
        let purged = Memories.item(4, origin: .observed, sourceRef: ref, purged: true)
        #expect(MemorySourceRules.display(item: purged, lookup: .loaded(message: nil, source: source())) == .unavailable("Original text deleted"))
        // 원문 행 자체가 사라졌는데 인용이 없다
        let noQuote = Memories.item(5, origin: .inferred, sourceRef: MemorySourceRef(sourceID: ChatContractFixtures.sourceID))
        #expect(MemorySourceRules.display(item: noQuote, lookup: .loaded(message: nil, source: nil)) == .unavailable("The source is no longer available"))
    }

    /// Slack 연결을 끊으면 인용이 사라진다 (D3): 그렇게 지웠다고 말한다 (옛 인용 아님)
    @Test func slackDisconnectIsNamedAndTheOldQuoteStaysGone() {
        let noQuote = Memories.item(1, origin: .explicit, sourceRef: MemorySourceRef(sourceID: ChatContractFixtures.sourceID))
        #expect(MemorySourceRules.display(item: noQuote, lookup: .loaded(message: nil, source: source())) == .unavailable("Removed when Slack was disconnected"))
        let placeholder = Memories.item(2, origin: .explicit, sourceRef: MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: RemovedQuote.slackDisconnected))
        #expect(MemorySourceRules.display(item: placeholder, lookup: .loaded(message: nil, source: source())) == .unavailable("Removed when Slack was disconnected"))
        // Slack이 아닌 원문에 인용이 없으면 그 사실만 말한다
        let notion = source(url: "https://www.notion.so/x")
        #expect(MemorySourceRules.display(item: noQuote, lookup: .loaded(message: nil, source: notion)) == .unavailable("No quote to show"))
    }

    /// 접근을 잃은 원문 · 글이 지워진 원문 · Slack 끊김은 옛 인용을 다시 보이지 않고 사실대로 말한다
    @Test func sourceThatLostAccessOrWasPurgedShowsNoOldQuote() {
        let item = Memories.item(1, origin: .inferred, sourceRef: MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday works"))
        let lost = MemorySourceRules.display(item: item, lookup: .loaded(message: nil, source: source(url: "https://www.notion.so/x", accessLost: true)))
        #expect(lost == .unavailable("Can't open the original"))
        let retention = MemorySourceRules.display(
            item: item, lookup: .loaded(message: nil, source: source(url: "https://www.notion.so/x", purgedAt: "2026-10-10T04:00:00Z", reason: "retention"))
        )
        #expect(retention == .unavailable("Original text deleted"))
        let disconnected = MemorySourceRules.display(
            item: item, lookup: .loaded(message: nil, source: source(purgedAt: "2026-10-10T04:00:00Z", reason: "disconnected"))
        )
        #expect(disconnected == .unavailable("Removed when Slack was disconnected"))
        // 원문 행 자체가 없다 (지워짐)
        #expect(MemorySourceRules.display(item: item, lookup: .loaded(message: nil, source: nil)) == .unavailable("The source is no longer available"))
    }

    /// Confirm: 정상 출처만 보이고, 접근 상실 · 글 지워짐 · Slack 유래 · 읽는 중 · 원문 없음은 감춘다 (서버도 보류한다)
    @Test func confirmIsOfferedOnlyForAHealthyReadableSource() {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday")
        let item = Memories.item(1, origin: .inferred, sourceRef: ref)
        let notion = "https://www.notion.so/x"
        func allows(_ lookup: MemorySourceRules.Lookup?) -> Bool { MemorySourceRules.allowsConfirm(item: item, lookup: lookup) }
        #expect(allows(.loaded(message: nil, source: source(url: notion))))
        #expect(!allows(.loaded(message: nil, source: source(url: notion, accessLost: true))))
        #expect(!allows(.loaded(message: nil, source: source(url: notion, purgedAt: "2026-10-10T04:00:00Z", reason: "retention"))))
        #expect(!allows(.loaded(message: nil, source: source())), "Slack 유래")
        #expect(!allows(.loaded(message: nil, source: source(url: nil, purgedAt: "2026-10-10T04:00:00Z", reason: "disconnected"))))
        #expect(!allows(.loaded(message: nil, source: nil)))
        #expect(!allows(.loading) && !allows(.failed) && !allows(nil), "상태를 모르면 주지 않는다")
        // 대화 발화가 출처인 추정은 서버가 정한다
        #expect(MemorySourceRules.allowsConfirm(item: Memories.item(2, origin: .inferred, sourceRef: MemorySourceRef(messageID: UUID())), lookup: nil))
    }

    @Test func chatUtterancesHaveNoSourceMark() {
        let message = Chats.message(7, in: ChatContractFixtures.conversationID, seq: 1, role: .user, text: "Use the shorter FAQ on both pricing pages.", at: 1)
        let item = Memories.item(1, sourceRef: MemorySourceRef(messageID: message.id))
        guard case .quote(let quote) = MemorySourceRules.display(item: item, lookup: .loaded(message: message, source: nil)) else {
            Issue.record("인용이 아님")
            return
        }
        #expect(quote.service == nil && quote.from == "You" && quote.place == "Chat")
        // 보관 기한으로 글이 비워졌으면 옛 말을 다시 보이지 않는다
        let blank = Chats.message(7, in: ChatContractFixtures.conversationID, seq: 1, role: .user, text: "", at: 1)
        #expect(MemorySourceRules.display(item: item, lookup: .loaded(message: blank, source: nil)) == .unavailable("Original text deleted"))
        #expect(MemorySourceRules.display(item: item, lookup: .loaded(message: nil, source: nil)) == .unavailable("Original text deleted"))
    }
}
