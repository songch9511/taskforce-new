#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 보기 V1 (DZ oa-session-view-dz v2): 일한 시간의 모양과 단계 줄의 글. 값은 화면이 그대로 쓴다 (문구는 승인된 말 그대로).
struct SessionTimeAndStepTextTests {
    // MARK: 일한 시간 (E5 · E6)

    @Test func aFinishedTurnSaysSecondsMinutesAndHoursInTheApprovedShape() {
        #expect(SessionTime.worked(42) == "42s")
        #expect(SessionTime.worked(252) == "4m 12s")
        #expect(SessionTime.worked(60) == "1m 0s")
        #expect(SessionTime.worked(4080) == "1h 8m")
        #expect(SessionTime.worked(3600) == "1h 0m")
        #expect(SessionTime.worked(3659) == "1h 0m", "시간이 넘으면 초는 쓰지 않는다")
    }

    @Test func secondsAreFlooredAndNeverNegative() {
        #expect(SessionTime.worked(59.99) == "59s")
        #expect(SessionTime.worked(0.4) == "0s")
        #expect(SessionTime.worked(-5) == "0s")
        #expect(SessionTime.worked(.nan) == "0s")
        #expect(SessionTime.worked(.infinity) == "0s", "무한대는 지어낸 값이다")
    }

    @Test func theLiveClockUsesMinutesAndSecondsAndHoursOnlyPastAnHour() {
        #expect(SessionTime.clock(7) == "0:07")
        #expect(SessionTime.clock(108) == "1:48")
        #expect(SessionTime.clock(3599) == "59:59")
        #expect(SessionTime.clock(3600) == "1:00:00")
        #expect(SessionTime.clock(3750) == "1:02:30")
        #expect(SessionTime.clock(-3) == "0:00")
        #expect(SessionTime.clock(.nan) == "0:00")
    }

    @Test func theLinesUseTheApprovedWords() {
        #expect(SessionTime.workedLine(252) == "Worked for 4m 12s")
        #expect(SessionTime.workingLine(108) == "Working · 1:48")
        #expect(SessionViewCopy.copy == "Copy" && SessionViewCopy.copied == "Copied")
        #expect(SessionViewCopy.input == "Input" && SessionViewCopy.result == "Result" && SessionViewCopy.failed == "Failed")
        #expect(SessionViewCopy.steps(9) == "9 steps")
    }

    @Test func aTurnUnderTenSecondsShowsNoTimeLine() {
        #expect(SessionTime.workedLine(9.9) == nil)
        #expect(SessionTime.workedLine(10) == "Worked for 10s")
        #expect(SessionTime.workedLine(0) == nil)
        #expect(SessionTime.workedLine(nil) == nil, "시각을 모르면 지어내지 않는다")
        #expect(SessionTime.workedLine(-4) == nil)
    }

    @Test func theElapsedTimeIsTheWallClockDifferenceOrNilWhenEitherTimeIsUnknown() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(SessionTime.elapsed(from: start, to: start.addingTimeInterval(252)) == 252)
        #expect(SessionTime.elapsed(from: nil, to: start) == nil)
        #expect(SessionTime.elapsed(from: start, to: nil) == nil)
        #expect(SessionTime.elapsed(from: start, to: start.addingTimeInterval(-5)) == nil, "끝이 시작보다 앞서면(시계가 어긋남) 값이 없다")
    }

    // MARK: 단계 줄 (E2 · E3)

    @Test func aStepLineIsTheToolNameThenTheTarget() {
        #expect(SessionStepText.line(name: "Read", target: "pricing.mdx") == "Read · pricing.mdx")
        #expect(SessionStepText.line(name: "Grep", target: nil) == "Grep")
        #expect(SessionStepText.line(name: "Bash", target: "") == "Bash")
        #expect(SessionStepText.line(name: "Bash", target: "Run the copy lint") == "Bash · Run the copy lint")
    }

    @Test func aShortFileNameIsKeptAsIs() {
        #expect(SessionStepText.shortFileName("pricing.mdx") == "pricing.mdx")
        #expect(SessionStepText.shortFileName(String(repeating: "a", count: 24) + ".swift") == String(repeating: "a", count: 24) + ".swift", "30자는 그대로 둔다")
    }

    @Test func theLimitIsThirtyAndOneCharacterOverIsShortenedToThirty() {
        #expect(SessionStepText.fileNameLimit == 30, "승인된 값 (DZ v2 E2)")
        let thirtyOne = String(repeating: "a", count: 25) + ".swift"
        #expect(thirtyOne.count == 31)
        let short = SessionStepText.shortFileName(thirtyOne)
        #expect(short.count == 30 && short.hasSuffix(".swift") && short.contains("…"), "31자는 30자로 줄인다")
        let thirtyFive = String(repeating: "b", count: 29) + ".swift"
        #expect(SessionStepText.shortFileName(thirtyFive).count == 30, "상한 넘는 이름은 모두 30자")
    }

    @Test func aLongFileNameLosesItsMiddleAndKeepsItsExtension() {
        let name = "LauncherWindowControllerWakeFromSleep.swift"
        let short = SessionStepText.shortFileName(name)
        #expect(short.count <= SessionStepText.fileNameLimit)
        #expect(short.hasSuffix(".swift"))
        #expect(short.hasPrefix("LauncherWindow"))
        #expect(short.contains("…"))
        #expect(short != name)
    }

    @Test func aLongNameWithoutAnExtensionStillFitsAndALongExtensionIsNotKept() {
        let plain = String(repeating: "x", count: 80)
        let shortPlain = SessionStepText.shortFileName(plain)
        #expect(shortPlain.count <= SessionStepText.fileNameLimit && shortPlain.contains("…"))
        let weird = "a." + String(repeating: "e", count: 60)
        let shortWeird = SessionStepText.shortFileName(weird)
        #expect(shortWeird.count <= SessionStepText.fileNameLimit, "긴 확장자도 상한을 넘지 않는다")
    }

    @Test func aFileNameOfOnlyAnExtensionOrNothingIsHandled() {
        #expect(SessionStepText.shortFileName("") == "")
        #expect(SessionStepText.shortFileName(".gitignore") == ".gitignore")
        #expect(SessionStepText.shortFileName("." + String(repeating: "z", count: 60)).count <= SessionStepText.fileNameLimit)
    }

    @Test func theFileNameIsTheLastPathComponentAndNeverAPath() {
        #expect(SessionStepText.fileName(fromPath: "/Users/tester/proj/content/pricing.mdx") == "pricing.mdx")
        #expect(SessionStepText.fileName(fromPath: "pricing.mdx") == "pricing.mdx")
        #expect(SessionStepText.fileName(fromPath: "/Users/tester/proj/") == nil, "끝이 폴더면 파일 이름이 없다")
        #expect(SessionStepText.fileName(fromPath: "/") == nil)
        #expect(SessionStepText.fileName(fromPath: "") == nil)
        #expect(SessionStepText.fileName(fromPath: "/a/b/\u{202E}evil.mdx") == "evil.mdx", "방향 바꿈 글자는 지운다")
        #expect(SessionStepText.fileName(fromPath: "/a/b/line\nbreak.txt") == "line break.txt", "줄바꿈은 한 칸으로 접는다")
        #expect(SessionStepText.fileName(fromPath: "/a/\(String(repeating: "n", count: 400)).txt") != nil)
    }

    @Test func aGroupLabelListsEachToolNameOnceInTheOrderItWasFirstUsed() {
        #expect(SessionStepText.groupLabel(names: ["Read", "Grep", "Read", "Glob", "Task", "Grep"]) == "Read · Grep · Glob · Task")
        #expect(SessionStepText.groupLabel(names: ["Edit"]) == "Edit")
        #expect(SessionStepText.groupLabel(names: []) == "")
    }
}
#endif
