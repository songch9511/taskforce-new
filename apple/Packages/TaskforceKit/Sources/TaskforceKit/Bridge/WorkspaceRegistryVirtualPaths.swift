#if os(macOS)
import Foundation

/// 서버로 가는 모든 경로 칸의 가상 루트 (OA D4a2-03 끝까지, 코디네이터 13.11 · 보안 검토 F1): 서버에는 이 Mac의 경로가 한 글자도 가지 않는다.
///
/// - 작업 폴더(realpath) → `/taskforce/<ws_id>`: `ws_id`는 등록부가 **폴더(realpath)마다 하나** 준 불투명 id라, 다른 세션 · 프로젝트가 같은 폴더를 써도 같은 가상 루트가 되어
///   서버의 경로 lease(`agent_path_leases`: bridge별 `path_key`)가 충돌을 잡는다
/// - 그 안의 경로 → `/taskforce/<ws_id>/<상대 경로>` (서버의 "안쪽" 판정 · 쓰기 대상 lease 키 · 관찰 lease 키 `workspace_ref/path`와 모양이 같다)
/// - 세션 cwd(adapter가 띄운 `<세션 폴더>/cwd`) → 작업 폴더 밖의 고정 `/taskforce-session/cwd`
/// - 그 밖의 절대 경로 → 작업 폴더 밖의 고정 `/taskforce-outside` (서버가 밖으로 보아 defer · deny: 안전한 쪽)
/// - `session_bound.workspace_ref`도 같은 `/taskforce/<ws_id>`다 (서버 도구 판정은 `normalize(workspace_ref)`와 `workspace_real_path`를 비교한다 — 다르면 모든 판정이 `workspace_mismatch`다).
///   서버의 pending 모양 검사 `^/[^/]+/[^/]+`를 통과하는 두 성분 모양이다
///
/// 서버가 돌려주는 경로(`parse.paths[].absolute`)는 이 Mac에서 쓰기 전에 되돌린다 (`restore`): 명령 재구성은 실제 경로로 대조한다. 명령 원문은 바꾸지 않는다(사용자 결정 Q8: 300자까지 서버 보관).
public struct VirtualWorkspacePaths: Sendable, Equatable {
    public static let rootPrefix = "/taskforce/"
    public static let sessionCwdPath = "/taskforce-session/cwd"
    public static let outsidePath = "/taskforce-outside"
    /// 가상 경로의 접두 (`/taskforce/` · `/taskforce-session/` · `/taskforce-outside`). 에이전트가 명령 글에 스스로 이런 경로를 적으면 서버의 `parse`가 그 글자를 그대로 돌려주고
    /// 되돌리기가 실제 파일로 바꿔 버리므로, 명령 글에 이 접두가 있으면 명령을 다시 만들지 않는다 (`CommandRebuild`, 재검토 1 Astra 3)
    public static let commandPrefixes = ["/taskforce/", "/taskforce-"]
    /// 등록부에 없는 폴더(Debug 일회용 · 가짜 agent)의 고정 자리. 이 자리의 모든 세션이 한 폴더로 보인다 — 그 두 길은 개발 전용이다
    public static let unregisteredRef = "ws_unregistered"

    /// 작업 폴더의 realpath
    public let workspace: String
    /// 이 폴더의 가상 루트 `/taskforce/<ws_id>`
    public let virtualRoot: String
    /// adapter가 띄운 세션 cwd의 realpath (모르면 nil)
    public let sessionCwd: String?

    /// - ref: 등록부가 준 `ws_<uuid>` (모양이 아니거나 nil이면 고정 자리)
    public init(workspace: String, ref: String?, sessionCwd: String?) {
        self.workspace = workspace
        let id = ref.flatMap { WorkspaceRegistry.isOpaqueRef($0) ? $0 : nil } ?? Self.unregisteredRef
        self.virtualRoot = Self.rootPrefix + id
        self.sessionCwd = sessionCwd
    }

    /// `session_bound.workspace_ref`로 가는 값: `/taskforce/<ws_id>`
    public static func virtualRoot(forRef ref: String) -> String { rootPrefix + ref }

    /// 서버가 돌려준 `workspace_ref`가 가상 루트면 그 `ws_id` (아니면 nil)
    public static func ref(fromVirtualRoot value: String) -> String? {
        guard value.hasPrefix(rootPrefix) else { return nil }
        let id = String(value.dropFirst(rootPrefix.count))
        return WorkspaceRegistry.isOpaqueRef(id) ? id : nil
    }

    /// 실제 경로 → 서버로 보낼 경로
    public func virtualPath(_ real: String) -> String {
        if let rest = Self.remainder(of: real, under: workspace) { return virtualRoot + rest }
        if let sessionCwd, let rest = Self.remainder(of: real, under: sessionCwd) { return Self.sessionCwdPath + rest }
        return Self.outsidePath
    }

    /// 서버가 준 가상 경로 → 실제 경로 (작업 폴더 · 세션 cwd 안만. 그 밖은 nil)
    public func realPath(_ virtual: String) -> String? {
        if let rest = Self.remainder(of: virtual, under: virtualRoot) { return workspace + rest }
        if let sessionCwd, let rest = Self.remainder(of: virtual, under: Self.sessionCwdPath) { return sessionCwd + rest }
        return nil
    }

    /// `path`가 `root` 자신이거나 그 아래면 root 뒤의 나머지(`""` 또는 `/…`). 나머지에 `..` · `.` 성분이 있으면 nil — 가상 루트 안에서 위로 빠져나가는 길을 만들지 않는다 (밖으로 본다)
    private static func remainder(of path: String, under root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = root == "/" ? path : "/" + path.dropFirst(prefix.count)
        guard !rest.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return rest
    }

    // MARK: 도구 판정

    /// 서버로 보내기 전에 모든 경로 칸을 가상 경로로 바꾼다 (명령 원문 · 상대 경로는 그대로)
    public func virtualize(_ query: BridgeV1ToolDecisionQuery) -> BridgeV1ToolDecisionQuery {
        var wire = query
        wire.workspaceRealPath = virtualRoot
        wire.sessionCwdRealPath = nil
        func target(_ value: BridgeV1ToolTarget) -> BridgeV1ToolTarget { BridgeV1ToolTarget(realPath: virtualPath(value.realPath), relPath: value.relPath) }
        switch query.call {
        case .claudeBash(let id, let mode, let cwd, let command, let background, let sandbox):
            wire.call = .claudeBash(toolUseID: id, permissionMode: mode, cwd: virtualPath(cwd), command: command, runInBackground: background, dangerouslyDisableSandbox: sandbox)
        case .claudeWrite(let id, let mode, let tool, let value):
            wire.call = .claudeWrite(toolUseID: id, permissionMode: mode, tool: tool, target: target(value))
        case .codexCommand(let id, let cwd, let command, let actions, let first):
            wire.call = .codexCommand(providerRequestID: id, cwd: virtualPath(cwd), command: command, commandActions: actions, firstForItem: first)
        case .codexFileChange(let id, let targets, let first):
            wire.call = .codexFileChange(providerRequestID: id, targets: targets.map(target), firstForItem: first)
        }
        return wire
    }

    /// 서버 응답의 가상 경로(`parse.paths[].absolute`)를 이 Mac의 실제 경로로 되돌린다. 되돌릴 수 없는 경로는 가상 경로 그대로 둔다 — 명령 재구성이 실제 경로로 확인하지 못해 defer한다 (안전한 쪽).
    /// **Mac이 스스로 가상화한 칸만** 되돌린다: 상대 인자(작업 폴더 cwd 기준)와 명령에 없던 암묵 cwd(`index == nil`). 명령에 절대 경로로 적힌 인자(`argv[index]`가 `/`로 시작)는
    /// 에이전트가 쓴 글 그대로의 경로라 되돌리지 않는다 — `cat /taskforce/<ws_id>/a.txt`가 실제 `a.txt`로 바뀌어 읽히지 않게 (재검토 1 Astra 3)
    public func restore(_ response: BridgeV1ToolDecisionResponse) -> BridgeV1ToolDecisionResponse {
        guard var parse = response.parse else { return response }
        let argv = parse.argv
        parse.paths = parse.paths.map { path in
            if let index = path.index, argv.indices.contains(index), argv[index].hasPrefix("/") { return path }
            return BridgeV1ToolDecisionParse.Path(index: path.index, absolute: realPath(path.absolute) ?? path.absolute)
        }
        var restored = response
        restored.parse = parse
        return restored
    }
}
#endif
