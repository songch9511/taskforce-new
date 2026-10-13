import Testing
@testable import TaskforceUI

/// 부품 안의 순수 규칙
struct ComponentRuleTests {
    /// Key: 키 하나에 상자 하나, ↩는 그린 기호
    @Test(arguments: [
        ("⌘K", [KeyHint.Key.text("⌘"), .text("K")]),
        ("⌘↩", [.text("⌘"), .returnKey]),
        ("↩", [.returnKey]),
        ("⌥Space", [.text("⌥"), .text("Space")]),
        ("esc", [.text("esc")]),
        ("⌘⌫", [.text("⌘"), .text("⌫")]),
        ("⇧⌘K", [.text("⇧"), .text("⌘"), .text("K")]),
        ("⌘ R", [.text("⌘"), .text("R")]),
        ("↑↓", [.text("↑"), .text("↓")]),
        ("", []),
    ])
    func keysSplitOnePerBox(_ shortcut: String, _ expected: [KeyHint.Key]) {
        #expect(KeyHint.keys(shortcut) == expected)
    }

    @Test func spokenKeys() {
        #expect(KeyHint.spokenName(KeyHint.keys("⌘K")) == "Command K")
        #expect(KeyHint.spokenName(KeyHint.keys("⌘↩")) == "Command Return")
        #expect(KeyHint.spokenName(KeyHint.keys("⌥Space")) == "Option Space")
    }

    /// M8 Use 칩: 4개까지 + `N more`
    @Test(arguments: [(0, 0, 0), (3, 3, 0), (4, 4, 0), (5, 4, 1), (6, 4, 2)])
    func chipFlowSplit(_ count: Int, _ shown: Int, _ more: Int) {
        let split = ChipFlow.split(count: count, limit: ChipFlow.visibleLimit)
        #expect(split.shown == shown)
        #expect(split.more == more)
    }

    @Test func chipFlowAccessibilityLabel() {
        let titles = ["제품 회의록", "데모 요청", "기획서 v1", "메모", "견적서", "인터뷰"]
        #expect(ChipFlow.accessibilityLabel(titles, limit: 4) == "Sources: 제품 회의록, 데모 요청, 기획서 v1, 메모, 2 more")
        #expect(ChipFlow.accessibilityLabel(["데모 요청"], limit: 4) == "Sources: 데모 요청")
    }

    /// 갈래 VoiceOver: "Taskforce, <상태>[, <부제>]"
    @Test func laneAccessibilityLabel() {
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Draft ready", subtitle: "AI draft · 14:20") == "Taskforce, Draft ready, AI draft · 14:20")
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Writing draft", subtitle: nil) == "Taskforce, Writing draft")
        #expect(LaneCard.accessibilityLabel(heading: "Taskforce", title: "Writing draft", subtitle: "") == "Taskforce, Writing draft")
        // 초안 제목이 제목이면 상태를 먼저 읽는다 (iPhone P2 "Taskforce, Draft ready")
        #expect(
            LaneCard.accessibilityLabel(heading: "Taskforce", title: "데모 예상 질문", subtitle: "AI draft · 14:20", spokenState: "Draft ready")
                == "Taskforce, Draft ready, 데모 예상 질문, AI draft · 14:20"
        )
    }

    /// VoiceOver: "제목, 기한[, Changed]"
    @Test func listRowAccessibilityLabel() {
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: "Fri", changed: true) == "데모 환경 배포, Fri, Changed")
        #expect(MacListRow.accessibilityLabel(title: "데모 환경 배포", accessory: nil, changed: false) == "데모 환경 배포")
    }

    // 0.2.0 디자인 시스템 Atoms

    /// Activity ring: 움직이는 것은 running · stopping뿐이고, 연결 끊김은 멈춘 반 링이다 (waiting과 다르다)
    @Test func activityRingMotion() {
        #expect(ActivityRing.Kind.running.period == 1.1)
        #expect(ActivityRing.Kind.stopping.period == 2.4)
        #expect(ActivityRing.Kind.unreachable.period == nil)
        #expect(ActivityRing.Kind.unreachable.arcLength(reduceMotion: false) == 0.5)
        #expect(ActivityRing.Kind.waiting.arcLength(reduceMotion: false) == nil)
        // 움직임 줄이기: running(반)과 stopping(3/4)이 멈춘 길이로 구분된다
        #expect(ActivityRing.Kind.running.arcLength(reduceMotion: true) != ActivityRing.Kind.stopping.arcLength(reduceMotion: true))
    }

    @Test func activityRingLabels() {
        #expect(ActivityRing.Kind.allCases.map(\.accessibilityLabel) == [
            "Running", "Stop requested", "Connection lost", "Needs your answer", "Waiting", "Done just now",
        ])
    }

    /// Result status: 체크는 검토 통과 · 받음에만. 완료 보고(Unconfirmed)는 체크도 굵기도 없다
    @Test func resultStatusRules() {
        #expect(ResultStatusLabel.State.allCases.filter(\.showsCheck) == [.passedReview, .accepted])
        #expect(ResultStatusLabel.State.unconfirmed.isQuiet)
        #expect(!ResultStatusLabel.State.unconfirmed.showsCheck)
        #expect(ResultStatusLabel.State.allCases.filter(\.isEmphasized) == [.revisionRequested, .accepted])
        #expect(ResultStatusLabel.State.allCases.map(\.label) == [
            "Draft", "Unconfirmed", "In review", "Revision requested", "Passed review", "Accepted",
        ])
    }

    /// 형광펜은 문장 안에 있는 구절만 칠한다
    @Test func markerPhrase() {
        #expect(MarkerText.contains("Could we do Thursday instead?", phrase: "Thursday"))
        #expect(!MarkerText.contains("Could we do Thursday instead?", phrase: "Friday"))
        #expect(!MarkerText.contains("Anything", phrase: nil))
        #expect(!MarkerText.contains("Anything", phrase: ""))
    }
}
