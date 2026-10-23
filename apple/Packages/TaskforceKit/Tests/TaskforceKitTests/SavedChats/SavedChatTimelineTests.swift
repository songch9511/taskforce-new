#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 저장된 대화를 세션 보기의 줄로 바꾸는 규칙 (D3v-m, DZ 시트 2 · 5): 도구는 이름뿐인 단계 줄, 답은 안전한 서식(링크 없음), "Worked for" · 시계 없음, 날짜가 바뀌면 날짜 줄
struct SavedChatTimelineTests {
    typealias S = SavedChatSamples

    private let zone = TimeZone(identifier: "UTC")!
    /// 2026-10-23 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_792_756_800)

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        now.addingTimeInterval(Double(dayOffset) * 86_400 + Double(hour - 12) * 3600 + Double(minute) * 60)
    }

    private func timeline(_ messages: [SavedChatMessage]) -> SavedChatTimeline {
        SavedChatTimeline.make(messages, now: now, timeZone: zone)
    }

    private func entryIDs(_ timeline: SavedChatTimeline) -> [String] {
        timeline.entries.map { entry in
            switch entry {
            case .item(let id): "item:\(id)"
            case .steps(let run): "steps:\(run.stepIDs.count):\(run.isGroup ? "group" : "rows")"
            case .footer: "footer"
            case .clock: "clock"
            }
        }
    }

    // MARK: 도구: 이름뿐인 단계 줄

    @Test func toolNamesBecomeNameOnlyStepRowsBeforeTheAnswerTheyBelongTo() {
        let user = S.message(1, role: .user, body: "migration 정리해줘", at: at(0, 9))
        let reply = S.message(2, role: .assistant, body: "Done.", tools: ["Read", "Grep"], at: at(0, 9, 5))
        let t = timeline([user, reply])
        #expect(entryIDs(t) == ["item:\(user.id.uuidString)", "steps:2:rows", "item:\(reply.id.uuidString)"])
        guard t.entries.count > 1, case .steps(let run) = t.entries[1] else { Issue.record("단계 줄이 아니다"); return }
        for id in run.stepIDs {
            let info = t.steps[id]
            #expect(info?.target == nil && info?.failed == false && info?.canExpand == false, "이름만이다: 입력 · 결과 · 파일 이름 · 펼침이 없다")
        }
        #expect(run.stepIDs.compactMap { t.steps[$0]?.line } == ["Read", "Grep"])
    }

    @Test func fourOrMoreToolsFoldIntoOneLineOfNamesWithoutACount() {
        let reply = S.message(2, role: .assistant, body: "x", tools: ["Read", "Grep", "Glob", "Edit", "Read", "Edit"], at: at(0, 9))
        let t = timeline([S.message(1, role: .user, at: at(0, 8)), reply])
        guard t.entries.count > 1, case .steps(let run) = t.entries[1] else { Issue.record("단계 줄이 아니다"); return }
        #expect(run.isGroup && run.stepIDs.count == 6)
        #expect(run.label == "Read · Grep · Glob · Edit", "처음 쓴 순서의 고유 이름: \(run.label)")
    }

    @Test func fortyToolNamesAreAllRows() {
        let names = (0..<40).map { $0.isMultiple(of: 2) ? "Read" : "Grep" }
        let t = timeline([S.message(1, role: .user, at: at(0, 8)), S.message(2, role: .assistant, body: "x", tools: names, at: at(0, 9))])
        guard t.entries.count > 1, case .steps(let run) = t.entries[1] else { Issue.record("단계 줄이 아니다"); return }
        #expect(run.stepIDs.count == 40 && Set(run.stepIDs).count == 40, "단계 id는 겹치지 않는다")
    }

    @Test func eachAnswerOwnsTheToolsUsedBeforeItAndAnAnswerWithoutToolsHasNoSteps() {
        let a = S.message(2, role: .assistant, body: "first", tools: ["Read"], at: at(0, 9))
        let b = S.message(3, role: .assistant, body: "second", at: at(0, 10))
        let t = timeline([S.message(1, role: .user, at: at(0, 8)), a, b])
        #expect(entryIDs(t).count == 4 && entryIDs(t)[1] == "steps:1:rows" && entryIDs(t)[3] == "item:\(b.id.uuidString)")
    }

    // MARK: "Worked for" · 시계 없음 (저장된 것은 기록이지 일하는 세션이 아니다)

    @Test func thereIsNoWorkedForLineNoFooterAndNoClockHoweverLongTheGaps() {
        let t = timeline([
            S.message(1, role: .user, at: at(0, 8)), S.message(2, role: .assistant, body: "done", tools: ["Read"], at: at(0, 9, 30)),
            S.message(3, role: .user, at: at(0, 11)), S.message(4, role: .assistant, body: "again", at: at(0, 11, 45)),
        ])
        #expect(!t.entries.contains { if case .footer = $0 { true } else { false } } && !t.entries.contains { if case .clock = $0 { true } else { false } })
    }

    // MARK: 보낸 말

    @Test func aSentMessageIsPlainTextWithTheReceivedViaTaskforceLine() {
        let user = S.message(1, role: .user, body: "가격 페이지 **굵게** 쓰지 마", at: at(0, 9))
        let t = timeline([user])
        guard case .sent(let text)? = t.items[user.id.uuidString] else { Issue.record("보낸 말이 아니다"); return }
        #expect(text == "가격 페이지 **굵게** 쓰지 마", "보낸 말은 쓴 그대로 (서식 없음)")
        #expect(t.items[user.id.uuidString]?.rendersMarkdown == false)
        #expect(SavedChatItem.deliveryLine == MessageDeliveryLine(strong: nil, text: "Received · via Taskforce"))
    }

    // MARK: 답: 안전한 서식 · 원문 그대로 복사

    @Test func aReplyKeepsItsRawMarkdownAndIsMarkedForTheSafeRenderer() {
        let body = "**Lifetime** card: `price` only. [link](https://example.com/phish)"
        let reply = S.message(2, role: .assistant, body: body, at: at(0, 9, 41))
        let t = timeline([S.message(1, role: .user, at: at(0, 9)), reply])
        guard case .reply(let markdown, let time)? = t.items[reply.id.uuidString] else { Issue.record("답이 아니다"); return }
        #expect(markdown == body, "원문 그대로를 안전한 서식 그림이 읽는다 (링크는 그림이 글자로 둔다)")
        #expect(time == "09:41", "24시간 \(time)")
        #expect(t.items[reply.id.uuidString]?.rendersMarkdown == true, "답은 세션 보기와 같은 안전한 서식으로 그린다")
    }

    @Test func aTruncatedReplyEndsWithAnEllipsis() {
        let reply = SavedChatMessage(id: S.id(7), role: .assistant, body: "cut off here", truncated: true, toolNames: [], saidAt: at(0, 9), seq: 7)
        let t = timeline([S.message(1, role: .user, at: at(0, 8)), reply])
        guard case .reply(let markdown, _)? = t.items[S.id(7).uuidString] else { Issue.record("답이 아니다"); return }
        #expect(markdown == "cut off here…")
    }

    // MARK: 날짜 줄

    @Test func aDayLineStandsAboveTheFirstMessageAndWhereTheDayChanges() {
        let first = S.message(1, role: .user, at: at(-2, 20))
        let sameDay = S.message(2, role: .assistant, body: "a", at: at(-2, 21))
        let nextDay = S.message(3, role: .user, at: at(-1, 9))
        let today = S.message(4, role: .user, at: at(0, 8))
        let t = timeline([first, sameDay, nextDay, today])
        func label(_ message: SavedChatMessage) -> String? { t.dayLabel(of: message.id.uuidString) }
        #expect(label(first) == "Oct 21", "첫 말 위에 그날 \(String(describing: label(first)))")
        #expect(label(sameDay) == nil, "같은 날이면 줄이 없다")
        #expect(label(nextDay) == "Yesterday")
        #expect(label(today) == "Today")
    }

    @Test func aReplyOnANewDayCarriesTheDayLineToo() {
        let t = timeline([S.message(1, role: .user, at: at(-1, 23, 50)), S.message(2, role: .assistant, body: "late", at: at(0, 0, 10))])
        #expect(t.dayLabel(of: S.message(2).id.uuidString) == "Today", "자정을 넘긴 답 앞에도 날짜 줄")
    }

    @Test func noMessagesNoEntries() {
        #expect(timeline([]).entries.isEmpty)
    }
}
#endif
