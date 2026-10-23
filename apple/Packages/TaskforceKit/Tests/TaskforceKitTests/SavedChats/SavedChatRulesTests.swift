import Foundation
import Testing
@testable import TaskforceKit

/// 저장된 대화의 줄 모델 · 규칙 (D3v-m, DZ `oa-desktop-chat-view-dz` 시트 1 · 5): 제목 없음 · 기기 이름 생략 · 접기 · 말 순서 · 승인된 문구
struct SavedChatRulesTests {
    typealias S = SavedChatSamples

    // MARK: 제목

    @Test func aNullEmptyOrBlankTitleIsUntitledAndAGoodTitleIsKept() {
        let rows = SavedChatRules.rows(
            [S.record(1, title: nil), S.record(2, title: ""), S.record(3, title: "  \n "), S.record(4, title: "Pricing copy draft")], deviceNames: [:], thisMac: nil
        )
        #expect(rows.map(\.isUntitled) == [true, true, true, false])
        #expect(rows.map(\.displayTitle) == ["Untitled", "Untitled", "Untitled", "Pricing copy draft"])
    }

    // MARK: 기기 이름 (이 Mac이거나 이름이 없으면 생략)

    @Test func theDeviceNameIsOmittedForThisMacAndForMissingOrBlankNames() {
        let names = [S.macThis: "This one", S.macOther: "Daniel's MacBook Pro"]
        #expect(SavedChatRules.deviceName(bridgeID: S.macThis, names: names, thisMac: S.macThis) == nil, "이 Mac이 보낸 것은 기기 이름을 반복하지 않는다")
        #expect(SavedChatRules.deviceName(bridgeID: S.macOther, names: names, thisMac: S.macThis) == "Daniel's MacBook Pro")
        #expect(SavedChatRules.deviceName(bridgeID: UUID(), names: names, thisMac: S.macThis) == nil, "이름이 null인 Mac(폐기 · 이름 없음)은 시각만")
        #expect(SavedChatRules.deviceName(bridgeID: S.macOther, names: [S.macOther: "   "], thisMac: nil) == nil, "빈 이름은 이름이 아니다")
    }

    @Test func whenThisMacIsUnknownTheNamedMacsStillShowTheirName() {
        #expect(SavedChatRules.deviceName(bridgeID: S.macOther, names: [S.macOther: "Studio"], thisMac: nil) == "Studio")
    }

    @Test func rowsKeepTheServersNewestFirstOrderAndCarryTheDeviceRule() {
        let records = [S.record(1, bridge: S.macOther, minutesAgo: 1), S.record(2, bridge: S.macThis, minutesAgo: 5), S.record(3, bridge: S.macOther, minutesAgo: 9)]
        let rows = SavedChatRules.rows(records, deviceNames: [S.macThis: "Mine", S.macOther: "Daniel's MacBook Air"], thisMac: S.macThis)
        #expect(rows.map(\.id) == [S.id(1), S.id(2), S.id(3)])
        #expect(rows.map(\.deviceName) == ["Daniel's MacBook Air", nil, "Daniel's MacBook Air"])
    }

    // MARK: 접기: 처음 셋 + Show all

    @Test func onlyTheFirstThreeShowUntilShowAllAndTheFoldLinkNeedsMoreThanThree() {
        let rows = (1...7).map { S.row($0) }
        let folded = SavedChatRules.fold(rows, expanded: false)
        #expect(folded.visible.map(\.id) == (1...3).map { S.id($0) } && folded.hiddenCount == 4 && folded.togglesFold && !folded.expanded)
        let open = SavedChatRules.fold(rows, expanded: true)
        #expect(open.visible.count == 7 && open.hiddenCount == 0 && open.togglesFold && open.expanded)
        let three = SavedChatRules.fold(Array(rows.prefix(3)), expanded: false)
        #expect(three.visible.count == 3 && !three.togglesFold && !three.expanded, "셋 이하면 링크가 없다")
        #expect(SavedChatRules.foldLimit == 3 && SavedChatRules.pageSize == 20)
    }

    // MARK: 말 순서 · 모르는 역할

    @Test func messagesAreOrderedBySaidAtThenSeqAndUnknownRolesAreDropped() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            S.messageRecord(1, role: "assistant", body: "later", at: t0.addingTimeInterval(60), seq: 3),
            S.messageRecord(2, role: "user", body: "first", at: t0, seq: 1),
            S.messageRecord(3, role: "assistant", body: "same time, higher seq", at: t0.addingTimeInterval(60), seq: 4),
            S.messageRecord(4, role: "system", body: "unknown role", at: t0, seq: 2),
        ]
        let ordered = SavedChatMessages.ordered(records)
        #expect(ordered.map(\.body) == ["first", "later", "same time, higher seq"])
        #expect(ordered.map(\.role) == [.user, .assistant, .assistant])
    }

    // MARK: 승인된 문구 (계약 27장 V1–V13 · Undo 없음 · 저장 표시 없음)

    @Test func theNewCopyIsExactlyTheApprovedStringsAndNothingElse() {
        #expect(SavedChatsCopy.title == "Saved chats")
        #expect(SavedChatsCopy.untitled == "Untitled")
        #expect(SavedChatsCopy.deleteChatTitle == "Delete this chat?")
        #expect(SavedChatsCopy.deleteChatDetail == "Deletes the saved copy from all your devices")
        #expect(SavedChatsCopy.couldNotDelete == "Couldn't delete")
        #expect(SavedChatsCopy.couldNotLoad == "Couldn't load saved chats")
        #expect(SavedChatsCopy.deleteAllRow == "Delete all saved chats")
        #expect(SavedChatsCopy.deleteAllButton == "Delete…")
        #expect(SavedChatsCopy.deleteAllTitle == "Delete all saved chats?")
        #expect(SavedChatsCopy.deleteAllDetail == "Deletes the saved copies from all your devices")
        #expect(SavedChatsCopy.deleteAllConfirm == "Delete all")
        #expect(SavedChatsCopy.approved == [
            "Saved chats", "Untitled", "Delete this chat?", "Deletes the saved copy from all your devices", "Couldn't delete", "Couldn't load saved chats",
            "Delete all saved chats", "Delete…", "Delete all saved chats?", "Deletes the saved copies from all your devices", "Delete all",
        ], "V1–V6 · V8–V12 (V7은 iPhone 빈 화면, V13 \"Couldn't delete some chats\"는 서버가 원자적이라 쓰지 않는다). 이 목록에 다른 글자를 더하면 승인 없는 문구다")
        #expect(!SavedChatsCopy.approved.contains { $0.lowercased().contains("some chats") }, "일부만 지워지는 상태는 없다")
    }

    @Test func noApprovedStringMentionsUndoOrSaving() {
        for text in SavedChatsCopy.approved + [SavedChatsCopy.delete] {
            let lowered = text.lowercased()
            #expect(!lowered.contains("undo") && !lowered.contains("saving") && !lowered.contains("saved to your account"), "\(text)")
        }
    }

    // MARK: 줄 글 (macOS)

    #if os(macOS)
    @Test func theSecondLineIsTimeThenDeviceAndOmitsTheDeviceWhenThereIsNone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let zone = TimeZone(identifier: "UTC")!
        let named = S.row(1, device: "Daniel's MacBook Air", minutesAgo: 12)
        let unnamed = S.row(2, device: nil, minutesAgo: 120)
        #expect(named.metaText(now: now, timeZone: zone) == "12 min ago · Daniel's MacBook Air")
        #expect(unnamed.metaText(now: now, timeZone: zone) == "2 hr ago", "기기 이름이 없으면 시각만")
        #expect(named.accessibilityName(now: now, timeZone: zone) == "Chat — 12 min ago · Daniel's MacBook Air")
        #expect(S.row(3, title: nil).accessibilityName(now: now, timeZone: zone).hasPrefix("Untitled — "))
    }

    @Test func theHeaderDateIsTheExactDayOfTheLastMessageInTheDeviceTimeZone() {
        let zone = TimeZone(identifier: "UTC")!
        let row = SavedChatRow(id: S.id(1), title: "x", lastMessageAt: Date(timeIntervalSince1970: 1_792_000_000), deviceName: nil)
        let today = LocalDate(date: Date(timeIntervalSince1970: 1_792_000_000), timeZone: zone)
        #expect(row.headerLine(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: zone) == DueText.date(today, today: today))
        let named = SavedChatRow(id: S.id(1), title: "x", lastMessageAt: Date(timeIntervalSince1970: 1_792_000_000), deviceName: "Studio")
        #expect(named.headerLine(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: zone) == "Studio · \(DueText.date(today, today: today))")
    }
    #endif
}
