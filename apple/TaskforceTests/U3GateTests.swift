import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// OA U3 10장 · 11.3: 새 셸(캡슐 레일 · bell · Taskforce 대화)은 게이트가 모두 켜졌을 때만 있다. Release와 꺼진 구성은 지금 그대로다
struct U3GateTests {
    private func surfaces(shell: Bool = true, review: Bool = true, summary: Bool = true, chats: Bool = true, projects: Bool = true) -> EdgeSurfaces {
        EdgeSurfaces(shell: shell, review: review, summary: summary, chats: chats, projects: projects, settingsWindow: shell)
    }

    @Test func releaseNeverHasTheTaskforceConversation() {
        #expect(!EdgeSurfaces.release.allowsTaskforceConversation(issueScreens: false))
        #expect(!EdgeSurfaces.release.allowsTaskforceConversation(issueScreens: EdgeSurfaces.release.allowsIssueScreens(flag: true)), "Release는 이슈 화면을 켜지 못한다")
        #expect(!EdgeSurfaces.release.allowsIssueScreens(flag: true))
        #expect(EdgeSurfaces.release.review && EdgeSurfaces.release.summary, "Release에는 S4 · C3가 켜져 있다: 그래도 이슈 화면이 없어 대화가 없다")
        #expect(EdgeSurfaces.release == EdgeSurfaces(shell: true, review: true, summary: true, chats: false, projects: false, settingsWindow: false))
    }

    @Test func anyMissingPartTurnsTheConversationOff() {
        #expect(surfaces().allowsTaskforceConversation(issueScreens: true))
        #expect(!surfaces(review: false).allowsTaskforceConversation(issueScreens: true))
        #expect(!surfaces(summary: false).allowsTaskforceConversation(issueScreens: true))
        #expect(!surfaces().allowsTaskforceConversation(issueScreens: false))
        #expect(!surfaces(shell: false).allowsTaskforceConversation(issueScreens: surfaces(shell: false).allowsIssueScreens(flag: true)))
        #expect(!surfaces(projects: false).allowsTaskforceConversation(issueScreens: surfaces(projects: false).allowsIssueScreens(flag: true)))
        #expect(!surfaces(chats: false).allowsTaskforceConversation(issueScreens: surfaces(chats: false).allowsIssueScreens(flag: true)))
    }

    @Test func theLaunchArgumentsAreTheExistingFiveAndNothingNewTurnsItOn() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeSurfaces.taskforceConversation(store.defaults))
        for key in [EdgeShellFlag.key, S3bFlag.key, EdgeSurfaces.issueScreensKey, S4Flag.key] {
            store.defaults.set(true, forKey: key)
            #expect(!EdgeSurfaces.taskforceConversation(store.defaults), "다섯 중 하나라도 빠지면 꺼진다 (\(key))")
        }
        store.defaults.set(true, forKey: C3Flag.key)
        #expect(EdgeSurfaces.taskforceConversation(store.defaults), "-TF_EDGE_SHELL -TF_S3B -TF_U2 -TF_S4 -TF_C3 (새 플래그 없음, U3-05)")
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(!EdgeSurfaces.taskforceConversation(store.defaults), "Release 표면 인자는 이슈 화면 · 대화를 끈다")
    }

    @Test func theTestHostRunsWithoutTheConversation() {
        #expect(!EdgeSurfaces.taskforceConversationForThisRun)
        #expect(!EdgeSurfaces.taskforceConversation())
    }
}
