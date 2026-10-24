#if os(macOS) && DEBUG
import Foundation
import Testing

/// 계약 20장 1: `state.json`의 이어받음 · 핀 · 서버 이어받기 확정은 **로컬 Resume here 확인에서만**. 명령 · push · 서버가 시작한 길(런타임의 명령 · 사건 · wake · 조정 코드)은 이 쓰기를 부를 수 없다.
/// 소스를 읽어 이 쓰기들을 부르는 파일의 목록이 정확히 아래와 같음을 고정한다: 새 호출자가 생기면 이 시험이 빨개져 의식적으로 목록을 바꾸게 한다.
/// 확인 흐름의 입구(`ExternalSessionAttachModel.request` · `confirm`)를 부르는 곳도 Mac 셸 하나로 고정한다: 흐름은 사용자가 누른 확인에서만 돈다
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

    /// 한 줄에서 줄 주석(`//` · `///`)을 뺀 코드. **문자열 안의 `//`(주소 등)는 주석이 아니다**: 그 뒤의 코드를 자르지 않는다.
    /// 한계: 여러 줄 문자열(`"""`) · 원시 문자열(`#"…"#`) · `/* */` 주석 안은 따로 보지 못한다 (이 저장소는 줄 주석만 쓴다)
    static func code(of line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if inString {
                result.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                previous = character
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "/", previous == "/" {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// 주석을 뺀 줄에서 그 이름을 쓰는 파일 (루트 기준 상대 경로)
    private static func callers(of symbol: String, under root: URL) -> Set<String> {
        var found = Set<String>()
        for file in swiftFiles(under: root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Self.code(of: String($0)) }
            if lines.contains(where: { $0.contains(symbol) }) { found.insert(String(file.path.dropFirst(root.path.count + 1))) }
        }
        return found
    }

    @Test func theSourceTreesWereFound() {
        #expect(!Self.swiftFiles(under: Self.kit).isEmpty && !Self.swiftFiles(under: Self.app).isEmpty, "\(Self.kit.path) · \(Self.app.path)")
    }

    @Test func commentStrippingKeepsCodeThatFollowsASlashSlashInsideAStringLiteral() {
        #expect(Self.code(of: #"let url = "http://x"; _ = commitAttach(plan)"#).contains("commitAttach("), "문자열 안의 // 뒤 코드를 자르지 않는다")
        #expect(Self.code(of: #"let s = "a \" // still a string"; commitAttach("#).contains("commitAttach("), "이스케이프한 따옴표 뒤도 문자열이다")
        #expect(!Self.code(of: "let a = 1 // commitAttach(").contains("commitAttach("), "줄 주석은 뺀다")
        #expect(!Self.code(of: "/// commitAttach(").contains("commitAttach("), "문서 주석도 뺀다")
        #expect(Self.code(of: "let a = 1 // x // y") == "let a = 1 ", "첫 //부터 끝까지")
    }

    /// 쓰기를 부르는 파일은 정확히 이 목록이다 (Kit 안): 명령 · 사건 · wake · 조정 · 원장 · 클라이언트 코드는 하나도 없다
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

    @Test func theMacAppNeverNamesTheseWritesItHandsTheRuntimeToTheKitFlow() {
        // Mac 앱 코드는 이 쓰기 · 준비 · 확정을 직접 부르지 않는다: 런타임을 Kit의 이어받기 흐름(`ExternalSessionAttach`)에 넘길 뿐이고, 흐름은 사용자가 누른 확인에서만 돈다
        for symbol in Self.writes {
            #expect(Self.callers(of: symbol, under: Self.app).isEmpty, "\(symbol)")
        }
    }

    /// 흐름의 입구: 확인 줄을 세우는 `request`와 확인을 누르는 `confirm`은 Mac 셸(`EdgeShellModel`)만 부른다. Kit 안의 다른 코드(명령 · 사건 · 조정)는 이 모델을 구동하지 않는다.
    /// 셸의 `confirmResume`은 줄의 확인 단추(`EdgeExternalSessions`)만 부른다
    @Test func onlyTheMacShellDrivesTheConfirmFlowAndOnlyTheConfirmButtonPressesIt() {
        let entries: [(symbol: String, app: Set<String>)] = [
            ("attach?.request(", ["Mac/Edge/EdgeShellModel.swift"]), ("attach?.confirm(", ["Mac/Edge/EdgeShellModel.swift"]),
            ("attach.request(", []), ("attach.confirm(", []), ("shell.confirmResume(", ["Mac/Edge/EdgeExternalSessions.swift"]),
        ]
        for entry in entries {
            #expect(Self.callers(of: entry.symbol, under: Self.app) == entry.app, "app: \(entry.symbol)")
            #expect(Self.callers(of: entry.symbol, under: Self.kit).isEmpty, "kit: \(entry.symbol)")
        }
    }
}
#endif
