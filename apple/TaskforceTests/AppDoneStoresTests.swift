import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 끝난 링이 앱을 다시 켠 뒤에도 남으려면 **실제 앱이 영속 저장소를 넘겨야** 한다 (OA PR-D2, 계약 23장).
/// 시험 호스트 · 견본은 메모리 저장소를 쓰는데(실사용 설정을 건드리지 않으려고), 그래서 앱이 메모리 저장소로 이어져도 다른 시험은 모두 통과한다 — 이 파일이 실제 생성 경로(`AppRuntime.makeChatRuntime`)와 셸 컨트롤러 연결을 직접 본다.
@MainActor
struct AppDoneStoresTests {
    // MARK: 어떤 저장소를 쓰나

    @Test func theShippedAppKeepsDoneMarksInUserDefaults() {
        let stores = AppRuntime.doneStores(sample: false, isTestHost: false)
        #expect(stores.rail is UserDefaultsRailDoneStore)
        #expect(stores.claudeApp is UserDefaultsClaudeAppDoneStore)
    }

    @Test func aSampleRunAndATestHostKeepThemInMemoryOnly() {
        for (sample, testHost) in [(true, false), (false, true), (true, true)] {
            let stores = AppRuntime.doneStores(sample: sample, isTestHost: testHost)
            #expect(stores.rail is InMemoryRailDoneStore && stores.claudeApp is InMemoryClaudeAppDoneStore, "sample \(sample) · test host \(testHost)")
        }
    }

    /// 기본 값은 이 프로세스가 시험 호스트인지 본다: 시험은 실사용 설정을 건드리지 않는다
    @Test func theDefaultReadsWhetherThisProcessIsATestHost() {
        let stores = AppRuntime.doneStores(sample: false)
        #expect(stores.rail is InMemoryRailDoneStore && stores.claudeApp is InMemoryClaudeAppDoneStore)
    }

    /// 앱을 끄고 켜면: 한 번 켠 때 쓴 표시를 다음에 켠 때 같은 설정 도메인에서 읽는다 (같은 열쇠 · 같은 저장소)
    @Test func marksOneLaunchWroteAreReadByTheNextLaunch() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        let session = UUID(), issue = UUID()
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AppRuntime.doneStores(sample: false, isTestHost: false, defaults: store.defaults)
        first.rail.update { $0.sessions[session] = seen; $0.issues[issue] = seen }
        first.claudeApp.save(["8a5f0000-0000-4000-8000-000000000001": ClaudeAppDoneMark(pid: 4242, at: seen)])
        let second = AppRuntime.doneStores(sample: false, isTestHost: false, defaults: store.defaults)
        #expect(second.rail.load() == RailDoneMarks(sessions: [session: seen], issues: [issue: seen]))
        #expect(second.claudeApp.load()["8a5f0000-0000-4000-8000-000000000001"] == ClaudeAppDoneMark(pid: 4242, at: seen))
        // 메모리 저장소는 다음 켬에 남지 않는다
        let memory = AppRuntime.doneStores(sample: true, isTestHost: false, defaults: store.defaults)
        #expect(memory.rail.load() == RailDoneMarks() && memory.claudeApp.load().isEmpty)
    }

    // MARK: 실제 생성 경로

    @Test func theRealCreationPathHandsThePersistentStoresToTheRuntime() throws {
        let account = try AppChatAccount.make()
        let runtime = AppRuntime.makeChatRuntime(
            session: account.session, services: S3bGateTests.services().services, sample: false, s3b: false, connectivity: nil, isTestHost: false
        )
        #expect(runtime.doneStores.rail is UserDefaultsRailDoneStore)
        #expect(runtime.doneStores.claudeApp is UserDefaultsClaudeAppDoneStore)
    }

    @Test func theRealCreationPathInATestHostAndTheSampleCreationPathStayInMemory() throws {
        let account = try AppChatAccount.make()
        let services = S3bGateTests.services().services
        let hosted = AppRuntime.makeChatRuntime(session: account.session, services: services, sample: false, s3b: false, connectivity: nil)
        #expect(hosted.doneStores.rail is InMemoryRailDoneStore && hosted.doneStores.claudeApp is InMemoryClaudeAppDoneStore)
        let sample = AppRuntime.makeChatRuntime(session: account.session, services: services, sample: true, s3b: false, connectivity: nil, isTestHost: false)
        #expect(sample.doneStores.rail is InMemoryRailDoneStore && sample.doneStores.claudeApp is InMemoryClaudeAppDoneStore)
    }

    /// 만든 런타임을 직접 만든 시험들도 메모리에서 시작한다 (실사용 설정에 쓰지 않는다)
    @Test func aRuntimeBuiltWithoutStoresStartsInMemory() throws {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), scope: account.scope)
        #expect(runtime.doneStores.rail is InMemoryRailDoneStore && runtime.doneStores.claudeApp is InMemoryClaudeAppDoneStore)
    }

    // MARK: 셸이 그 저장소를 쓴다

    /// 컨트롤러는 런타임이 가진 저장소를 셸에 그대로 넘긴다 (자기 전역 판단으로 다른 저장소를 만들지 않는다)
    @Test func theShellControllerUsesTheStoresTheRuntimeCarries() throws {
        let account = try AppChatAccount.make()
        let stores = RailDoneStores.inMemory()
        let runtime = ChatRuntime(
            gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true, doneStores: stores
        )
        let controller = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false)
        #expect(controller.shell.railDone === stores.rail)
    }

    /// 새 Issues 화면이 꺼진 구성은 레일 끝남 저장소를 쓰지 않는다 (옛 3초 모드)
    @Test func aShellWithoutIssueScreensHasNoRailDoneStore() throws {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), scope: account.scope, issueScreens: false, doneStores: .inMemory())
        let controller = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false)
        #expect(controller.shell.railDone == nil)
    }
}
