import SwiftUI
import TaskforceKit
import TaskforceUI

@main
struct TaskforceApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        // 에이전트 앱: Dock · 창 없이 메뉴 막대 아이콘 + ⌥Space 런처 (MacAppDelegate)
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
        Settings {
            switch AppRuntime.startup {
            case .ready(let session, let services):
                // `TF_EDGE_SHELL`이 꺼져 있으면(기본) 기존 `MacSettingsView`, 켜져 있으면 0.2.0 탭 창 (`MacSettingsRoot`)
                MacSettingsRoot()
                    .environment(session)
                    .environment(\.services, services)
                    .environment(AppRuntime.account(services: services))
                    .environment(AppRuntime.runs(services: services))
            case .misconfigured(let message):
                ConfigErrorView(message: message)
                    .frame(width: 420, height: 240)
            }
        }
    }
}

/// 앱 전체에서 하나만 두는 것들: 설정 · 로그인 상태 · 서비스. Mac은 SwiftUI 장면 밖(런처 패널)에서도 같은 것을 쓴다.
@MainActor
enum AppRuntime {
    static let startup = Startup.make()

    /// Mac 런처 목록의 계정별 저장본. 로그아웃과 계정 삭제 때 지운다.
    static let savedNow: SavedNowStore? = (try? AppConfig.fromMainBundle())
        .flatMap { SavedNowStore.defaultRoot(appGroupID: $0.appGroupID) }
        .map(SavedNowStore.init(root:))

    private static var accountStore: AccountStore?

    /// 연결 · 동의 · 프로필 상태 (런처와 Mac 설정 창이 같은 것을 본다)
    static func account(services: AppServices) -> AccountStore {
        if let accountStore { return accountStore }
        let session: SessionStore? = if case .ready(let session, _) = startup { session } else { nil }
        let store = AccountStore(services: services, session: session)
        accountStore = store
        return store
    }

    private static var chatRuntimeStore: ChatRuntime?

    /// 대화 · 기억 (`TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만, `MacAppDelegate`가 `session.start()` 전에 만든다).
    /// 앱 시작 때 세션 계정 · epoch에 한 번 붙어, 패널 · 설정 창이 떠 있는지와 상관없이 계정이 떠나면 초안 · 캐시 · 대기 전송을 비운다.
    /// 견본(`-TFSampleData`)은 가짜 서버(`SampleChatGateway`)와 견본 계정으로 서버를 부르지 않는다.
    /// 범위 멤버십(S3b)은 `-TF_S3B YES`일 때만 연결된다 (`S3bFlag`, 기본 꺼짐)
    static func chatRuntime(session: SessionStore, services: AppServices) -> ChatRuntime {
        if let chatRuntimeStore { return chatRuntimeStore }
        #if DEBUG
        let sample = SampleData.isEnabled
        #else
        let sample = false
        #endif
        let runtime = makeChatRuntime(session: session, services: services, sample: sample, s3b: S3bFlag.isEnabled())
        SettingsWindowModel.shared.bind(to: runtime)
        chatRuntimeStore = runtime
        return runtime
    }

    /// 실제 생성 경로의 본체 (`chatRuntime`이 부르고, 테스트가 같은 함수를 기본 / off / on으로 부른다).
    /// `s3b`가 꺼져 있으면 범위 멤버십 게이트웨이 · 저장소를 **만들지 않는다**: 멤버십 읽기 · 쓰기 · ProjectLink 연결이 없고 All work는 S3 그대로다.
    /// `connectivity`: 연결 경로 (테스트는 nil로 감시를 만들지 않는다)
    static func makeChatRuntime(
        session: SessionStore, services: AppServices, sample: Bool, s3b: Bool, connectivity: AsyncStream<Bool>? = Connectivity.updates()
    ) -> ChatRuntime {
        #if DEBUG
        if sample {
            let gateway = SampleChatGateway(scenario: SampleData.chatScenario)
            let contexts = s3b ? SampleContextGateway(scenario: SampleData.contextScenario) : nil
            let runtime = ChatRuntime(gateway: gateway, contextGateway: contexts)
            runtime.sampleGateway = gateway
            runtime.sampleContextGateway = contexts
            runtime.scope.bind(to: session, account: { SampleData.userID })
            return runtime
        }
        #endif
        let runtime = ChatRuntime(gateway: LiveChatGateway(services: services), contextGateway: s3b ? LiveContextGateway(services: services) : nil)
        runtime.scope.bind(to: session)
        if let connectivity { runtime.followConnectivity(connectivity) }
        return runtime
    }

    /// 이미 만들어졌으면 그것 (설정 창이 쓴다). 플래그가 꺼져 있으면 nil
    static var existingChatRuntime: ChatRuntime? { chatRuntimeStore }

    /// Review 페이지(S4)의 답을 보내는 곳 (`MacAppDelegate`가 Edge 셸을 만들 때 부른다). `-TF_S4 YES`일 때만 만든다 (`S4Flag`, 기본 꺼짐)
    static func reviewDesk(now: NowStore?, scope: AccountScope?) -> ReviewDesk? {
        makeReviewDesk(now: now, scope: scope, s4: S4Flag.isEnabled())
    }

    /// 실제 생성 경로의 본체 (`reviewDesk`가 부르고, 테스트가 같은 함수를 기본 / off / on으로 부른다).
    /// `s4`가 꺼져 있으면 `ReviewDesk`를 **만들지 않는다**: 셸에 Review 페이지 · 단축키 연결이 없고 지금(S3b/B3/Edge) 그대로다.
    /// 목록(`NowStore`)이나 계정 경계(`AccountScope`)가 없어도 만들지 않는다
    static func makeReviewDesk(now: NowStore?, scope: AccountScope?, s4: Bool) -> ReviewDesk? {
        guard s4, let now, let scope else { return nil }
        return ReviewDesk(now: now, scope: scope)
    }

    /// 복귀 요약(C3)을 읽고 Clear하는 곳 (`MacAppDelegate`가 Edge 셸을 만들 때 부른다). `-TF_C3 YES`일 때만 만든다 (`C3Flag`, 기본 꺼짐).
    /// 견본(`-TFSampleData`)은 서버를 부르지 않고 가짜 서버(`SampleReturnSummaryGateway`)가 답한다
    static func returnSummary(services: AppServices?, scope: AccountScope?) -> ReturnSummaryStore? {
        makeReturnSummaryStore(
            makeGateway: {
                #if DEBUG
                if SampleData.isEnabled {
                    let sample = SampleReturnSummaryGateway(scenario: SampleData.summaryScenario, clear: SampleData.summaryClearBehavior)
                    sampleSummaryGateway = sample
                    return sample
                }
                #endif
                return services.map { LiveReturnSummaryGateway(services: $0) }
            },
            scope: scope, c3: C3Flag.isEnabled()
        )
    }

    #if DEBUG
    /// 견본이면 가짜 서버 (스냅샷 · 합성 조작이 시나리오를 바꿔 가며 담는다)
    static var sampleSummaryGateway: SampleReturnSummaryGateway?
    #endif

    /// 실제 생성 경로의 본체 (`returnSummary`가 부르고, 테스트가 같은 함수를 기본 / off / on으로 부른다).
    /// `c3`가 꺼져 있으면 게이트웨이도 `ReturnSummaryStore`도 **만들지 않는다**: 셸에 카드 자리 · 읽기가 없고 지금(S4/S3b/B3/Edge) 그대로다.
    /// 게이트웨이나 계정 경계(`AccountScope`)가 없어도 만들지 않는다
    static func makeReturnSummaryStore(makeGateway: () -> (any ReturnSummaryGateway)?, scope: AccountScope?, c3: Bool) -> ReturnSummaryStore? {
        guard c3, let scope, let gateway = makeGateway() else { return nil }
        return ReturnSummaryStore(gateway: gateway, scope: scope)
    }

    private static var runStore: RunStore?

    /// 실행(U2) 상태: credits · run · 초안 (Mac 설정 Usage & Credits와 런처가 같은 것을 본다). 계정이 떠나면 스스로 비운다 (`RunStore.reset`).
    /// 견본(`-TFSampleData`)이면 서버를 부르지 않고 `SampleRuns` 인자대로 채운다
    static func runs(services: AppServices) -> RunStore {
        if let runStore { return runStore }
        let session: SessionStore? = if case .ready(let session, _) = startup { session } else { nil }
        let store = RunStore(services: services, session: session)
        #if DEBUG
        if SampleData.isEnabled { store.useSampleData() }
        #endif
        runStore = store
        return store
    }
}

/// 설정(Secrets.xcconfig)이 빠졌으면 앱을 죽이지 않고 무엇을 채워야 하는지 보여준다.
enum Startup {
    case ready(SessionStore, AppServices)
    case misconfigured(String)

    @MainActor
    static func make() -> Startup {
        do {
            let config = try AppConfig.fromMainBundle()
            // 클라이언트 하나를 로그인 · 읽기 · Realtime이 함께 쓴다 (세션 · 토큰 갱신을 공유)
            let supabase = TaskforceClient.makeSupabase(config: config)
            // 요청은 디스크 캐시 없는 세션으로 (`TaskforceClient.urlSession`). 예전 빌드가 공유 캐시에 남긴 응답 사본은 시작할 때 지운다
            URLCache.shared.removeAllCachedResponses()
            // 계정별로 이 기기에 남기는 데이터(목록 · 저장본)는 계정이 떠날 때 `SessionStore.onSignedOut`에서 지운다 (Mac 런처: `LauncherModel`)
            let session = SessionStore(auth: supabase.auth, googleOnly: true)
            return .ready(session, AppServices(config: config, supabase: supabase, session: TaskforceClient.urlSession))
        } catch {
            return .misconfigured(String(describing: error))
        }
    }
}

struct ConfigErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView("Setup needed", systemImage: "wrench.and.screwdriver", description: Text(message))
            .padding()
    }
}
