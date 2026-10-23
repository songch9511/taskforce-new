#if os(macOS) && DEBUG
import Foundation
import Testing

/// 계약 20장 1: `state.json`의 이어받음 · 핀 · 서버 이어받기 확정은 **로컬 Resume here 확인에서만**. 명령 · push · 서버가 시작한 길(런타임의 명령 · 사건 · wake · 조정 코드)은 이 쓰기를 부를 수 없다.
/// 소스를 읽어 이 쓰기들을 부르는 파일의 목록이 정확히 아래와 같음을 고정한다: 새 호출자가 생기면 이 시험이 빨개져 의식적으로 목록을 바꾸게 한다
struct ExternalSessionAttachSourceScanTests {
    private static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let kit = package.appending(path: "Sources/TaskforceKit")
    private static let app = package.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Taskforce")

    /// 이 쓰기들의 이름
    private static let writes = ["writeAttached(", "attachPin(", "bindAttached(", "commitAttach(", "prepareAttach("]

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 주석을 뺀 줄에서 그 이름을 쓰는 파일 (루트 기준 상대 경로)
    private static func callers(of symbol: String, under root: URL) -> Set<String> {
        var found = Set<String>()
        for file in swiftFiles(under: root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let string = String(line)
                guard let comment = string.range(of: "//") else { return string }
                return String(string[..<comment.lowerBound])
            }
            if code.contains(where: { $0.contains(symbol) }) { found.insert(String(file.path.dropFirst(root.path.count + 1))) }
        }
        return found
    }

    @Test func theSourceTreesWereFound() {
        #expect(!Self.swiftFiles(under: Self.kit).isEmpty && !Self.swiftFiles(under: Self.app).isEmpty, "\(Self.kit.path) · \(Self.app.path)")
    }

    @Test func onlyTheLocalConfirmFlowCanWriteTheAttachState() {
        let expectedKit: [String: Set<String>] = [
            "writeAttached(": ["Bridge/ClaudeCode/ClaudeSessionState.swift", "Bridge/ClaudeCode/ClaudeAttach.swift"],
            "attachPin(": ["Bridge/WorkspaceRegistry.swift", "Bridge/BridgeRuntime+Attach.swift"],
            "bindAttached(": ["Bridge/ClaudeCode/ClaudeAttach.swift", "Bridge/BridgeRuntime+Attach.swift"],
            "commitAttach(": ["Bridge/BridgeRuntime+Attach.swift", "Bridge/ExternalSessions/ExternalSessionAttach.swift"],
            "prepareAttach(": ["Bridge/BridgeRuntime+Attach.swift", "Bridge/ExternalSessions/ExternalSessionAttach.swift"],
        ]
        for symbol in Self.writes {
            #expect(Self.callers(of: symbol, under: Self.kit) == expectedKit[symbol], "\(symbol)")
        }
    }

    @Test func theCommandAndEventPathsNeverNameTheseWrites() {
        // 서버가 시작하는 길: 명령 · 사건 · wake · 조정 · 원장 · 클라이언트 (Kit의 `Bridge/` 아래, 이어받기 파일 둘과 등록부 · 상태 정의를 뺀 모두)
        let allowed: Set<String> = [
            "Bridge/BridgeRuntime+Attach.swift", "Bridge/ClaudeCode/ClaudeAttach.swift", "Bridge/ClaudeCode/ClaudeSessionState.swift", "Bridge/WorkspaceRegistry.swift",
            "Bridge/ExternalSessions/ExternalSessionAttach.swift",
        ]
        for symbol in Self.writes {
            let outside = Self.callers(of: symbol, under: Self.kit).subtracting(allowed)
            #expect(outside.isEmpty, "\(symbol): \(outside.sorted())")
        }
    }

    @Test func theMacAppNeverNamesTheseWritesItHandsTheRuntimeToTheKitFlow() {
        // Mac 앱 코드는 이 쓰기 · 준비 · 확정을 직접 부르지 않는다: 런타임을 Kit의 이어받기 흐름(`ExternalSessionAttach`)에 넘길 뿐이고, 흐름은 사용자가 누른 확인에서만 돈다
        for symbol in Self.writes {
            #expect(Self.callers(of: symbol, under: Self.app).isEmpty, "\(symbol)")
        }
    }
}
#endif
