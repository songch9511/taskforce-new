#if os(macOS)
import Foundation
import Supabase
import Synchronization
import TaskforceKit

/// 프로젝트마다의 작업 폴더 (OA D4a2, 사용자 결정 11.1): 이 Mac · 이 계정 파티션의 폴더 등록부(`WorkspaceRegistry`)와, 세션 → 폴더를 찾는 resolver(`RegistryWorkspaceResolver`)를 앱에 잇는다.
/// 판단은 Kit이 한다 (찾기 순서 · 거절 규칙 · 경로 ↔ id). 여기는 파티션 폴더 위치 · 규칙에 넣는 앱 데이터 폴더 · 서버 읽기(RLS)를 대는 일뿐이다.
/// 파티션마다 등록부 하나를 만들어 두고 같은 객체를 런타임(resolver)과 화면(보내기 전 묻기 · Settings)이 함께 쓴다 — 서로 다른 사본이 디스크를 덮지 않게.
/// 서버에는 경로를 보내지 않는다(불투명 id만, D4a2-03). 경로 원문을 로그에 남기지 않는다.
final class ProjectWorkspaces: @unchecked Sendable {
    private let root: URL
    private let protectedRoots: [URL]
    private let makeRules: @Sendable ([String]) -> WorkspaceFolderRules
    private let sessions: any AgentSessionGateway
    private let contexts: any ContextGateway
    private let localBridgeID: @Sendable () async -> UUID?
    private let connectionBridgeID: @Sendable (UUID) async -> UUID?
    private let registries = Mutex<[String: WorkspaceRegistry]>([:])

    /// - root: 파티션 폴더들의 뿌리 (`<Application Support>/<번들 id>/Bridge/v1`). 계정 삭제는 파티션째 지워 등록부도 같이 사라진다
    /// - protectedRoots: 작업 폴더로 받지 않는 앱 데이터 폴더 (그 안, 그것을 품는 폴더 모두)
    /// - rules: 받아 줄 폴더의 규칙 (인자는 앱 데이터 폴더 경로들). 기본은 표준 규칙이다 — 시험은 임시 폴더가 `/private` 아래라 시스템 폴더 목록을 바꾼 규칙을 넣는다
    /// - localBridgeID: 이 Mac의 bridge id (등록 전이면 nil)
    /// - connectionBridgeID: 연결 하나를 돌리는 Mac의 bridge id (`agent_connections.bridge_id`, 읽지 못하면 nil)
    init(
        root: URL, home: String, protectedRoots: [URL], rules: (@Sendable ([String]) -> WorkspaceFolderRules)? = nil, sessions: any AgentSessionGateway,
        contexts: any ContextGateway, localBridgeID: @escaping @Sendable () async -> UUID?, connectionBridgeID: @escaping @Sendable (UUID) async -> UUID?
    ) {
        self.root = root
        self.makeRules = rules ?? { WorkspaceFolderRules.standard(home: home, protectedRoots: $0) }
        self.protectedRoots = protectedRoots
        self.sessions = sessions
        self.contexts = contexts
        self.localBridgeID = localBridgeID
        self.connectionBridgeID = connectionBridgeID
    }

    /// 작업 폴더로 받지 않고 Edit/Write도 막는 앱 폴더 (OA D4a2-03 · 코디네이터 13.11–13.12 · 보안 F2 · N1): 앱 데이터 폴더 · 파티션 뿌리 · **앱 번들**(`Contents/Helpers`의 훅 · 지킴이 — 에이전트가 바꾸면 게이트를 영구히 우회한다).
    /// 번들이 `/Applications` 밖(예: 내려받은 폴더)에 있어도 그 번들을 품은 폴더를 고를 수 없다. 번들이 App Translocation으로 옮겨져 실행 중이면 원래 번들 경로도 들어간다 (`AppBundleProtection`).
    /// 폴더 규칙(`denyAround`)과 adapter(`protectedRealPaths`)가 이 한 목록을 함께 쓴다 — 두 곳이 어긋나지 않게
    static func protectedRoots(support: URL, bundleID: String, root: URL, bundle: AppBundleProtection = AppBundleProtection()) -> [URL] {
        [support.appending(path: bundleID, directoryHint: .isDirectory), root] + bundle.roots
    }

    /// 실제 앱 연결: 서버 읽기는 RLS(`TaskforceReads` · `LiveContextGateway`), 이 Mac의 bridge id는 활성 런타임이 안다
    static func live(services: AppServices, root: URL, support: URL, bundleID: String, bundle: AppBundleProtection = AppBundleProtection()) -> ProjectWorkspaces {
        let supabase = services.supabase
        return ProjectWorkspaces(
            root: root, home: NSHomeDirectory(), protectedRoots: protectedRoots(support: support, bundleID: bundleID, root: root, bundle: bundle),
            sessions: services.reads, contexts: LiveContextGateway(services: services),
            localBridgeID: {
                guard let runtime = await MainActor.run(body: { BridgeHost.shared?.activeRuntime }) else { return nil }
                return await runtime.localBridgeID()
            },
            connectionBridgeID: { connectionID in
                let rows: [AgentConnectionRecord]? = try? await supabase.from("agent_connections").select(AgentConnectionRecord.columns)
                    .eq("id", value: connectionID.uuidString.lowercased()).limit(1).execute().value
                return rows?.first?.bridgeID
            }
        )
    }

    /// 이 파티션의 등록부 (파티션마다 하나)
    func registry(for partition: BridgePartition) -> WorkspaceRegistry {
        registries.withLock { cache in
            if let existing = cache[partition.id] { return existing }
            let registry = WorkspaceRegistry(
                file: partition.directory(in: root).appending(path: WorkspaceRegistry.fileName),
                rules: makeRules(protectedRoots.map(\.path))
            )
            cache[partition.id] = registry
            return registry
        }
    }

    /// 계정 삭제 뒤 그 파티션의 등록부 캐시를 비운다 (보안 F4): 지워진 파티션의 등록부 객체를 화면 · resolver가 다시 만나지 않게. 늦게 오는 쓰기는 파티션 폴더가 없으면 `persist`가 거절한다
    func forget(_ partition: BridgePartition) {
        registries.withLock { $0[partition.id] = nil }
    }

    /// 런타임에 넣는 resolver (Release · Debug 둘 다)
    func resolver(for partition: BridgePartition, log: any BridgeLogSink = BridgeOSLog()) -> RegistryWorkspaceResolver {
        RegistryWorkspaceResolver(registry: registry(for: partition), sessions: sessions, contexts: contexts, log: log)
    }

    /// 대상 연결이 이 Mac의 것인가 (보내기 전에 묻기, D4a2-05): 연결의 `bridge_id`가 이 Mac의 bridge id와 같을 때만 true. 읽지 못하면 false (다른 Mac이 정한다고 보고 묻지 않는다)
    func isThisMac(connectionID: UUID) async -> Bool {
        guard let mine = await localBridgeID(), let theirs = await connectionBridgeID(connectionID) else { return false }
        return mine == theirs
    }
}

/// 보내기 전에 묻는 쪽(`ChatRuntime`)이 한 번에 받는 면: 지금 계정의 등록부 + 연결 확인
struct AgentWorkspaceAsking {
    let folders: any AgentWorkspaceFolders
    let isThisMac: @Sendable (UUID) async -> Bool
}
/// Gatekeeper의 App Translocation: 격리 표시가 붙은 앱을 옮기지 않고 실행하면 시스템이 번들을 읽기 전용 뷰(`.../AppTranslocation/<UUID>/d/<앱>`, nullfs)로 열어 실행한다.
/// 이 뷰의 realpath는 원래 번들이 아니라서, 보호 목록에 이 경로만 있으면 원래 폴더(`~/Downloads`)를 작업 폴더로 고를 수 있고 훅을 바꿔치기할 수 있다 (보안 N1).
/// 감지: `SecTranslocateIsTranslocatedURL`(Security.framework, dlsym) 또는 경로 성분 `AppTranslocation`. 원래 경로: `SecTranslocateCreateOriginalPathForURL`. 시험은 두 함수를 바꿔 넣는다
struct AppTranslocation: Sendable {
    /// 번들 URL이 translocate됐나 (API를 부르지 못하면 nil)
    var isTranslocated: @Sendable (URL) -> Bool?
    /// translocate된 번들의 원래 경로 (구하지 못하면 nil)
    var originalPath: @Sendable (URL) -> String?

    /// translocate되지 않은 실행 (시험)
    static let notTranslocated = AppTranslocation(isTranslocated: { _ in false }, originalPath: { _ in nil })

    static let live = AppTranslocation(isTranslocated: liveIsTranslocated, originalPath: liveOriginalPath)

    private typealias IsTranslocatedFunction = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPathFunction = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        return dlsym(handle, name)
    }

    private static func liveIsTranslocated(_ url: URL) -> Bool? {
        guard let address = symbol("SecTranslocateIsTranslocatedURL") else { return nil }
        let function = unsafeBitCast(address, to: IsTranslocatedFunction.self)
        var translocated = false
        var error: Unmanaged<CFError>?
        guard function(url as CFURL, &translocated, &error) else {
            error?.release()
            return nil
        }
        return translocated
    }

    private static func liveOriginalPath(_ url: URL) -> String? {
        guard let address = symbol("SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(address, to: OriginalPathFunction.self)
        var error: Unmanaged<CFError>?
        guard let original = function(url as CFURL, &error)?.takeRetainedValue() else {
            error?.release()
            return nil
        }
        return (original as URL).path
    }
}

/// 이 실행의 앱 번들 보호 (보안 F2 · N1): 보호 루트에 더할 번들 realpath들과, 원래 번들을 알 수 없는 translocate 실행인지(`failClosed`).
/// `failClosed`면 그 실행에서는 Claude Code adapter를 만들지 않는다 — 원래 번들을 보호할 수 없는 채 에이전트에게 쓰기를 주지 않는다
struct AppBundleProtection: Equatable {
    /// 번들 realpath. translocate됐고 원래 경로를 알면 그 realpath도
    let roots: [URL]
    /// translocate됐는데 원래 경로를 구하지 못했다
    let failClosed: Bool

    init(bundleURL: URL = Bundle.main.bundleURL, translocation: AppTranslocation = .live) {
        func real(_ path: String) -> URL { URL(fileURLWithPath: GateFileSystem.realpath(path) ?? path, isDirectory: true) }
        var roots = [real(bundleURL.path)]
        let marker = "AppTranslocation"
        let translocated = (translocation.isTranslocated(bundleURL) ?? false) || bundleURL.pathComponents.contains(marker)
        var failClosed = false
        if translocated {
            if let original = translocation.originalPath(bundleURL), original.hasPrefix("/"), !URL(fileURLWithPath: original).pathComponents.contains(marker) {
                roots.append(real(original))
            } else {
                failClosed = true
            }
        }
        self.roots = roots
        self.failClosed = failClosed
    }
}
#endif
